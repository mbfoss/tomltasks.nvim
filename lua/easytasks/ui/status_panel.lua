local utils             = require('easytasks.util.ui_util')
local exec              = require('easytasks.runner.exec')

---@class easytasks.ui.status_panel
local M                 = {}

-- ── State ─────────────────────────────────────────────────────────────────────

local _win              = nil ---@type integer?
local _height_ratio     = nil ---@type number?

local _runs             = {} ---@type string[]   run_ids, newest first
local _run_map          = {} ---@type table<string, easytasks.RunEntry>
local _known_buf_counts = {} ---@type table<string, integer>  bufnr count as of last notification

local _active_run_id    = nil ---@type string?
local _active_page      = 0 -- 0 = info scratch, 1..n = entry.bufnrs index

local _subscribed       = false
local _jump_mode        = false
local _jump_targets     = {} ---@type {run_id:string, page:integer}[]
local _JUMP_KEYS        = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()"

local _info_buf         = nil ---@type integer?
local _empty_buf        = nil ---@type integer?

local _augroup          = vim.api.nvim_create_augroup("EasyTasksStatusPanel", { clear = true })
local _info_hl_ns       = vim.api.nvim_create_namespace("EasyTasksInfoBuf")

-- ── Highlights ────────────────────────────────────────────────────────────────

local function _setup_hl()
    local function fg(name)
        local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
        return ok and hl.fg or nil
    end
    local function bg(name)
        local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
        return ok and hl.bg or nil
    end
    vim.api.nvim_set_hl(0, "EasyTasksActiveTab", { fg = fg("Title"), bg = bg("WinBar"), bold = true, default = true })
    vim.api.nvim_set_hl(0, "EasyTasksBadgeOk", { link = "DiagnosticOk", default = true })
    vim.api.nvim_set_hl(0, "EasyTasksBadgeErr", { link = "DiagnosticError", default = true })
    vim.api.nvim_set_hl(0, "EasyTasksBadgeWarn", { link = "DiagnosticWarn", default = true })
    vim.api.nvim_set_hl(0, "EasyTasksBadgeHint", { link = "DiagnosticHint", default = true })
    vim.api.nvim_set_hl(0, "EasyTasksJumpKey",
        { fg = 0xffffff, bg = 0xcc2222, bold = true, default = true })
end

---@type table<easytasks.TaskState, {icon:string, hl:string}>
local _badge = {
    running = { icon = "▶", hl = "EasyTasksBadgeWarn" },
    waiting = { icon = "⧗", hl = "EasyTasksBadgeWarn" },
    ok      = { icon = "✓", hl = "EasyTasksBadgeOk" },
    failed  = { icon = "✗", hl = "EasyTasksBadgeErr" },
    stopped = { icon = "■", hl = "EasyTasksBadgeHint" },
    idle    = { icon = "●", hl = "Comment" },
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

---@param run_id string
---@return integer?
local function _run_idx(run_id)
    for i, id in ipairs(_runs) do
        if id == run_id then return i end
    end
end

-- ── Info buffer ───────────────────────────────────────────────────────────────

---@param entry easytasks.RunEntry
---@return integer bufnr
local function _refresh_info_buf(entry)
    if not _info_buf or not vim.api.nvim_buf_is_valid(_info_buf) then
        _info_buf = utils.create_sratch_buffer(false, { bufhidden = "hide" })
    end

    local p    = entry.progress
    local fmt  = function(t) return os.date("%H:%M:%S", t) --[[@as string]] end
    local b    = _badge[entry.state] or _badge.idle

    ---@type {text:string, hl:string?, col:integer?}[]
    local rows = {
        { text = entry.task_name },
        { text = "" },
        { text = "status   " .. entry.state,      hl = b.hl, col = #"status   " },
        { text = "started  " .. fmt(p.start_time) },
    }
    if p.stop_time then
        table.insert(rows, { text = "stopped  " .. fmt(p.stop_time) })
    end
    if entry.waiting_for and #entry.waiting_for > 0 then
        table.insert(rows, { text = "" })
        table.insert(rows, { text = "waiting for", hl = "Label" })
        for _, dep in ipairs(entry.waiting_for) do
            table.insert(rows, { text = "  - " .. dep })
        end
    end
    if #p.events > 0 then
        table.insert(rows, { text = "" })
        table.insert(rows, { text = "events", hl = "Label" })
        for _, ev in ipairs(p.events) do
            local prefix = "  [" .. fmt(ev.time) .. "] "
            local lines  = vim.split(ev.message, "\n", { plain = true })
            table.insert(rows, { text = prefix .. lines[1] })
            for i = 2, #lines do
                table.insert(rows, { text = string.rep(" ", #prefix) .. lines[i] })
            end
        end
    end

    local texts = vim.tbl_map(function(r) return r.text end, rows)
    vim.bo[_info_buf].modifiable = true
    vim.api.nvim_buf_set_lines(_info_buf, 0, -1, false, texts)
    vim.bo[_info_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(_info_buf, _info_hl_ns, 0, -1)
    for i, r in ipairs(rows) do
        if r.hl then
            vim.api.nvim_buf_set_extmark(_info_buf, _info_hl_ns, i - 1, r.col or 0, {
                hl_group = r.hl, end_col = #r.text,
            })
        end
    end
    return _info_buf
end

---@return integer
local function _get_empty_buf()
    if not _empty_buf or not vim.api.nvim_buf_is_valid(_empty_buf) then
        local ns = vim.api.nvim_create_namespace("EasyTasksEmpty")
        _empty_buf = utils.create_sratch_buffer(false, { bufhidden = "hide" })
        vim.bo[_empty_buf].modifiable = true
        vim.api.nvim_buf_set_lines(_empty_buf, 0, -1, false, { "" })
        vim.bo[_empty_buf].modifiable = false
        vim.api.nvim_buf_set_extmark(_empty_buf, ns, 0, 0, {
            virt_text     = { { "No tasks", "Comment" } },
            virt_text_pos = "overlay",
        })
    end
    return _empty_buf
end

-- ── Buffer display ────────────────────────────────────────────────────────────

local function _set_win_buf(bufnr)
    if not _win or not vim.api.nvim_win_is_valid(_win) then return end
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    vim.wo[_win].winfixbuf = false
    vim.api.nvim_win_set_buf(_win, bufnr)
    vim.wo[_win].winfixbuf = true
end

local function _show_active()
    if not _active_run_id then
        _set_win_buf(_get_empty_buf())
        return
    end
    local entry = _run_map[_active_run_id]
    if not entry then return end

    if _active_page == 0 then
        _set_win_buf(_refresh_info_buf(entry))
    else
        local be = entry.bufnrs[_active_page]
        if be and vim.api.nvim_buf_is_valid(be.bufnr) then
            _set_win_buf(be.bufnr)
        else
            _active_page = 0
            _set_win_buf(_refresh_info_buf(entry))
        end
    end
end

-- ── Winbar ────────────────────────────────────────────────────────────────────

-- Each item: { kind, text }
--   kind 1 = croppable (task name)
--   kind 2 = fixed visible text (icons, time, punctuation)
--   kind 3 = zero-width escape (highlight groups, click regions)

---@param width integer
---@return string
local function _build_winbar(width)
    if #_runs == 0 then
        return "%#WinBar# %#Comment#No tasks%#WinBar#"
    end

    local active_idx = _active_run_id and _run_idx(_active_run_id)
    local items = {} ---@type {[1]:integer,[2]:string}[]
    local function push(kind, text) items[#items + 1] = { kind, text } end

    local jump_idx = 0

    for run_idx, run_id in ipairs(_runs) do
        local entry = _run_map[run_id]
        if not entry then goto continue end
        local b         = _badge[entry.state] or _badge.idle
        local is_active = run_idx == active_idx
        local tab_hl    = is_active and "%#EasyTasksActiveTab#" or "%#WinBar#"

        -- assign jump key for the info tab before building page_sfx so indices
        -- match _jump_targets order (info tab first, then buffer tabs)
        local task_key = ""
        if _jump_mode then
            jump_idx  = jump_idx + 1
            task_key  = _JUMP_KEYS:sub(jump_idx, jump_idx)
        end

        -- buffer tabs shown for every task; task name itself is the info tab
        local page_sfx  = ""
        if #entry.bufnrs > 0 then
            local parts = {}
            for pi, be in ipairs(entry.bufnrs) do
                local page_id = run_idx * 10 + pi
                local is_cur  = is_active and pi == _active_page
                local part
                if _jump_mode then
                    jump_idx = jump_idx + 1
                    local k  = _JUMP_KEYS:sub(jump_idx, jump_idx)
                    if k ~= "" and #be.label > 0 then
                        -- replace first label char with jump key; width unchanged
                        local rest     = vim.fn.strcharpart(be.label, 1)
                        local after_hl = is_cur and tab_hl or "%#Comment#"
                        if is_cur then
                            part = string.format(
                                "%%%d@v:lua._EasyTasksWbc@%%#EasyTasksJumpKey#%s%s%s%%X",
                                page_id, k, after_hl, rest)
                        else
                            part = string.format(
                                "%%%d@v:lua._EasyTasksWbc@%%#EasyTasksJumpKey#%s%s%s%s%%X",
                                page_id, k, after_hl, rest, tab_hl)
                        end
                    end
                end
                if not part then
                    if is_cur then
                        part = string.format(
                            "%%%d@v:lua._EasyTasksWbc@%s%%X", page_id, be.label)
                    else
                        part = string.format(
                            "%%%d@v:lua._EasyTasksWbc@%%#Comment#%s%s%%X",
                            page_id, be.label, tab_hl)
                    end
                end
                parts[#parts + 1] = part
            end
            page_sfx = " [" .. table.concat(parts, "|") .. "]"
        end

        if run_idx > 1 then
            push(3, "%#Comment#")
            push(2, "│")
        end
        push(2, " ")
        push(3, tab_hl)
        push(3, string.format("%%%d@v:lua._EasyTasksWbc@", run_idx * 10))
        push(3, "%#" .. b.hl .. "#")
        push(2, b.icon .. " ")
        push(3, tab_hl)
        if _jump_mode and task_key ~= "" then
            push(3, "%#EasyTasksJumpKey#")
            push(2, task_key)
            push(3, tab_hl)
            push(1, vim.fn.strcharpart(entry.task_name, 1))
        else
            push(1, entry.task_name)
        end
        push(3, "%X")
        if page_sfx ~= "" then push(3, page_sfx) end
        push(3, "%#WinBar#")
        push(2, " ")

        ::continue::
    end

    -- measure visible width (kind=3 items are zero-width)
    local vis_w, n_crop = 0, 0
    for _, it in ipairs(items) do
        if it[1] ~= 3 then
            vis_w = vis_w + vim.fn.strdisplaywidth(it[2])
            if it[1] == 1 then n_crop = n_crop + 1 end
        end
    end

    -- proportionally crop task names on overflow
    local out = {}
    if vis_w > width and n_crop > 0 then
        local overflow  = vis_w - width
        local base_cut  = math.floor(overflow / n_crop)
        local remainder = overflow % n_crop
        local ci        = 0
        for _, it in ipairs(items) do
            local text = it[2]
            if it[1] == 1 then
                ci           = ci + 1
                local cut    = base_cut + (ci <= remainder and 1 or 0)
                local cw     = vim.fn.strdisplaywidth(text)
                local target = math.max(cw - cut, 2)
                if target < cw then
                    text = vim.fn.strcharpart(text, 0, math.max(target - 1, 1)) .. "…"
                end
            end
            out[#out + 1] = text
        end
    else
        for _, it in ipairs(items) do out[#out + 1] = it[2] end
    end

    return table.concat(out)
end

local function _refresh_winbar()
    if not _win or not vim.api.nvim_win_is_valid(_win) then return end
    vim.wo[_win].winbar = _build_winbar(vim.api.nvim_win_get_width(_win))
end

-- ── Winbar click handler (global — required by %N@v:lua.fn@ syntax) ───────────

---@param id integer  run_idx*10 for tab clicks, run_idx*10+page_idx for page labels
_G._EasyTasksWbc = function(id)
    local run_idx  = math.floor(id / 10)
    local page_idx = id % 10
    local run_id   = _runs[run_idx]
    if not run_id then return end
    _active_run_id = run_id
    if page_idx == 0 then
        -- task name click: always go to info page
        _active_page = 0
    else
        -- buffer tab click: pi=1→bufnr[1] (page 1), pi=2→bufnr[2] (page 2), etc.
        _active_page = page_idx
    end
    _show_active()
    _refresh_winbar()
end

-- ── State change subscription ─────────────────────────────────────────────────

---Best page index for an entry: highest-priority buffer, or 0 if no buffers.
---The info page (0) is treated as priority -1 so any real buffer beats it.
---@param entry easytasks.RunEntry
---@return integer
local function _best_page(entry)
    local best_idx, best_pri = 0, -1
    for i, be in ipairs(entry.bufnrs) do
        local pri = be.priority or 0
        if pri > best_pri then
            best_pri = pri; best_idx = i
        end
    end
    return best_idx
end

---@param run_id string
---@param entry  easytasks.RunEntry
local function _on_state_change(run_id, entry)
    if not _win or not vim.api.nvim_win_is_valid(_win) then
        M.open()
        return
    end

    local is_new              = _run_map[run_id] == nil
    local prev_count          = _known_buf_counts[run_id] or 0
    _run_map[run_id]          = entry
    _known_buf_counts[run_id] = #entry.bufnrs

    if is_new then
        table.insert(_runs, run_id)
        local cur = _active_run_id and _run_map[_active_run_id]
        local cur_done = not cur
            or cur.state == "ok" or cur.state == "failed" or cur.state == "stopped"
        if cur_done then
            _active_run_id = run_id
            _active_page   = _best_page(entry)
        end
    end

    if _active_run_id == run_id then
        vim.schedule(function()
            if not _win or not vim.api.nvim_win_is_valid(_win) then return end
            if vim.api.nvim_get_current_win() == _win then return end
            if #entry.bufnrs > prev_count then
                -- New buffer(s) added: advance to the highest-priority page if it
                -- beats the one currently shown (-1 for the info page, otherwise
                -- the buffer's own priority).
                local cur_pri = _active_page == 0
                    and -1
                    or (entry.bufnrs[_active_page] and entry.bufnrs[_active_page].priority or 0)
                local best = _best_page(entry)
                local best_pri = best > 0
                    and (entry.bufnrs[best].priority or 0)
                    or -1
                if best_pri > cur_pri then _active_page = best end
            end
            _show_active()
        end)
    end

    vim.schedule(_refresh_winbar)
end

-- ── Cleanup ───────────────────────────────────────────────────────────────────

---@param run_id string
local function _on_dispose(run_id)
    local idx = _run_idx(run_id)
    if not idx then return end
    table.remove(_runs, idx)
    _run_map[run_id]          = nil
    _known_buf_counts[run_id] = nil

    if _active_run_id == run_id then
        _active_run_id = _runs[#_runs]
        local e = _active_run_id and _run_map[_active_run_id]
        _active_page = e and _best_page(e) or 0
        -- Switch synchronously so the window leaves the buffer before it is deleted.
        _show_active()
        _refresh_winbar()
    else
        vim.schedule(_refresh_winbar)
    end
end

local function _on_close()
    vim.api.nvim_clear_autocmds({ group = _augroup })
    _win              = nil
    _active_run_id    = nil
    _active_page      = 0
    _runs             = {}
    _run_map          = {}
    _known_buf_counts = {}
    if _info_buf and vim.api.nvim_buf_is_valid(_info_buf) then
        pcall(vim.api.nvim_buf_delete, _info_buf, { force = true })
        _info_buf = nil
    end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.open()
    if _win and vim.api.nvim_win_is_valid(_win) then return end

    _setup_hl()

    local prev_win = vim.api.nvim_get_current_win()
    vim.cmd("bot split")
    _win                        = vim.api.nvim_get_current_win()

    vim.wo[_win].winfixheight   = true
    vim.wo[_win].winfixbuf      = true
    vim.wo[_win].number         = false
    vim.wo[_win].relativenumber = false
    vim.wo[_win].signcolumn     = "no"
    vim.wo[_win].spell          = false
    vim.wo[_win].wrap           = false

    local height                = _height_ratio
        and math.max(6, math.floor(vim.o.lines * _height_ratio))
        or math.max(6, math.floor(vim.o.lines * 0.22))
    vim.api.nvim_win_set_height(_win, height)

    vim.api.nvim_set_current_win(prev_win)

    -- populate from already-running tasks, newest first
    local all = exec.get_all()
    local ids = vim.tbl_keys(all)
    table.sort(ids, function(a, b)
        return (tonumber(a:match("#(%d+)$")) or 0) < (tonumber(b:match("#(%d+)$")) or 0)
    end)
    for _, id in ipairs(ids) do
        table.insert(_runs, id)
        _run_map[id] = all[id]
    end
    if #_runs > 0 then
        -- prefer the outermost waiting task (root waiting for deps); else newest
        local pick = _runs[#_runs]
        for _, id in ipairs(_runs) do
            if (_run_map[id] or {}).state == "waiting" then pick = id; break end
        end
        _active_run_id = pick
        local e = _run_map[_active_run_id]
        _active_page = e and _best_page(e) or 0
    end

    _show_active()
    _refresh_winbar()

    if not _subscribed then
        exec.on_state_change(_on_state_change)
        exec.on_dispose(_on_dispose)
        _subscribed = true
    end

    vim.api.nvim_create_autocmd("WinClosed", {
        group    = _augroup,
        callback = function(args)
            if tonumber(args.match) == _win then
                if vim.api.nvim_win_is_valid(_win) then
                    _height_ratio = vim.api.nvim_win_get_height(_win) / vim.o.lines
                end
                _on_close()
            end
        end,
    })

    -- re-apply height when the user opens new splits so the panel stays pinned
    vim.api.nvim_create_autocmd("WinNew", {
        group    = _augroup,
        callback = function()
            vim.schedule(function()
                if _win and vim.api.nvim_win_is_valid(_win) then
                    local target = math.max(6, math.floor(vim.o.lines * (_height_ratio or 0.22)))
                    pcall(vim.api.nvim_win_set_height, _win, target)
                end
            end)
        end,
    })

    vim.api.nvim_create_autocmd("WinResized", {
        group    = _augroup,
        callback = function()
            if _win and vim.api.nvim_win_is_valid(_win) then
                _refresh_winbar()
            end
        end,
    })
end

function M.toggle()
    if _win and vim.api.nvim_win_is_valid(_win) then
        _height_ratio = vim.api.nvim_win_get_height(_win) / vim.o.lines
        vim.api.nvim_win_close(_win, false)
    else
        M.open()
    end
end

--- Show jump-key hints in the winbar, then navigate to whichever tab the user picks.
function M.jump()
    M.open()
    if #_runs == 0 then return end

    -- build flat target list in the same order _build_winbar assigns keys:
    -- info tab then buffer tabs for each run
    _jump_targets = {}
    for _, run_id in ipairs(_runs) do
        local entry = _run_map[run_id]
        if not entry then goto continue end
        table.insert(_jump_targets, { run_id = run_id, page = 0 })
        for pi = 1, #entry.bufnrs do
            table.insert(_jump_targets, { run_id = run_id, page = pi })
        end
        ::continue::
    end

    _jump_mode = true
    _refresh_winbar()
    vim.cmd("redraw")

    local char = vim.fn.getcharstr()
    _jump_mode = false

    if char ~= "\27" then
        for i, target in ipairs(_jump_targets) do
            if _JUMP_KEYS:sub(i, i) == char then
                _active_run_id = target.run_id
                _active_page   = target.page
                _show_active()
                break
            end
        end
    end

    _jump_targets = {}

    _refresh_winbar()
end

return M
