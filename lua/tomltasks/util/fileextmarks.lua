local M = {}

---@class tomltasks.util.fileextmarks.MarkInfo
---@field id number
---@field file string
---@field lnum number        -- 1-based
---@field col number        -- 0-based
---@field opts vim.api.keyset.set_extmark
---@field user_data any
---@field source "live"|"stored"

---@class tomltasks.util.fileextmarks.MarkData
---@field id number
---@field ns number
---@field lnum number        -- 1-based
---@field col number        -- 0-based
---@field opts vim.api.keyset.set_extmark
---@field user_data any

---@alias tomltasks.util.fileextmarks.ById table<number, tomltasks.util.fileextmarks.MarkData>
---@alias tomltasks.util.fileextmarks.ByFile table<string, tomltasks.util.fileextmarks.ById>

---@class tomltasks.util.fileextmarks.GroupData
---@field ns number
---@field byfile tomltasks.util.fileextmarks.ByFile
---@field id_to_file table<number, string>

---@type table<string, tomltasks.util.fileextmarks.GroupData>
local _defined_groups = {}
local _autocmds_registered = false

-- Namespaces and autocmd groups live in one process-wide registry keyed by name,
-- while the state above is per module instance, so two vendored copies of this
-- file would silently share them. The owning plugin claims a prefix via M.init().
---@type string?
local _prefix = nil

---@return string
local function _require_prefix()
    return assert(_prefix, "init(prefix) must be called first")
end

---@param name string
---@return string
local function _prefixed(name)
    return ("%s.%s"):format(_require_prefix(), name)
end

--- Lands every spelling of a file -- relative, or through a symlinked component
--- -- on one key. Buffer names go through it too: Neovim leaves a final-component
--- symlink unresolved. `resolve()`, since a mark may name a file that is not there.
---@param file string
---@return string
local function _normalize_file(file)
    return vim.fn.resolve(vim.fn.fnamemodify(file, ":p"))
end

--- Normalized buffer names, keyed by bufnr and validated against the raw name.
--- The scan below normalizes every loaded buffer on every miss, and a miss is the
--- common case: most tracked files are not open.
---@type table<integer, { name: string, normalized: string }>
local _bufname_cache = {}

--- `_normalize_file` for a buffer's name, memoized. Two `vim.fn` calls become one
--- C call and a table lookup; re-validating against the raw name heals a rename
--- and a reused buffer number on its own.
---@param bufnr integer
---@param name string        -- the buffer's raw name, non-empty
---@return string
local function _normalized_buf_name(bufnr, name)
    local entry = _bufname_cache[bufnr]
    if entry and entry.name == name then return entry.normalized end

    local normalized = _normalize_file(name)
    _bufname_cache[bufnr] = { name = name, normalized = normalized }
    return normalized
end

---@class tomltasks.util.fileextmarks.BufCacheEntry
---@field bufnr integer
---@field name string        -- the buffer's name when it was resolved

--- Cache for `_get_loaded_bufnr`, keyed by normalized path.
---@type table<string, tomltasks.util.fileextmarks.BufCacheEntry>
local _bufnr_cache = {}

--- Walks the buffer list comparing normalized names, which also lands a buffer
--- opened by another spelling. `vim.fn.bufnr()` cannot do this job: it falls back
--- to a partial match, so an untracked file resolves to any name containing it.
---@param file string        -- must already be normalized
---@return integer
local function _lookup_loaded_bufnr(file)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            local name = vim.api.nvim_buf_get_name(bufnr)
            if name ~= "" and _normalized_buf_name(bufnr, name) == file then return bufnr end
        end
    end

    return -1
end

--- The scan above is a `resolve()` per loaded buffer, so it is cached. Re-validating
--- the cached answer against the name it was cached under costs three C calls and
--- heals wipes, unloads and renames itself.
---@param file string        -- must already be normalized
---@return integer
local function _get_loaded_bufnr(file)
    local entry = _bufnr_cache[file]
    if entry then
        if vim.api.nvim_buf_is_valid(entry.bufnr)
            and vim.api.nvim_buf_is_loaded(entry.bufnr)
            and vim.api.nvim_buf_get_name(entry.bufnr) == entry.name
        then
            return entry.bufnr
        end
        _bufnr_cache[file] = nil
    end

    local bufnr = _lookup_loaded_bufnr(file)
    if bufnr == -1 then return -1 end

    _bufnr_cache[file] = { bufnr = bufnr, name = vim.api.nvim_buf_get_name(bufnr) }
    return bufnr
end

--- Buffers holding marks, mapped to the normalized file they hold them for:
--- `_on_lines` needs it on every change and cannot afford to re-derive it from the
--- buffer's name, and a missing entry is what tells the callback to detach.
---@type table<integer, string>
local _attached = {}

--- Buffers with a live `on_lines` subscription. Kept out of `_attached`: dropping
--- an entry there only *schedules* a detach, and one table doing both jobs would
--- read as unsubscribed in that window and stack a second subscription.
---@type table<integer, true>
local _subscribed = {}

--- Forgets the cached buffer lookup for `file`, unless some group still tracks
--- it. Call after dropping a file from a group; the cache is shared across
--- groups, so the last one out turns the light off.
---@param file string
local function _forget_bufnr(file)
    for _, group_data in pairs(_defined_groups) do
        if group_data.byfile[file] then return end
    end

    _bufnr_cache[file] = nil

    -- Schedule the `on_lines` release too, or the buffer keeps paying a query per
    -- group on every edit reaching its end. `_attached` is scanned because
    -- `_bufnr_cache` may never have held this file; `_subscribed` is left alone.
    for bufnr, attached_file in pairs(_attached) do
        if attached_file == file then _attached[bufnr] = nil end
    end
end

--- Call after removing a single mark: drops `file` from the group if that was its
--- last one, then releases the cache. Otherwise an emptied file lingers as a bare
--- table that every later `_get_extmarks` walks and pays a buffer lookup for.
---@param group_data tomltasks.util.fileextmarks.GroupData
---@param file string
local function _release_file(group_data, file)
    local file_table = group_data.byfile[file]
    if file_table and next(file_table) == nil then
        group_data.byfile[file] = nil
    end

    _forget_bufnr(file)
end

--- Writes `mark` into the buffer at the given position, clamped to a real line
--- and a real column. Does not touch the cached position in `mark`.
---@param bufnr integer
---@param mark tomltasks.util.fileextmarks.MarkData
---@param lnum integer        -- 1-based
---@param col integer        -- 0-based
---@param ends { end_row: integer?, end_col: integer? }?      -- live end, if known
---@return integer lnum, integer col      -- the clamped position actually used
local function _place_extmark(bufnr, mark, lnum, col, ends)
    local line_count = vim.api.nvim_buf_line_count(bufnr)

    lnum = math.max(1, math.min(lnum, line_count))
    local row = lnum - 1

    -- Only a non-zero column needs the line, and marks overwhelmingly sit at 0.
    -- Kept around for the range end below, which usually wants the same line.
    local row_line
    if col > 0 then
        row_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, true)[1] or ""
        col = math.min(col, #row_line)
    else
        col = 0
    end

    -- Clamp the range end inside the buffer: `end_col` is measured against its
    -- line, so a range whose text was deleted would throw. `mark.opts` is left
    -- alone, so an undo restores the whole range; a range that fits allocates nothing.
    local opts = mark.opts
    local end_row, end_col = opts.end_row, opts.end_col

    -- `ends` wins when given: the stored end only moves on a save, so a caller
    -- holding the live one is holding the truth. Both fields nil means a point
    -- mark, which has to be able to clear a range the stored opts still carry.
    if ends then end_row, end_col = ends.end_row, ends.end_col end

    if end_row or end_col then
        local clamped_row = math.min(end_row or row, line_count - 1)

        -- The end may not precede the start: Neovim stores an inverted range in
        -- silence rather than rejecting it, and the mark just stops rendering.
        -- Costs a comparison on a path that already clamps.
        clamped_row = math.max(clamped_row, row)

        local clamped_col = end_col

        if end_col then
            local line = clamped_row == row and row_line
            if not line then
                line = vim.api.nvim_buf_get_lines(bufnr, clamped_row, clamped_row + 1, true)[1] or ""
            end
            clamped_col = math.min(end_col, #line)
            if clamped_row == row then clamped_col = math.max(clamped_col, col) end
        end

        if ends then
            -- Assigned rather than merged: `tbl_extend` cannot carry a nil through,
            -- so a merge would leave a stale field standing.
            opts = vim.tbl_extend("force", opts, {})
            opts.end_row, opts.end_col = clamped_row, clamped_col
        elseif (end_row and clamped_row ~= end_row) or clamped_col ~= end_col then
            opts = vim.tbl_extend("force", opts, { end_row = clamped_row, end_col = clamped_col })
        end
    elseif ends and (opts.end_row or opts.end_col) then
        opts = vim.tbl_extend("force", opts, {})
        opts.end_row, opts.end_col = nil, nil
    end

    assert(type(mark.id) == "number")
    local id = vim.api.nvim_buf_set_extmark(bufnr, mark.ns, row, col, opts)
    assert(id == mark.id)

    return lnum, col
end

---@param bufnr integer
---@param mark tomltasks.util.fileextmarks.MarkData
---@param store boolean      -- record where the mark landed, clamp included
local function _set_extmark(bufnr, mark, store)
    -- No empty-buffer guard: a loaded buffer always holds at least one line.
    if not vim.api.nvim_buf_is_loaded(bufnr) then return end

    local lnum, col = _place_extmark(bufnr, mark, mark.lnum, mark.col)
    if store then mark.lnum, mark.col = lnum, col end
end

---@class tomltasks.util.fileextmarks.LivePos
---@field id number
---@field lnum number        -- 1-based
---@field col number        -- 0-based
---@field end_row number?        -- 0-based; nil for a point mark
---@field end_col number?        -- 0-based; nil for a point mark

--- Reports where this group's marks currently sit in `bufnr`. Pure: `_on_lines`
--- keeps every row real. The clamp is defence in depth for a buffer we failed to
--- attach to -- better the last line than a line that does not exist.
---@param bufnr integer
---@param file_table tomltasks.util.fileextmarks.ById
---@param ns integer
---@return tomltasks.util.fileextmarks.LivePos[]      -- in buffer order
local function _read_live_marks(bufnr, file_table, ns)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local result = {}

    -- `details` is what carries the range end, and only a synced end can be paired
    -- with a synced start -- see `_sync_file_extmarks`. A point mark reports neither.
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
        local id, row, col, details = m[1], m[2], m[3], m[4]
        assert(details)
        if file_table[id] then
            result[#result + 1] = {
                id = id,
                lnum = math.min(row + 1, line_count),
                col = col,
                end_row = details.end_row,
                end_col = details.end_col,
            }
        end
    end

    return result
end

--- Re-anchors marks stranded past the end of `bufnr` onto its last line: a delete
--- running to the last line leaves them one row past it forever, where nothing
--- renders and no ranged query finds them. Bounded to that tail, so usually free.
---@param bufnr integer
---@param file string        -- normalized; from `_attached`, so an edit re-normalizes nothing
---@param line_count integer      -- the buffer's line count after the change
local function _repair_stranded_marks(bufnr, file, line_count)
    for _, group_data in pairs(_defined_groups) do
        -- Matched through `byfile`, not by id: a buffer can hold an extmark for a
        -- file it is no longer the buffer of, and by id that orphan would resolve
        -- to its *new* file and be re-anchored here on every edit.
        local file_table = group_data.byfile[file]
        if file_table then
            local stranded = vim.api.nvim_buf_get_extmarks(
                bufnr,
                group_data.ns,
                { line_count, 0 },
                { -1, -1 },
                { details = true }
            )
            for _, m in ipairs(stranded) do
                local mark = file_table[m[1]]
                if mark then
                    -- Clamps onto the last line, live end included -- pairing it with
                    -- the stored end would collapse the range. The cached position is
                    -- left alone, so the cache keeps describing the file on disk.
                    _place_extmark(bufnr, mark, m[2] + 1, m[3], m[4])
                end
            end
        end
    end
end

--- Fires for every change to an attached buffer, including API ones -- which is
--- why this replaced a TextChanged autocmd: `nvim_buf_set_lines` fires no
--- TextChanged, so a plugin editing the buffer stranded marks silently.
local function _on_lines(_, bufnr, _, _, _, last_new)
    -- No entry means the last mark for this buffer's file is gone. Returning true
    -- is the whole detach path: an `on_lines` callback can only release itself, so
    -- `_forget_bufnr` drops the entry and the next change tears the subscription down.
    local file = _attached[bufnr]
    if not file then
        _subscribed[bufnr] = nil
        return true -- detach
    end

    -- Guarded for a second reason: an error escaping here has Neovim drop the
    -- subscription without calling `on_detach`, and the stale `_subscribed` entry
    -- would bar `_attach_buffer` from ever replacing it. Nothing else can raise.
    local ok, line_count = pcall(vim.api.nvim_buf_line_count, bufnr)
    if not ok then
        -- State unknown, so hold nothing: detaching costs one re-attach, and the
        -- next `_apply_buffer_extmarks` or `set_file_extmark` does it.
        _attached[bufnr] = nil
        _subscribed[bufnr] = nil
        return true -- detach
    end

    -- Only a change reaching the end can strand a mark -- growing the buffer does
    -- it too, since a right-gravity mark lands on `last_new`. Decided from the
    -- range alone, so a shorter edit costs O(1) and never touches the extmark tree.
    if last_new < line_count then return end -- change stopped short of the end

    -- Swallowed on purpose: an error raised here propagates out of the change that
    -- triggered it, and the buffer then rejects every later edit.
    pcall(_repair_stranded_marks, bufnr, file, line_count)
end

---@param bufnr integer
---@param file string        -- normalized; the file `bufnr` holds marks for
local function _attach_buffer(bufnr, file)
    _attached[bufnr] = file -- may be a re-attach under a new name

    -- A subscription scheduled for release but not yet torn down is reused: the
    -- entry above revives it, and attaching again would leave two running.
    if _subscribed[bufnr] then return end

    _subscribed[bufnr] = true
    local ok = vim.api.nvim_buf_attach(bufnr, false, {
        on_lines = _on_lines,
        on_detach = function(_, b)
            _attached[b] = nil
            _subscribed[b] = nil
        end,
    })
    if not ok then
        _attached[bufnr] = nil
        _subscribed[bufnr] = nil
    end
end

---@param bufnr integer
---@param ns integer
local function _clear_buf_namespace(bufnr, ns)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

--- Whether `bufnr`'s text can be read as the file's own. The stored position
--- describes what is on disk, so this gates every write from a buffer back into
--- the cache: an unsaved edit, and a buffer with no file behind it, are not it.
---@param bufnr integer
---@return boolean
local function _buf_matches_file(bufnr)
    if vim.bo[bufnr].modified then return false end

    -- The second call is reached only by a one-line buffer, so the common case is
    -- a single C call and no allocation.
    if vim.api.nvim_buf_line_count(bufnr) > 1 then return true end
    return vim.api.nvim_buf_get_lines(bufnr, 0, 1, true)[1] ~= ""
end

--- Replaces the namespace with this group's stored marks for `bufnr`'s file. The
--- clear collects marks orphaned by an unload (deletes skip an unloaded buffer) or
--- a rename, so it runs unconditionally -- before the name check, which may miss.
---@param bufnr integer
---@param group string
local function _apply_buffer_extmarks(bufnr, group)
    local group_data = _defined_groups[group]
    assert(group_data)

    _clear_buf_namespace(bufnr, group_data.ns)

    local file = vim.api.nvim_buf_get_name(bufnr)
    if file == "" then return end
    file = _normalized_buf_name(bufnr, file)

    local file_data = group_data.byfile[file]
    if not file_data then return end

    -- The clamp is evidence about the file only when the buffer holds what the
    -- file holds: a `BufNewFile` buffer is empty for want of a file, not for want
    -- of lines, and recording that would flatten every stored line to 1.
    local store = _buf_matches_file(bufnr)

    for _, mark in pairs(file_data) do
        _set_extmark(bufnr, mark, store)
    end

    _attach_buffer(bufnr, file)
end

---@param bufnr number
local function _sync_file_extmarks(bufnr)
    local file = vim.api.nvim_buf_get_name(bufnr)
    if file == "" then return end
    file = _normalized_buf_name(bufnr, file)

    -- Both callers reach here with the buffer about to be written or dropped, and
    -- neither is a reason to record positions the file does not have.
    if not _buf_matches_file(bufnr) then return end

    for _, group_data in pairs(_defined_groups) do
        local file_table = group_data.byfile[file]
        if file_table then
            for _, live in ipairs(_read_live_marks(bufnr, file_table, group_data.ns)) do
                local mark = file_table[live.id]
                mark.lnum, mark.col = live.lnum, live.col

                -- The end drifts like the start but lives in `opts`, so syncing
                -- only the start would re-place a current start against a
                -- creation-time end. Unconditional: a point mark reports nil.
                mark.opts.end_row = live.end_row
                mark.opts.end_col = live.end_col
            end
        end
    end
end

local function _register_autocmds()
    if _autocmds_registered then return end
    _autocmds_registered = true

    local name = _prefixed("fileextmarks")

    assert(not pcall(vim.api.nvim_get_autocmds, { group = name }),
        ("augroup %q already exists -- another copy of this module owns prefix %q"):format(name, _require_prefix()))

    local augroup = vim.api.nvim_create_augroup(name, { clear = true })
    -- `BufNewFile` alongside `BufReadPost`: a path with no file behind it fires
    -- only the former, and marks on a file that is not there yet are a case this
    -- module supports -- see `_normalize_file`.
    vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
        group = augroup,
        callback = function(ev)
            for group in pairs(_defined_groups) do
                _apply_buffer_extmarks(ev.buf, group)
            end
        end,
    })
    -- A rename leaves the buffer holding the old name's marks, rendered but
    -- unreachable: every lookup goes through the file, not the buffer. Re-applying
    -- clears the namespace and puts back whatever the new name owns.
    vim.api.nvim_create_autocmd("BufFilePost", {
        group = augroup,
        callback = function(ev)
            -- Dropped rather than repointed: `_apply_buffer_extmarks` re-attaches
            -- under the new file if it has marks, and leaving the old entry has
            -- `_on_lines` repairing this buffer against a file it no longer holds.
            _attached[ev.buf] = nil
            for group in pairs(_defined_groups) do
                _apply_buffer_extmarks(ev.buf, group)
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = augroup,
        callback = function(ev) _sync_file_extmarks(ev.buf) end,
    })
    -- `BufUnload` as well as `BufWipeout`: `:bdelete` unloads without wiping and
    -- leaves the buffer valid, so waiting for the wipe leaks an entry per buffer
    -- for the life of the session -- and `_lookup_loaded_bufnr` caches every
    -- loaded buffer it walks past, tracked or not. An entry for an unloaded
    -- buffer is dead weight anyway: only loaded buffers are ever scanned, and a
    -- buffer that comes back pays one `resolve()` to re-enter the cache.
    vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
        group = augroup,
        callback = function(ev) _bufname_cache[ev.buf] = nil end,
    })
end

---@param id number
---@param file string
---@param lnum number        -- 1-based
---@param col number        -- 0-based
---@param group_data tomltasks.util.fileextmarks.GroupData
---@param opts vim.api.keyset.set_extmark       -- extmark opts (include `priority` here)
---@param user_data any
---@see vim.api.nvim_buf_set_extmark
local function _set_file_extmark(id, file, lnum, col, group_data, opts, user_data)
    assert(lnum >= 1, "lnum must be 1-based")

    file = _normalize_file(file)
    local bufnr = _get_loaded_bufnr(file)

    local old_file = group_data.id_to_file[id]
    if old_file and old_file ~= file then
        local old_bufnr = _get_loaded_bufnr(old_file)
        if old_bufnr >= 0 then
            vim.api.nvim_buf_del_extmark(old_bufnr, group_data.ns, id)
        end

        -- Vacate the old file, or the mark stays visible there: it would be
        -- reported twice by `_get_extmarks` and put back into the old buffer by
        -- `refresh()`, since both read from `byfile` rather than from the buffer.
        local old_table = group_data.byfile[old_file]
        if old_table then
            old_table[id] = nil
            _release_file(group_data, old_file)
        end
    end

    group_data.id_to_file[id] = file
    group_data.byfile[file] = group_data.byfile[file] or {}

    ---@type tomltasks.util.fileextmarks.MarkData
    local mark = {
        id = id,
        ns = group_data.ns,
        lnum = lnum,
        col = col,
        -- `id` last: with "force" the right-hand table wins, and the id this
        -- mark is keyed by everywhere is not the caller's to override.
        opts = vim.tbl_extend("force", opts or {}, { id = id }),
        user_data = user_data,
    }

    group_data.byfile[file][id] = mark

    if bufnr >= 0 then
        -- Gated like every other write into the cached position: the clamp inside
        -- `_set_extmark` is measured against the *buffer*, and a buffer with
        -- unsaved deletes is shorter than its file. Storing that would pin the
        -- mark to the short buffer's last line for good -- the edit can be thrown
        -- away, the cached line cannot. Where the buffer is the file, the clamp is
        -- evidence and worth keeping; where it is not, the caller's line stands.
        _set_extmark(bufnr, mark, _buf_matches_file(bufnr))
        _attach_buffer(bufnr, file)
    end
end

---@param id number
---@param group_data tomltasks.util.fileextmarks.GroupData
local function _remove_extmark(id, group_data)
    local file = group_data.id_to_file[id]
    if not file then return end

    group_data.id_to_file[id] = nil

    local file_table = group_data.byfile[file]
    if not file_table then return end

    local bufnr = _get_loaded_bufnr(file)
    if bufnr >= 0 then
        vim.api.nvim_buf_del_extmark(bufnr, group_data.ns, id)
    end

    file_table[id] = nil
    _release_file(group_data, file)
end

---@param file string
---@param group_data tomltasks.util.fileextmarks.GroupData
local function _remove_file_extmarks(file, group_data)
    file = _normalize_file(file)

    local file_table = group_data.byfile[file]
    if not file_table then return end

    for id in pairs(file_table) do
        group_data.id_to_file[id] = nil
    end

    group_data.byfile[file] = nil

    local bufnr = _get_loaded_bufnr(file)
    if bufnr >= 0 then
        _clear_buf_namespace(bufnr, group_data.ns)
    end

    _forget_bufnr(file)
end

---@param group_data tomltasks.util.fileextmarks.GroupData
local function _remove_extmarks(group_data)
    local files = {}
    for file in pairs(group_data.byfile) do
        files[#files + 1] = file
        local bufnr = _get_loaded_bufnr(file)
        if bufnr >= 0 then
            _clear_buf_namespace(bufnr, group_data.ns)
        end
    end

    group_data.byfile = {}
    group_data.id_to_file = {}

    for _, file in ipairs(files) do
        _forget_bufnr(file)
    end
end

---@param id number
---@param group_data tomltasks.util.fileextmarks.GroupData
---@return tomltasks.util.fileextmarks.MarkInfo?
local function _get_extmark_by_id(id, group_data)
    local file = group_data.id_to_file[id]
    if not file then return nil end

    local mark = (group_data.byfile[file] or {})[id]
    if not mark then return nil end

    return {
        id = mark.id,
        file = file,
        lnum = mark.lnum,
        col = mark.col,
        opts = mark.opts,
        user_data = mark.user_data,
        source = "stored",
    }
end

---@param file string
---@param line number
---@param group_data tomltasks.util.fileextmarks.GroupData
---@param live boolean
---@return tomltasks.util.fileextmarks.MarkInfo?
local function _get_extmark_by_location(file, line, group_data, live)
    assert(type(live) == "boolean")
    assert(line >= 1, "line must be 1-based")

    file = _normalize_file(file)

    local file_table = group_data.byfile[file]
    if not file_table then return nil end

    local bufnr = live and _get_loaded_bufnr(file) or -1
    if bufnr >= 0 then
        local line_count = vim.api.nvim_buf_line_count(bufnr)
        if line > line_count then return nil end

        -- Bounded to the line asked for rather than walking the namespace. The last
        -- line reaches past the end too: a mark stranded there reads as sitting on
        -- it, and a buffer we failed to attach to can still be holding one.
        local last = line == line_count and { -1, -1 } or { line - 1, -1 }
        local found = vim.api.nvim_buf_get_extmarks(
            bufnr,
            group_data.ns,
            { line - 1, 0 },
            last,
            { details = false }
        )

        for _, m in ipairs(found) do
            local mark = file_table[m[1]]
            if mark then
                return {
                    id = m[1],
                    file = file,
                    lnum = line, -- every hit in this range reads as `line`
                    col = m[3],
                    opts = mark.opts,
                    user_data = mark.user_data,
                    source = "live",
                }
            end
        end

        return nil
    end

    for id, mark in pairs(file_table) do
        if mark.lnum == line then
            return {
                id = id,
                file = file,
                lnum = mark.lnum,
                col = mark.col,
                opts = mark.opts,
                user_data = mark.user_data,
                source = "stored",
            }
        end
    end

    return nil
end

---@param group_data tomltasks.util.fileextmarks.GroupData
---@param live boolean
---@return tomltasks.util.fileextmarks.MarkInfo[]
local function _get_extmarks(group_data, live)
    assert(type(live) == "boolean")

    local result = {}

    for file, file_table in pairs(group_data.byfile) do
        local bufnr = live and _get_loaded_bufnr(file) or -1
        if bufnr >= 0 then
            for _, m in ipairs(_read_live_marks(bufnr, file_table, group_data.ns)) do
                local mark = file_table[m.id]
                result[#result + 1] = {
                    id = m.id,
                    file = file,
                    lnum = m.lnum,
                    col = m.col,
                    opts = mark.opts,
                    user_data = mark.user_data,
                    source = "live",
                }
            end
        else
            for id, mark in pairs(file_table) do
                result[#result + 1] = {
                    id = id,
                    file = file,
                    lnum = mark.lnum,
                    col = mark.col,
                    opts = mark.opts,
                    user_data = mark.user_data,
                    source = "stored",
                }
            end
        end
    end

    return result
end

---@param file string
---@param group_data tomltasks.util.fileextmarks.GroupData
---@param live boolean
---@return tomltasks.util.fileextmarks.MarkInfo[]
local function _get_file_extmarks(file, group_data, live)
    assert(type(live) == "boolean")

    file = _normalize_file(file)
    local result = {}

    local file_table = group_data.byfile[file]
    if not file_table then return result end

    local bufnr = live and _get_loaded_bufnr(file) or -1
    if bufnr >= 0 then
        for _, m in ipairs(_read_live_marks(bufnr, file_table, group_data.ns)) do
            local mark = file_table[m.id]
            result[#result + 1] = {
                id = mark.id,
                file = file,
                lnum = m.lnum,
                col = m.col,
                opts = mark.opts,
                user_data = mark.user_data,
                source = "live",
            }
        end
    else
        for _, mark in pairs(file_table) do
            result[#result + 1] = {
                id = mark.id,
                file = file,
                lnum = mark.lnum,
                col = mark.col,
                opts = mark.opts,
                user_data = mark.user_data,
                source = "stored",
            }
        end
    end

    return result
end

---@param group_data tomltasks.util.fileextmarks.GroupData
---@param group string
local function _refresh_group(group_data, group)
    for file in pairs(group_data.byfile) do
        local bufnr = _get_loaded_bufnr(file)
        if bufnr >= 0 then
            _apply_buffer_extmarks(bufnr, group) -- clears the namespace itself
        end
    end
end

---@class tomltasks.util.fileextmarks.GroupFunctions
---@field set_file_extmark fun(id:number, file:string, lnum:number, col:number, opts:vim.api.keyset.set_extmark, user_data:any)
---@field remove_extmarks fun()
---@field remove_extmark fun(id:number)
---@field remove_file_extmarks fun(file:string)
---@field get_extmark_by_id fun(id:number): tomltasks.util.fileextmarks.MarkInfo?
---@field get_extmark_by_location fun(file:string, line:number, live:boolean): tomltasks.util.fileextmarks.MarkInfo?
---@field get_extmarks fun(live:boolean): tomltasks.util.fileextmarks.MarkInfo[]
---@field get_file_extmarks fun(file:string, live:boolean): tomltasks.util.fileextmarks.MarkInfo[]
---@field refresh fun()

--- Claims the prefix used for every namespace and augroup this module creates.
--- Must be called (once) before M.define_group().
---@param prefix string  unique to the calling plugin, e.g. "myplugin"
function M.init(prefix)
    assert(type(prefix) == "string" and prefix ~= "", "prefix (non-empty string) required")
    assert(not _prefix or _prefix == prefix, ("already initialized with prefix %q"):format(_prefix))

    _prefix = prefix
end

---@param group string  name, unique within this module instance; used to derive the extmark namespace
---@return tomltasks.util.fileextmarks.GroupFunctions
function M.define_group(group)
    _require_prefix()
    assert(type(group) == "string", "group (string) required")
    assert(not _defined_groups[group], "group already defined")

    local ns_name = _prefixed(group)
    assert(not vim.api.nvim_get_namespaces()[ns_name],
        ("namespace %q already exists -- another copy of this module owns prefix %q"):format(ns_name, _require_prefix()))

    ---@type tomltasks.util.fileextmarks.GroupData
    local group_data = {
        ns = vim.api.nvim_create_namespace(ns_name),
        byfile = {},
        id_to_file = {},
    }
    _defined_groups[group] = group_data

    _register_autocmds()

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            _apply_buffer_extmarks(bufnr, group)
        end
    end

    ---@type tomltasks.util.fileextmarks.GroupFunctions
    return {
        set_file_extmark = function(id, file, lnum, col, opts, user_data)
            _set_file_extmark(id, file, lnum, col, group_data, opts, user_data)
        end,
        remove_extmark = function(id)
            _remove_extmark(id, group_data)
        end,
        remove_file_extmarks = function(file)
            _remove_file_extmarks(file, group_data)
        end,
        remove_extmarks = function()
            _remove_extmarks(group_data)
        end,
        get_extmark_by_id = function(id)
            return _get_extmark_by_id(id, group_data)
        end,
        get_extmark_by_location = function(file, line, live)
            return _get_extmark_by_location(file, line, group_data, live)
        end,
        get_extmarks = function(live)
            return _get_extmarks(group_data, live)
        end,
        get_file_extmarks = function(file, live)
            return _get_file_extmarks(file, group_data, live)
        end,
        refresh = function()
            _refresh_group(group_data, group)
        end,
    }
end

return M
