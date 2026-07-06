local utils                     = require('easytasks.util.ui_util')
local exec                      = require('easytasks.runner.exec')
local throttle                  = require('easytasks.util.throttle')

---@class easytasks.ui.status_panel
local M                         = {}

-- ── State ─────────────────────────────────────────────────────────────────────

local _win                      = nil ---@type integer?
local _height_ratio             = nil ---@type number?

local _runs                     = {} ---@type string[]   run_ids, newest first
local _run_map                  = {} ---@type table<string, easytasks.RunEntry>
local _known_buf_counts         = {} ---@type table<string, integer>  bufnr count as of last notification

local _active_run_id            = nil ---@type string?
local _active_page              = 0 -- 0 = info scratch, 1..n = entry.bufnrs index

-- Restarting a task already in the panel is an exception to the "don't disturb a
-- focused user" rule: the re-run takes over the view even while the panel is
-- focused. _restart_pending_name is the task name of an active run that was just
-- disposed (a same-named re-run arriving next is the restart); _restart_follow_run
-- is the run_id we keep showing past the focus guard until it finishes.
local _restart_pending_name     = nil ---@type string?
local _restart_follow_run       = nil ---@type string?

local _subscribed               = false
local _attached_bufs            = {} ---@type table<integer, true>  bufnrs where nvim_buf_attach has been called
local _unread_bufnrs            = {} ---@type table<integer, true>  bufnrs with new lines added while not visible

-- Flat, winbar-order map from global page number to its navigable target. Every
-- tab and page the winbar draws gets one sequential number (left to right);
-- _build_winbar rebuilds this each render and it is the single source of truth
-- for click handling and `:Tasks panel jump N`.
local _page_targets             = {} ---@type { run_id: string, page: integer }[]

local _log_buf                  = nil ---@type integer?
local _empty_buf                = nil ---@type integer?

local _shell_counter            = 0
local _shell_entries            = {} ---@type table<string, easytasks.RunEntry>  persists across panel open/close

---@class easytasks.LogSub
---@field cancel_report fun()
---@field run_id        string
---@field report_count   integer

local _log_sub                  = nil ---@type easytasks.LogSub?

local _augroup                  = vim.api.nvim_create_augroup("EasyTasksStatusPanel", { clear = true })

local _set_win_buf ---@type fun(bufnr: integer)  forward declaration (defined after _attach_buf)
local _refresh_winbar ---@type fun()  forward declaration (defined after _build_winbar)
local _throttled_refresh_winbar = throttle.throttle_wrap(100, function()
    vim.schedule(_refresh_winbar)
end)

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
    vim.api.nvim_set_hl(0, "EasyTasksBadgeMuted", { link = "WinBar", default = true })
    vim.api.nvim_set_hl(0, "EasyTasksUnread", { link = "DiagnosticHint", default = true })
end

---@type table<easytasks.TaskState, {icon:string, hl:string}>
local _badge = {
    running = { icon = "▶", hl = "EasyTasksBadgeOk" },
    waiting = { icon = "⧗", hl = "EasyTasksBadgeWarn" },
    ok      = { icon = "✓", hl = "EasyTasksBadgeOk" },
    failed  = { icon = "✗", hl = "EasyTasksBadgeErr" },
    stopped = { icon = "✗", hl = "EasyTasksBadgeHint" },
    idle    = { icon = "●", hl = "EasyTasksBadgeMuted" },
}

-- shell tabs are not tasks, so they show a fixed neutral badge regardless of
-- whether the shell is still running or has exited.
local _shell_badge = { icon = "❯", hl = "EasyTasksBadgeMuted" }

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- `vim.wo[win].opt = val` sets both the window-local value AND nvim's hidden
-- global default (the value new windows inherit), even for options with no
-- real global scope (winfixbuf, number, signcolumn, ...) — so every panel open
-- would silently leak its window settings into every future plain window.
-- Force `scope = "local"` to keep these changes confined to `win`.
---@param win integer
---@param opt string
---@param val any
local function _setlocal(win, opt, val)
    vim.api.nvim_set_option_value(opt, val, { win = win, scope = "local" })
end

---@param run_id string
---@return integer?
local function _run_idx(run_id)
    for i, id in ipairs(_runs) do
        if id == run_id then return i end
    end
end

-- Find the frame kind ("col"/"row") of the node directly containing `target`.
---@param node   table    a vim.fn.winlayout() node
---@param target integer  window id
---@return string?
local function _parent_frame(node, target)
    if node[1] == "leaf" then return nil end
    for _, child in ipairs(node[2]) do
        if child[1] == "leaf" and child[2] == target then return node[1] end
    end
    for _, child in ipairs(node[2]) do
        local kind = _parent_frame(child, target)
        if kind then return kind end
    end
    return nil
end

-- Whether re-pinning the panel to its fixed height is safe. Forcing a
-- smaller-than-full height only works when the panel sits vertically stacked
-- with another window that can absorb the freed rows. If the panel is the only
-- window, or only shares its row with vertical splits (nothing above/below it),
-- shrinking it strands the leftover rows in the command area — 'winfixheight'
-- forbids the siblings from growing to reclaim them. Only a "col" parent frame
-- gives the panel a vertical neighbour.
---@return boolean
local function _panel_pinnable()
    if not _win or not vim.api.nvim_win_is_valid(_win) then return false end
    return _parent_frame(vim.fn.winlayout(), _win) == "col"
end

-- ── Info buffer ───────────────────────────────────────────────────────────────

local function _cancel_log_sub()
    if _log_sub then
        _log_sub.cancel_report()
        _log_sub = nil
    end
end

---@param entry  easytasks.RunEntry
---@param run_id string
---@return integer bufnr
local function _refresh_log_buf(entry, run_id)
    if not _log_buf then
        _log_buf = utils.create_scratch_buffer(false, { bufhidden = "hide" }, function()
            _log_buf = nil
        end)
        vim.api.nvim_buf_set_var(_log_buf, "easytasks_autoscroll", true)
    end

    if _log_sub and _log_sub.run_id ~= run_id then _cancel_log_sub() end
    if _log_sub and _log_sub.run_id == run_id then return _log_buf end

    local fmt = function(t) return os.date("%H:%M:%S", t) --[[@as string]] end

    -- snapshot all events accumulated so far
    local lines = {}
    for _, ev in ipairs(entry.reports) do
        local prefix      = "[" .. fmt(ev.time) .. "] "
        local ev_lines    = vim.split(ev.message, "\n", { plain = true })
        lines[#lines + 1] = prefix .. ev_lines[1]
        for j = 2, #ev_lines do
            lines[#lines + 1] = string.rep(" ", #prefix) .. ev_lines[j]
        end
    end
    if #lines == 0 then lines = { "" } end

    vim.bo[_log_buf].modifiable = true
    vim.api.nvim_buf_set_lines(_log_buf, 0, -1, false, lines)
    vim.bo[_log_buf].modifiable = false

    -- subscribe: append each new event as it arrives
    local cancel_report = exec.on_report(function(changed_id, ev)
        if changed_id ~= run_id then return end
        if not _log_sub or _log_sub.run_id ~= run_id then return end
        if not _log_buf or not vim.api.nvim_buf_is_valid(_log_buf) then return end
        if _active_run_id ~= run_id or _active_page ~= 0 then return end

        local prefix    = "[" .. fmt(ev.time) .. "] "
        local ev_lines  = vim.split(ev.message, "\n", { plain = true })
        local new_lines = { prefix .. ev_lines[1] }
        for j = 2, #ev_lines do
            new_lines[#new_lines + 1] = string.rep(" ", #prefix) .. ev_lines[j]
        end
        vim.bo[_log_buf].modifiable = true
        vim.api.nvim_buf_set_lines(_log_buf, -1, -1, false, new_lines)
        vim.bo[_log_buf].modifiable = false
        _log_sub.report_count = _log_sub.report_count + 1
    end)

    _log_sub = {
        cancel_report = cancel_report,
        run_id        = run_id,
        report_count  = #entry.reports,
    }

    return _log_buf
end

---@return integer
local function _get_empty_buf()
    if not _empty_buf or not vim.api.nvim_buf_is_valid(_empty_buf) then
        local ns = vim.api.nvim_create_namespace("EasyTasksEmpty")
        _empty_buf = utils.create_scratch_buffer(false, { bufhidden = "hide" })
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

---@param bufnr integer
local function _attach_buf(bufnr)
    if _attached_bufs[bufnr] then return end
    _attached_bufs[bufnr] = true
    local ok, autoscroll = pcall(vim.api.nvim_buf_get_var, bufnr, "easytasks_autoscroll")
    local do_autoscroll = ok and autoscroll
    vim.api.nvim_buf_attach(bufnr, false, {
        on_lines = function()
            if not _win or not vim.api.nvim_win_is_valid(_win) then return true end
            local is_visible = vim.api.nvim_win_get_buf(_win) == bufnr
            if is_visible then
                if do_autoscroll then
                    vim.schedule(function()
                        if not _win or not vim.api.nvim_win_is_valid(_win) then return end
                        if vim.api.nvim_win_get_buf(_win) ~= bufnr then return end
                        local last = vim.api.nvim_buf_line_count(bufnr)
                        pcall(vim.api.nvim_win_set_cursor, _win, { last, 0 })
                    end)
                end
            else
                _unread_bufnrs[bufnr] = true
                _throttled_refresh_winbar()
            end
        end,
        on_detach = function()
            _attached_bufs[bufnr] = nil
            _unread_bufnrs[bufnr] = nil
        end,
    })
    -- Switch the panel away before the buffer disappears. No group so this
    -- autocmd outlives panel open/close cycles (buffers do too).
    vim.api.nvim_create_autocmd("BufUnload", {
        buffer   = bufnr,
        once     = true,
        callback = function()
            if not _win or not vim.api.nvim_win_is_valid(_win) then return end
            if vim.api.nvim_win_get_buf(_win) ~= bufnr then return end
            _set_win_buf(_get_empty_buf())
        end,
    })
end

_set_win_buf = function(bufnr)
    if not _win or not vim.api.nvim_win_is_valid(_win) then return end
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    _setlocal(_win, "winfixbuf", false)
    vim.api.nvim_win_set_buf(_win, bufnr)
    _setlocal(_win, "winfixbuf", true)
    _unread_bufnrs[bufnr] = nil
    if vim.bo[bufnr].buftype == "terminal" then
        local last = vim.api.nvim_buf_line_count(bufnr)
        vim.api.nvim_win_set_cursor(_win, { last, 0 })
    end
    _attach_buf(bufnr)
end

local function _show_active()
    if not _active_run_id then
        _cancel_log_sub()
        _set_win_buf(_get_empty_buf())
        return
    end
    local entry = _run_map[_active_run_id]
    if not entry then return end

    if entry.is_shell then
        _cancel_log_sub()
        local be = entry.bufnrs[1]
        if be and vim.api.nvim_buf_is_valid(be.bufnr) then
            _set_win_buf(be.bufnr)
        end
        return
    end

    if _active_page == 0 then
        _set_win_buf(_refresh_log_buf(entry, _active_run_id))
    else
        _cancel_log_sub()
        local be = entry.bufnrs[_active_page]
        if be and vim.api.nvim_buf_is_valid(be.bufnr) then
            _set_win_buf(be.bufnr)
        else
            _active_page = 0
            _set_win_buf(_refresh_log_buf(entry, _active_run_id))
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
        return "%#WinBar# %#EasyTasksBadgeMuted#No tasks%#WinBar#"
    end

    local active_idx = _active_run_id and _run_idx(_active_run_id)
    local items = {} ---@type {[1]:integer,[2]:string}[]
    local function push(kind, text) items[#items + 1] = { kind, text } end

    -- rebuild the global page numbering as we render; click/jump read it back.
    _page_targets = {}
    local gnum = 0 -- running global page number, incremented per navigable target

    for run_idx, run_id in ipairs(_runs) do
        local entry = _run_map[run_id]
        if not entry then goto continue end
        local b                 = entry.is_shell and _shell_badge or (_badge[entry.state] or _badge.idle)
        local is_active         = run_idx == active_idx
        local tab_hl            = is_active and "%#EasyTasksActiveTab#" or "%#WinBar#"

        -- the task name tab is its info page (page 0) and takes the first number for
        -- this run; shells have no info page, so the name tab is the terminal (we
        -- still record page 0 — _show_active resolves shells to their terminal buf).
        gnum                    = gnum + 1
        local name_num          = gnum
        _page_targets[name_num] = { run_id = run_id, page = 0 }

        -- buffer tabs shown for every task; task name itself is the info tab.
        -- shell tabs have no info/log page — the name tab is the terminal itself.
        local page_sfx          = ""
        if #entry.bufnrs > 0 and not entry.is_shell then
            local parts = {}
            for pi, be in ipairs(entry.bufnrs) do
                gnum                    = gnum + 1
                local page_num          = gnum
                _page_targets[page_num] = { run_id = run_id, page = pi }
                local is_cur            = is_active and pi == _active_page
                local has_unread        = _unread_bufnrs[be.bufnr]
                local lbl               = page_num .. ":" .. be.label
                local part
                if has_unread then
                    if is_cur then
                        part = string.format(
                            "%%%d@v:lua._EasyTasksWbc@%s%%#EasyTasksUnread#•%s%%X",
                            page_num, lbl, tab_hl)
                    else
                        part = string.format(
                            "%%%d@v:lua._EasyTasksWbc@%%#EasyTasksBadgeMuted#%s%%#EasyTasksUnread#•%s%%X",
                            page_num, lbl, tab_hl)
                    end
                elseif is_cur then
                    part = string.format(
                        "%%%d@v:lua._EasyTasksWbc@%s%%X", page_num, lbl)
                else
                    part = string.format(
                        "%%%d@v:lua._EasyTasksWbc@%%#EasyTasksBadgeMuted#%s%s%%X",
                        page_num, lbl, tab_hl)
                end
                parts[#parts + 1] = part
            end
            page_sfx = " [" .. table.concat(parts, "|") .. "]"
        end

        if run_idx > 1 then
            push(3, "%#EasyTasksBadgeMuted#")
            push(2, "│")
        end
        push(2, " ")
        push(3, string.format("%%%d@v:lua._EasyTasksWbc@", name_num))
        push(3, "%#" .. b.hl .. "#")
        push(2, b.icon .. " ")
        push(3, tab_hl)
        push(2, name_num .. ":")
        push(1, entry.task_name)
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

_refresh_winbar = function()
    if not _win or not vim.api.nvim_win_is_valid(_win) then return end
    vim.wo[_win].winbar = _build_winbar(vim.api.nvim_win_get_width(_win))
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

---@param run_id string?
---@param page   integer?  explicit page index; defaults to best page of the entry or 0
local function _set_active_run(run_id, page)
    -- Switching to any other run cancels an in-progress restart follow.
    if run_id ~= _restart_follow_run then _restart_follow_run = nil end
    _active_run_id = run_id
    local e        = run_id and _run_map[run_id]
    _active_page   = page ~= nil and page or (e and _best_page(e) or 0)
end

---Advance the shown page to the entry's highest-priority buffer, but only if it
---outranks the page currently shown. The info page (0) counts as priority -1, so
---any real buffer beats it; otherwise the buffer's own priority is compared.
---@param entry easytasks.RunEntry
local function _activate_best_page(entry)
    local cur_pri = _active_page == 0
        and -1
        or (entry.bufnrs[_active_page] and entry.bufnrs[_active_page].priority or 0)
    local best = _best_page(entry)
    local best_pri = best > 0
        and (entry.bufnrs[best].priority or 0)
        or -1
    if best_pri > cur_pri then _active_page = best end
end

---True while the user has the panel window focused (working inside it).
---@return boolean
local function _is_focused()
    return _win ~= nil and vim.api.nvim_get_current_win() == _win
end

---Render the active run after a state change. Skipped while the user is focused
---in the panel so we don't disturb them — except for a restarted run, which keeps
---the view past the focus guard. When new buffers appeared, advances to the best
---page first.
---@param entry      easytasks.RunEntry
---@param prev_count integer  buffer count before this state change
---@param run_id     string   the run this entry belongs to
local function _follow_active_run(entry, prev_count, run_id)
    if not _win or not vim.api.nvim_win_is_valid(_win) then return end
    local force = run_id == _restart_follow_run
    if _is_focused() and not force then return end
    if #entry.bufnrs > prev_count then
        _activate_best_page(entry)
    end
    _show_active()
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

    for i = prev_count + 1, #entry.bufnrs do
        local be = entry.bufnrs[i]
        if be and vim.api.nvim_buf_is_valid(be.bufnr) then
            _attach_buf(be.bufnr)
        end
    end

    if is_new then table.insert(_runs, run_id) end

    -- A re-run of the task that was active when it got disposed (a restart) takes
    -- over the panel even while it's focused, then stays followed until it ends.
    local is_restart = is_new and entry.primary
        and _restart_pending_name == entry.task_name
    if is_new and entry.primary then _restart_pending_name = nil end

    -- A run the user just launched (run/restart/parallel) takes over the display,
    -- unless they're working inside the panel. Dependency runs aren't `primary`,
    -- so they never steal the view. Always show something if nothing is active.
    if not _active_run_id
        or (is_new and entry.primary and not _is_focused())
        or is_restart then
        _set_active_run(run_id)
        if is_restart then _restart_follow_run = run_id end
    end

    -- Once a restart-followed run finishes, stop overriding the focus guard so its
    -- final state change doesn't disturb a focused user.
    if _restart_follow_run == run_id
        and entry.state ~= "running" and entry.state ~= "waiting" then
        _restart_follow_run = nil
    end

    if _active_run_id == run_id then
        vim.schedule(function() _follow_active_run(entry, prev_count, run_id) end)
    end

    vim.schedule(_refresh_winbar)
end

-- ── Winbar click handler (global — required by %N@v:lua.fn@ syntax) ───────────

---@param id integer  global page number assigned by _build_winbar
_G._EasyTasksWbc = function(id)
    local target = _page_targets[id]
    if not target then return end
    _set_active_run(target.run_id, target.page)
    _show_active()
    _refresh_winbar()
end

-- ── Cleanup ───────────────────────────────────────────────────────────────────

---@param run_id string
local function _on_dispose(run_id)
    local idx = _run_idx(run_id)
    if not idx then return end
    local was_active = _active_run_id == run_id
    local name       = (_run_map[run_id] or {}).task_name
    table.remove(_runs, idx)
    _run_map[run_id]          = nil
    _known_buf_counts[run_id] = nil

    if was_active then
        -- A restart disposes the old run, then synchronously launches the new one.
        -- Remember this run's name so that same-tick re-run is recognised as a
        -- restart and takes over the focused panel. Cleared next tick so a plain
        -- manual disposal doesn't linger as a false restart hint.
        _restart_pending_name = name
        vim.schedule(function() _restart_pending_name = nil end)
        _set_active_run(_runs[#_runs])
        -- Switch synchronously so the window leaves the buffer before it is deleted.
        _show_active()
        _refresh_winbar()
    else
        vim.schedule(_refresh_winbar)
    end
end

--- Drop a standalone shell tab from the panel. Invoked from the terminal
--- buffer's BufDelete/BufWipeout autocmd, so the buffer is already being deleted
--- — we must NOT delete it again here (that raises E937 while it is in use); we
--- only clean up the panel's bookkeeping. _on_dispose switches the window away
--- from the dying buffer synchronously so the panel doesn't end up on it.
---@param run_id string
local function _close_shell(run_id)
    if not _shell_entries[run_id] then return end
    _shell_entries[run_id] = nil
    _on_dispose(run_id)
end

local function _on_close()
    _cancel_log_sub()
    vim.api.nvim_clear_autocmds({ group = _augroup })
    _win = nil
    _set_active_run(nil)
    _runs             = {}
    _run_map          = {}
    _known_buf_counts = {}
    _unread_bufnrs    = {}
    if _log_buf and vim.api.nvim_buf_is_valid(_log_buf) then
        pcall(vim.api.nvim_buf_delete, _log_buf, { force = true })
        _log_buf = nil
    end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.open()
    if _win and vim.api.nvim_win_is_valid(_win) then return end

    _setup_hl()

    local prev_win = vim.api.nvim_get_current_win()
    vim.cmd("bot split")
    _win                        = vim.api.nvim_get_current_win()

    _setlocal(_win, "winfixheight", true)
    _setlocal(_win, "winfixbuf", true)
    _setlocal(_win, "number", false)
    _setlocal(_win, "relativenumber", false)
    _setlocal(_win, "signcolumn", "no")
    _setlocal(_win, "spell", false)
    _setlocal(_win, "wrap", false)

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
        for _, be in ipairs(all[id].bufnrs or {}) do
            if vim.api.nvim_buf_is_valid(be.bufnr) then
                _attach_buf(be.bufnr)
            end
        end
    end
    -- re-attach standalone shell tabs (they outlive panel open/close)
    for id, entry in pairs(_shell_entries) do
        table.insert(_runs, id)
        _run_map[id] = entry
        for _, be in ipairs(entry.bufnrs) do
            if vim.api.nvim_buf_is_valid(be.bufnr) then
                _attach_buf(be.bufnr)
            end
        end
    end
    if #_runs > 0 then
        -- prefer the outermost waiting task (root waiting for deps); else newest
        local pick = _runs[#_runs]
        for _, id in ipairs(_runs) do
            if (_run_map[id] or {}).state == "waiting" then
                pick = id; break
            end
        end
        _set_active_run(pick)
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
            -- 'winbar' is copied onto a freshly split window (most other
            -- window-local options, like 'winfixbuf', and window-local
            -- variables are not). If someone splits the panel window itself,
            -- the new sibling inherits our winbar text verbatim (click regions
            -- included), but it is never re-rendered by _refresh_winbar (which
            -- only targets `_win`), so its page numbers go stale as soon as the
            -- panel state changes and clicking it jumps to the wrong target.
            -- Detect the inherited winbar text and confirm it isn't already our
            -- marked panel window, then strip every panel-special option back
            -- off immediately so the sibling reverts to a plain window.
            local new_win = vim.api.nvim_get_current_win()
            if _win and new_win ~= _win and vim.api.nvim_win_is_valid(_win)
                and vim.wo[new_win].winbar ~= ""
                and vim.wo[new_win].winbar == vim.wo[_win].winbar then
                vim.api.nvim_win_call(new_win, function()
                    vim.cmd("setlocal winbar< winfixheight< winfixbuf< number< relativenumber< signcolumn< spell< wrap<")
                end)
            end
            vim.schedule(function()
                -- Only re-pin when the panel has a vertical neighbour to absorb
                -- the resize; otherwise (sole window, or vsplit sibling) shrinking
                -- it strands the freed rows in the command area.
                if _panel_pinnable() then
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

--- Activate the nth panel page (1-based, left to right, matching the number
--- prefixes shown in the winbar) and focus the panel on it. The numbering is
--- global across every tab and page — a task's name/info tab, each of its buffer
--- pages, and each shell all get one sequential number. Accepts both an argument
--- (`:Tasks panel jump 3`) and a command count (`:3Tasks panel jump`).
---@param n integer?  page number; defaults to 1 when omitted or non-positive
function M.jump(n)
    M.open()
    if not n or n <= 0 then return end
    if not n then
        require("easytasks.ui").notify_warning("page number required")
        return
    end
    local target = _page_targets[n]
    if not target then
        return
    end
    _set_active_run(target.run_id, target.page)
    _show_active()
    _refresh_winbar()
    if _win and vim.api.nvim_win_is_valid(_win) then
        vim.api.nvim_set_current_win(_win)
    end
end

--- Open an interactive shell in a standalone panel tab (not backed by a task).
--- The tab shows a fixed neutral badge and stays when the shell exits; it is only
--- removed once its terminal buffer is deleted.
---@param opts? { cmd?: string|string[], cwd?: string, label?: string }
function M.open_shell(opts)
    opts = opts or {}
    M.open()

    local term        = require("easytasks.util.term")
    -- adding '--' as a no-op operator so that therminal buffer is not closed by noevim when the shell exists
    local cmd         = opts.cmd or { vim.o.shell, '--' }

    _shell_counter    = _shell_counter + 1
    local run_id      = "shell$" .. _shell_counter

    local entry ---@type easytasks.RunEntry  forward ref for on_exit
    local on_done     = require("easytasks.util.Signal").new()

    local handle, err = term.spawn(cmd, {
        cwd     = opts.cwd,
        on_exit = function()
            -- keep the tab and its neutral badge; just mark it finished so newly
            -- started task tabs are free to take focus from an exited shell.
            if entry and entry.state == "running" then entry.state = "stopped" end
            on_done:emit()
        end,
    })
    if not handle then
        require("easytasks.ui").notify_error("shell failed to start: " .. tostring(err))
        return
    end

    local label            = opts.label
        or (type(cmd) == "table" and cmd[1] and vim.fn.fnamemodify(cmd[1], ":t"))
        or "shell"

    entry                  = {
        task_name = label,
        state     = "running",
        is_shell  = true,
        bufnrs    = { { bufnr = handle.bufnr, label = label, priority = 0 } },
        reports   = {},
        done      = on_done,
    }

    _shell_entries[run_id] = entry

    -- the tab lives as long as its terminal buffer does; remove it when the user
    -- deletes/wipes the buffer.
    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        buffer   = handle.bufnr,
        once     = true,
        callback = function() _close_shell(run_id) end,
    })

    -- register the tab, then force it active and focus the terminal for input.
    _on_state_change(run_id, entry)
    _set_active_run(run_id)
    _show_active()
    _refresh_winbar()

    if _win and vim.api.nvim_win_is_valid(_win) then
        vim.api.nvim_set_current_win(_win)
        vim.cmd("startinsert")
    end
end

---@param state easytasks.TaskState
---@return boolean
local function _is_finished(state)
    return state ~= "running" and state ~= "waiting"
end

--- Tabs eligible for disposal: finished task runs (tracked by the runner) and
--- finished standalone shell tabs (panel-only state). Running/waiting tabs are
--- excluded. Sorted by label.
---@return { run_id: string, label: string }[]
function M.disposable_entries()
    local out = {}
    local function add(run_id, entry)
        out[#out + 1] = { run_id = run_id, label = entry.task_name .. "  [" .. entry.state .. "]" }
    end
    for run_id, entry in pairs(exec.get_all()) do
        if not entry.ephemeral and _is_finished(entry.state) then add(run_id, entry) end
    end
    for run_id, entry in pairs(_shell_entries) do
        if _is_finished(entry.state) then add(run_id, entry) end
    end
    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end

--- Dispose a finished tab by run_id, routing shell tabs and task runs to the
--- right disposer.
---@param run_id string
---@return boolean ok, string? err
function M.dispose_entry(run_id)
    if _shell_entries[run_id] then return M.dispose_shell(run_id) end
    return exec.dispose(run_id)
end

--- Dispose a standalone shell tab: delete its terminal buffer (killing the shell
--- if it is still running) and remove the tab from the panel. The buffer's
--- BufDelete/BufWipeout autocmd drives the panel cleanup via _close_shell.
---@param run_id string
---@return boolean ok, string? err
function M.dispose_shell(run_id)
    local entry = _shell_entries[run_id]
    if not entry then return false, "no such shell: " .. tostring(run_id) end
    local be = entry.bufnrs[1]
    if be and vim.api.nvim_buf_is_valid(be.bufnr) then
        pcall(vim.api.nvim_buf_delete, be.bufnr, { force = true })
    else
        _close_shell(run_id)
    end
    return true
end

return M
