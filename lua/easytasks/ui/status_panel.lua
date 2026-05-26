local TreeBuffer = require('easytasks.ui.TreeBuffer')
local exec       = require('easytasks.runner.exec')

---@class easytasks.ui.status_panel
local M = {}

local _tb          = nil  ---@type table?   easytasks.ui.TreeBuffer instance
local _win         = nil  ---@type integer?
local _output_win  = nil  ---@type integer?

--- run_ids of root nodes already in the tree.
---@type table<string, true>
local _known_runs = {}

--- buf-node IDs already in the tree ("buf#<bufnr>").
---@type table<string, true>
local _known_bufs = {}

local _PANEL_HEIGHT = 8
local _LIST_WIDTH   = 36

local _augroup = vim.api.nvim_create_augroup("EasytasksStatusPanel", { clear = true })

local _state_badge = {
    running = { "● ", "DiagnosticWarn" },
    ok      = { "● ", "DiagnosticOk" },
    failed  = { "● ", "DiagnosticError" },
    idle    = { "● ", "Comment" },
}

---@return vim.api.keyset.win_config
local function _output_config()
    local w = assert(_win, "_output_config called before _win is set")
    local win_w = vim.api.nvim_win_get_width(w)
    local win_h = vim.api.nvim_win_get_height(w)
    local float_w = math.max(4, win_w - _LIST_WIDTH - 1)
    ---@type vim.api.keyset.win_config
    return {
        relative  = "win",
        win       = w,
        anchor    = "NW",
        row       = 0,
        col       = _LIST_WIDTH,
        width     = float_w,
        height    = win_h,
        style     = "minimal",
        border    = { "", "", "", "", "", "", "", "│" },
        focusable = true,
        zindex    = 50,
    }
end

---@param bufnr integer
local function _show_output(bufnr)
    if not _win or not vim.api.nvim_win_is_valid(_win) then return end
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    if _output_win and vim.api.nvim_win_is_valid(_output_win) then
        vim.api.nvim_win_set_buf(_output_win, bufnr)
    else
        _output_win = vim.api.nvim_open_win(bufnr, false, _output_config())
        vim.wo[_output_win].number         = false
        vim.wo[_output_win].relativenumber = false
        vim.wo[_output_win].wrap           = false
    end
end

local function _close_output()
    if _output_win and vim.api.nvim_win_is_valid(_output_win) then
        pcall(vim.api.nvim_win_close, _output_win, true)
    end
    _output_win = nil
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
        return { { badge[1], badge[2] }, { data.task_name, nil } }, {}
    else
        ---@cast data easytasks.BufEntry
        return { { "  ", nil }, { data.label, "Comment" } }, {}
    end
end

--- Add any buffer children not yet in the tree for this run entry.
---@param run_id string
---@param entry  easytasks.RunEntry
local function _sync_buf_nodes(run_id, entry)
    if not _tb then return end
    for _, buf_entry in ipairs(entry.bufnrs) do
        local bid = _buf_node_id(buf_entry.bufnr)
        if not _known_bufs[bid] then
            _known_bufs[bid] = true
            _tb:add_item(bid, buf_entry, run_id)
        end
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
        _tb:add_item(run_id, entry, nil)
    end
    _sync_buf_nodes(run_id, entry)
    -- Auto-show the newest buffer when no output pane is open
    if #entry.bufnrs > 0 and (not _output_win or not vim.api.nvim_win_is_valid(_output_win)) then
        local bufnr = entry.bufnrs[#entry.bufnrs].bufnr
        if vim.api.nvim_buf_is_valid(bufnr) then
            _show_output(bufnr)
        end
    end
end

local function on_close()
    exec.unsubscribe(on_state_change)
    vim.api.nvim_clear_autocmds({ group = _augroup })
    _close_output()
    _tb          = nil
    _win         = nil
    _known_runs  = {}
    _known_bufs  = {}
end

--- Return the bufnr to show for the item under the cursor, or nil.
---@return integer?
local function _cursor_bufnr()
    if not _tb then return nil end
    local id, data = _tb:cursor_item()
    if not id or not data then return nil end
    if _is_buf_node(id) then
        ---@cast data easytasks.BufEntry
        return vim.api.nvim_buf_is_valid(data.bufnr) and data.bufnr or nil
    end
    -- run entry node: show the most recently registered buffer
    ---@cast data easytasks.RunEntry
    if #data.bufnrs > 0 then
        local bufnr = data.bufnrs[#data.bufnrs].bufnr
        return vim.api.nvim_buf_is_valid(bufnr) and bufnr or nil
    end
    return nil
end

local function _sync_output_to_cursor()
    local bufnr = _cursor_bufnr()
    if bufnr then _show_output(bufnr) end
end

function M.open()
    if _win and vim.api.nvim_win_is_valid(_win) then
        vim.api.nvim_set_current_win(_win)
        return
    end

    _tb = TreeBuffer.new({
        formatter           = _formatter,
        current_item_prefix = "",
        on_selection        = function(id, data)
            local bufnr
            if _is_buf_node(id) then
                ---@cast data easytasks.BufEntry
                bufnr = data.bufnr
            else
                ---@cast data easytasks.RunEntry
                if #data.bufnrs > 0 then
                    bufnr = data.bufnrs[#data.bufnrs].bufnr
                end
            end
            if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
                _show_output(bufnr)
                if _output_win and vim.api.nvim_win_is_valid(_output_win) then
                    vim.api.nvim_set_current_win(_output_win)
                end
            end
        end,
    })

    local buf = _tb:buf()
    vim.bo[buf].filetype = "easytasks-status"

    vim.cmd("botright split")
    _win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(_win, buf)
    vim.wo[_win].number         = false
    vim.wo[_win].relativenumber = false
    vim.wo[_win].wrap           = false
    vim.wo[_win].winfixheight   = true
    vim.api.nvim_win_set_height(_win, _PANEL_HEIGHT)

    vim.api.nvim_create_autocmd("WinClosed", {
        group    = _augroup,
        pattern  = tostring(_win),
        once     = true,
        callback = on_close,
    })

    vim.api.nvim_create_autocmd("WinResized", {
        group    = _augroup,
        callback = function()
            if _output_win and vim.api.nvim_win_is_valid(_output_win)
               and _win and vim.api.nvim_win_is_valid(_win) then
                pcall(vim.api.nvim_win_set_config, _output_win, _output_config())
            end
        end,
    })

    vim.api.nvim_create_autocmd("CursorMoved", {
        group    = _augroup,
        buffer   = buf,
        callback = _sync_output_to_cursor,
    })

    -- Populate with runs already tracked
    for run_id, entry in pairs(exec.get_all()) do
        _known_runs[run_id] = true
        _tb:add_item(run_id, entry, nil)
        _sync_buf_nodes(run_id, entry)
    end

    -- Show the most recent buffer immediately
    for _, entry in pairs(exec.get_all()) do
        if #entry.bufnrs > 0 then
            local bufnr = entry.bufnrs[#entry.bufnrs].bufnr
            if vim.api.nvim_buf_is_valid(bufnr) then
                _show_output(bufnr)
                break
            end
        end
    end

    exec.subscribe(on_state_change)
end

function M.toggle()
    if _win and vim.api.nvim_win_is_valid(_win) then
        vim.api.nvim_win_close(_win, false)
    else
        M.open()
    end
end

return M
