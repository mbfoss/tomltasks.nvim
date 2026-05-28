local TreeBuffer    = require('easytasks.ui.TreeBuffer')
local utils         = require('easytasks.ui.utils')
local exec          = require('easytasks.runner.exec')

---@class easytasks.ui.status_panel
local M             = {}

local _tb           = nil ---@type easytasks.ui.TreeBuffer?
local _win          = nil ---@type integer?
local _output_win   = nil ---@type integer?

--- run_ids of root nodes already in the tree.
---@type table<string, true>
local _known_runs   = {}

--- buf-node IDs already in the tree ("buf#<bufnr>") → owning run_id.
---@type table<string, string>
local _known_bufs   = {}

--- Single scratch buffer used to display status info for the selected root node.
local _info_buf     = nil ---@type integer?

local _PANEL_HEIGHT = 8
local _LIST_WIDTH   = 36

local _augroup      = vim.api.nvim_create_augroup("EasytasksStatusPanel", { clear = true })
local _empty_ns     = vim.api.nvim_create_namespace("EasytasksStatusPanelEmpty")
local _info_hl_ns   = vim.api.nvim_create_namespace("EasytasksInfoBuf")

local _state_badge  = {
    running = { "● ", "DiagnosticWarn" },
    waiting = { "◌ ", "DiagnosticWarn" },
    ok      = { "● ", "DiagnosticOk" },
    failed  = { "● ", "DiagnosticError" },
    stopped = { "● ", "DiagnosticHint" },
    idle    = { "● ", "Comment" },
}

---@return integer  bottom row (0-indexed) for SW-anchored floats
local function _panel_row()
    return vim.o.lines - vim.o.cmdheight - 1
end

---@return integer  gutter width (signs + numbers + folds) of the leftmost window
local function _gutter_width()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local info = vim.fn.getwininfo(win)[1]
        if info and info.wincol == 1 then
            return info.textoff
        end
    end
    return 0
end

---@return vim.api.keyset.win_config
local function _list_config()
    ---@type vim.api.keyset.win_config
    return {
        relative  = "editor",
        anchor    = "SW",
        row       = _panel_row(),
        col       = _gutter_width(),
        width     = _LIST_WIDTH,
        height    = _PANEL_HEIGHT,
        style     = "minimal",
        border    = "rounded",
        focusable = true,
        zindex    = 49,
    }
end

---@return vim.api.keyset.win_config
local function _full_config()
    local gw = _gutter_width()
    ---@type vim.api.keyset.win_config
    return {
        relative  = "editor",
        anchor    = "SW",
        row       = _panel_row(),
        col       = gw,
        width     = math.max(4, vim.o.columns - gw * 2),
        height    = _PANEL_HEIGHT,
        style     = "minimal",
        border    = "rounded",
        focusable = true,
        zindex    = 49,
    }
end

---@return vim.api.keyset.win_config
local function _output_config()
    local gw    = _gutter_width()
    local out_w = math.max(4, vim.o.columns - gw - gw - _LIST_WIDTH - 2)
    ---@type vim.api.keyset.win_config
    return {
        relative  = "editor",
        anchor    = "SW",
        row       = _panel_row(),
        col       = gw + _LIST_WIDTH + 2,
        width     = out_w,
        height    = _PANEL_HEIGHT,
        style     = "minimal",
        border    = "rounded",
        focusable = true,
        zindex    = 49,
    }
end

---@param bufnr integer
local function _show_output(bufnr)
    if not _win or not vim.api.nvim_win_is_valid(_win) then return end
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    if _output_win and vim.api.nvim_win_is_valid(_output_win) then
        vim.api.nvim_win_set_buf(_output_win, bufnr)
    else
        _output_win                        = utils.create_window(bufnr, false, _output_config(), function()
            _output_win = nil
            if _win then
                vim.api.nvim_win_close(_win, false)
            end
        end)
        vim.wo[_output_win].number         = false
        vim.wo[_output_win].relativenumber = false
        vim.wo[_output_win].wrap           = false
    end

    local back = function()
        if _win and vim.api.nvim_win_is_valid(_win) then
            vim.api.nvim_set_current_win(_win)
        end
    end
    vim.keymap.set("n", "<C-w>h", back, { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<C-w><C-h>", back, { buffer = bufnr, nowait = true })
end

local function _close_output()
    if _output_win and vim.api.nvim_win_is_valid(_output_win) then
        pcall(vim.api.nvim_win_close, _output_win, true)
    end
    _output_win = nil
end

local function _update_layout()
    if not _tb or not _win or not vim.api.nvim_win_is_valid(_win) then return end
    local is_empty = next(_known_runs) == nil
    local buf = _tb:buf()
    vim.api.nvim_buf_clear_namespace(buf, _empty_ns, 0, -1)
    if is_empty then
        _close_output()
        pcall(vim.api.nvim_win_set_config, _win, _full_config())
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
        vim.bo[buf].modifiable = false
        vim.api.nvim_buf_set_extmark(buf, _empty_ns, 0, 0, {
            virt_text     = { { "  No running tasks", "Comment" } },
            virt_text_pos = "overlay",
        })
    else
        pcall(vim.api.nvim_win_set_config, _win, _list_config())
    end
end

---@param bufnr integer
---@return string
local function _buf_node_id(bufnr)
    return "buf#" .. tostring(bufnr)
end

---@param id any
---@return boolean
local function _is_buf_node(id)
    return type(id) == "string" and id:sub(1, 4) == "buf#"
end

---@param data  any
---@param depth integer
---@return string[][], string[][]
local function _formatter(_, data, depth)
    if depth == 0 then
        ---@cast data easytasks.RunEntry
        local badge = _state_badge[data.state] or _state_badge.idle
        local time  = os.date("%H:%M:%S", data.progress.start_time) --[[@as string]]
        return { { badge[1], badge[2] }, { time .. " ", "Comment" }, { data.task_name, nil } }, {}
    else
        ---@cast data easytasks.BufEntry
        return { { "  ", nil }, { data.label, "Comment" } }, {}
    end
end

--- Sync buffer child nodes for a run entry.
--- Removes nodes for deleted buffers and adds nodes for new ones.
---@param run_id string
---@param entry  easytasks.RunEntry
local function _sync_buf_nodes(run_id, entry)
    if not _tb then return end

    local current = {} ---@type table<string, easytasks.BufEntry>
    for _, buf_entry in ipairs(entry.bufnrs) do
        current[_buf_node_id(buf_entry.bufnr)] = buf_entry
    end

    for bid, owner in pairs(_known_bufs) do
        if owner == run_id and not current[bid] then
            _known_bufs[bid] = nil
            _tb:remove_item(bid)
        end
    end

    for bid, buf_entry in pairs(current) do
        if not _known_bufs[bid] then
            _known_bufs[bid] = run_id
            _tb:add_item(bid, buf_entry, run_id)
        end
    end
end

---@class easytasks.InfoLine
---@field text    string
---@field hl      string?   highlight group
---@field hl_col  integer?  start column for hl (default 0 = whole line)

---@param entry easytasks.RunEntry
---@return easytasks.InfoLine[]
local function _info_lines(entry)
    local p   = entry.progress
    local fmt = function(t) return os.date("%H:%M:%S", t) --[[@as string]] end

    ---@param text    string
    ---@param hl      string?
    ---@param hl_col  integer?
    ---@return easytasks.InfoLine
    local function line(text, hl, hl_col) return { text = text, hl = hl, hl_col = hl_col } end

    local label      = "status   "
    local state_hl   = (_state_badge[entry.state] or _state_badge.idle)[2]
    local rows = {
        line(entry.task_name, "Title"),
        line(""),
        line(label .. entry.state, state_hl, #label),
        line("started  " .. fmt(p.start_time)),
    }

    if p.stop_time then
        table.insert(rows, line("stopped  " .. fmt(p.stop_time)))
    end

    if entry.waiting_for and #entry.waiting_for > 0 then
        table.insert(rows, line(""))
        table.insert(rows, line("waiting for", "Label"))
        for _, dep in ipairs(entry.waiting_for) do
            table.insert(rows, line("  - " .. dep))
        end
    end

    if #p.events > 0 then
        table.insert(rows, line(""))
        table.insert(rows, line("events", "Label"))
        for _, ev in ipairs(p.events) do
            table.insert(rows, line("  [" .. fmt(ev.time) .. "] " .. ev.message))
        end
    end

    return rows
end

--- Ensure a scratch info buffer exists for `run_id` and refresh its content.
--- Populate the single info buffer with `entry`'s status lines and return it.
---@param entry easytasks.RunEntry
---@return integer
local function _update_info_buf(entry)
    if not _info_buf or not vim.api.nvim_buf_is_valid(_info_buf) then
        _info_buf = utils.create_sratch_buffer(false, { bufhidden = "hide" })
    end

    local rows  = _info_lines(entry)
    local texts = vim.tbl_map(function(r) return r.text end, rows)

    vim.bo[_info_buf].modifiable = true
    vim.api.nvim_buf_set_lines(_info_buf, 0, -1, false, texts)
    vim.bo[_info_buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(_info_buf, _info_hl_ns, 0, -1)
    for i, r in ipairs(rows) do
        if r.hl then
            local s_col = r.hl_col or 0
            vim.api.nvim_buf_set_extmark(_info_buf, _info_hl_ns, i - 1, s_col, { hl_group = r.hl, end_col = #r.text })
        end
    end
    return _info_buf
end

--- Return the bufnr to show for the item under the cursor, or nil.
---@return integer?
local function _cursor_bufnr()
    if not _tb then return nil end
    local id, data = _tb:cursor_item()
    if not id or not data then return nil end
    if _is_buf_node(id) then
        ---@cast data easytasks.BufEntry
        return data.bufnr and vim.api.nvim_buf_is_valid(data.bufnr) and data.bufnr or nil
    else
        ---@cast data easytasks.RunEntry
        return _update_info_buf(data)
    end
end

local function _sync_output_to_cursor()
    local bufnr = _cursor_bufnr()
    if bufnr then
        _show_output(bufnr)
    else
        _close_output()
    end
end

---@param run_id string
---@param entry  easytasks.RunEntry
local function on_state_change(run_id, entry)
    if not _tb then return end
    if _known_runs[run_id] then
        _tb:update_item(run_id, entry)
    else
        _known_runs[run_id] = true
        _tb:add_item(run_id, entry, nil, true)
    end
    _sync_buf_nodes(run_id, entry)
    _update_layout()
    vim.schedule(_sync_output_to_cursor)
end

local function on_close()
    exec.unsubscribe(on_state_change)
    vim.api.nvim_clear_autocmds({ group = _augroup })
    _close_output()
    _tb         = nil
    _win        = nil
    _known_runs = {}
    _known_bufs = {}
    if _info_buf and vim.api.nvim_buf_is_valid(_info_buf) then
        pcall(vim.api.nvim_buf_delete, _info_buf, { force = true })
    end
    _info_buf = nil
end

function M.open()
    if _win and vim.api.nvim_win_is_valid(_win) then
        vim.api.nvim_set_current_win(_win)
        return
    end

    _tb                         = TreeBuffer.new(
        {
            formatter           = _formatter,
            current_item_prefix = "",
            on_selection        = function(id, data)
                local bufnr
                if _is_buf_node(id) then
                    ---@cast data easytasks.BufEntry
                    bufnr = data.bufnr
                else
                    ---@cast data easytasks.RunEntry
                    bufnr = _update_info_buf(data)
                end
                if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
                    _show_output(bufnr)
                    if _output_win and vim.api.nvim_win_is_valid(_output_win) then
                        vim.api.nvim_set_current_win(_output_win)
                    end
                end
            end,
        })

    local buf                   = _tb:buf()
    vim.bo[buf].filetype        = "easytasks-status"

    _win                        = utils.create_window(buf, true, _list_config(), function()
        _win = nil
        on_close()
    end)
    vim.wo[_win].number         = false
    vim.wo[_win].relativenumber = false
    vim.wo[_win].wrap           = false
    vim.wo[_win].cursorline     = true

    vim.api.nvim_create_autocmd("VimResized", {
        group    = _augroup,
        callback = function()
            _update_layout()
            if _output_win and vim.api.nvim_win_is_valid(_output_win) then
                pcall(vim.api.nvim_win_set_config, _output_win, _output_config())
            end
        end,
    })

    vim.api.nvim_create_autocmd("CursorMoved", {
        group    = _augroup,
        buffer   = buf,
        callback = _sync_output_to_cursor,
    })

    vim.api.nvim_create_autocmd("CursorMoved", {
        group    = _augroup,
        callback = function()
            if not _win or not vim.api.nvim_win_is_valid(_win) then return end
            local cur_win = vim.api.nvim_get_current_win()
            if cur_win == _win or cur_win == _output_win then return end
            local panel_top_row     = _panel_row() - _PANEL_HEIGHT - 1
            local cursor_screen_row = vim.fn.screenrow() - 1
            if cursor_screen_row >= panel_top_row then
                vim.schedule(function()
                    if _win and vim.api.nvim_win_is_valid(_win) then
                        vim.api.nvim_win_close(_win, false)
                    end
                end)
            end
        end,
    })

    -- Populate with runs already tracked, newest first
    local existing = vim.tbl_keys(exec.get_all())
    table.sort(existing, function(a, b)
        local na = tonumber(a:match("#(%d+)$")) or 0
        local nb = tonumber(b:match("#(%d+)$")) or 0
        return na > nb
    end)
    local all = exec.get_all()
    for _, run_id in ipairs(existing) do
        _known_runs[run_id] = true
        _tb:add_item(run_id, all[run_id], nil)
        _sync_buf_nodes(run_id, all[run_id])
    end

    _update_layout()
    _sync_output_to_cursor()

    exec.subscribe(on_state_change)
end

function M.toggle()
    if _win then
        vim.api.nvim_win_close(_win, false)
    else
        M.open()
    end
end

return M
