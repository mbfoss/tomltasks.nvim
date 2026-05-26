local M = {}

local ui_util = require("easytasks.ui.ui_util")

local _spawn_win

--- Spawn a command in a terminal buffer and yield until it exits.
--- Must be called from within a coroutine (started with async.go).
--- `bufnr` must already be visible in a window.
--- termopen handles all output rendering including ANSI colours.
---@param cmd  string|string[]
---@param opts {cwd?: string, env?: table<string,string>}
---@param bufnr integer  terminal buffer (must be visible in a window)
---@return integer exit_code
function M.spawn(cmd, opts, bufnr)
    local co = assert(coroutine.running(), "spawn must be called inside a coroutine")

    -- A terminal buffer must be in a window for jobstart {term=true}.
    if not _spawn_win then
        _spawn_win = ui_util.create_window(bufnr, false, {
            relative  = "editor",
            row       = 0,
            col       = 0,
            width     = vim.o.columns,
            height    = vim.o.lines,
            style     = "minimal",
            hide      = true,
            focusable = false,
            zindex    = 1,
        }, function()
            _spawn_win = nil
        end)
    else
        vim.api.nvim_win_set_buf(_spawn_win, bufnr)
    end

    local saved_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(_spawn_win)

    local job_id = vim.fn.jobstart(cmd, {
        term    = true,
        cwd     = opts.cwd,
        env     = opts.env,
        on_exit = function(_, code)
            vim.schedule(function()
                coroutine.resume(co, code)
            end)
        end,
    })

    vim.api.nvim_set_current_win(saved_win)

    if job_id <= 0 then return -1 end

    return coroutine.yield()
end

return M
