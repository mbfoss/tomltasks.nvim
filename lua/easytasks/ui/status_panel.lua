local ListBuffer = require('easytasks.ui.ListBuffer')
local exec       = require('easytasks.runner.exec')

---@class easytasks.ui.status_panel
local M = {}

---@type easytasks.ui.ListBuffer?
local _lb = nil

---@type integer?
local _win = nil

---@type integer?
local _output_win = nil

local _PANEL_HEIGHT = 8
local _LIST_WIDTH   = 36  -- columns reserved for the task list on the left

local _augroup = vim.api.nvim_create_augroup("EasytasksStatusPanel", { clear = true })

local _state_badge = {
    running = { "● ", "DiagnosticWarn" },
    ok      = { "● ", "DiagnosticOk" },
    failed  = { "● ", "DiagnosticError" },
    idle    = { "● ", "Comment" },
}

--- Float config: right portion of _win, same height, left-border separator.
--- Must be called after _win is set.
---@return vim.api.keyset.win_config
local function _output_config()
    local w = assert(_win, "_output_config called before _win is set")
    local win_w = vim.api.nvim_win_get_width(w)
    local win_h = vim.api.nvim_win_get_height(w)
    local float_w = math.max(4, win_w - _LIST_WIDTH - 1)  -- -1 for the border column
    return {
        relative  = "win",
        win       = w,
        anchor    = "NW",
        row       = 0,
        col       = _LIST_WIDTH,
        width     = float_w,
        height    = win_h,
        style     = "minimal",
        -- single left border acts as a split-line separator, no other borders
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

local function _sync_output_to_cursor()
    if not _lb then return end
    local _, entry = _lb:cursor_item()
    if entry and entry.bufnr then
        _show_output(entry.bufnr)
    end
end

---@param name string
---@param entry easytasks.RunEntry
---@return string[][], string[][]
local function formatter(name, entry)
    local badge = _state_badge[entry.state] or _state_badge.idle
    return {
        { badge[1], badge[2] },
        { name,     nil },
    }, {}
end

local function on_state_change(name, entry)
    if not _lb then return end
    _lb:add_item(name, entry)
    if entry.bufnr and (not _output_win or not vim.api.nvim_win_is_valid(_output_win)) then
        _show_output(entry.bufnr)
    end
end

local function on_close()
    exec.unsubscribe(on_state_change)
    vim.api.nvim_clear_autocmds({ group = _augroup })
    _close_output()
    _lb  = nil
    _win = nil
end

function M.open()
    if _win and vim.api.nvim_win_is_valid(_win) then
        vim.api.nvim_set_current_win(_win)
        return
    end

    _lb = ListBuffer.new({
        formatter           = formatter,
        current_item_prefix = "",
        -- <CR> focuses the output float so the user can scroll terminal output
        on_selection        = function(_, entry)
            if entry.bufnr and vim.api.nvim_buf_is_valid(entry.bufnr) then
                _show_output(entry.bufnr)
                if _output_win and vim.api.nvim_win_is_valid(_output_win) then
                    vim.api.nvim_set_current_win(_output_win)
                end
            end
        end,
    })

    local buf = _lb:buf()
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

    -- Keep float size in sync when the panel is resized
    vim.api.nvim_create_autocmd("WinResized", {
        group    = _augroup,
        callback = function()
            if _output_win and vim.api.nvim_win_is_valid(_output_win)
               and _win and vim.api.nvim_win_is_valid(_win) then
                pcall(vim.api.nvim_win_set_config, _output_win, _output_config())
            end
        end,
    })

    -- Update output when cursor moves through the list
    vim.api.nvim_create_autocmd("CursorMoved", {
        group    = _augroup,
        buffer   = buf,
        callback = _sync_output_to_cursor,
    })

    for name, entry in pairs(exec.get_all()) do
        _lb:add_item(name, entry)
    end

    -- Show the first available buffer immediately
    for _, entry in pairs(exec.get_all()) do
        if entry.bufnr and vim.api.nvim_buf_is_valid(entry.bufnr) then
            _show_output(entry.bufnr)
            break
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
