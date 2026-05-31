local M = {}

local ui = require("easytasks.ui")

local _spawn_win

---@class easytasks.SpawnHandle
---@field stop    fun()                        stop the spawned command
---@field on_exit fun(cb: fun(code: integer))  register a callback invoked when the process exits

--- Spawn a command in a terminal buffer.
--- Must be called from within a coroutine (started with async.go).
--- Returns immediately with a handle; call `handle.wait()` to yield until exit.
--- `bufnr` must already be visible in a window.
--- termopen handles all output rendering including ANSI colours.
---@param cmd  string|string[]
---@param opts {cwd?: string, env?: table<string,string>, on_stdout?: fun(id: integer, data: string[], name: string), on_stderr?: fun(id: integer, data: string[], name: string)}
---@param bufnr integer  terminal buffer (must be visible in a window)
---@return easytasks.SpawnHandle
function M.spawn(cmd, opts, bufnr)
    -- A terminal buffer must be in a window for jobstart {term=true}.
    if not _spawn_win then
        _spawn_win = ui.create_window(bufnr, false, {
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

    local exit_cb
    local job_id
    job_id = vim.fn.jobstart(cmd, {
        term      = true,
        cwd       = opts.cwd,
        env       = opts.env,
        on_stdout = opts.on_stdout,
        on_stderr = opts.on_stderr,
        on_exit   = function(_, code)
            job_id = -1
            vim.schedule(function()
                if exit_cb then exit_cb(code) end
            end)
        end,
    })

    vim.api.nvim_set_current_win(saved_win)

    if job_id <= 0 then
        return { stop = function() end, on_exit = function(cb) cb(-1) end }
    end

    return {
        stop = function()
            if job_id > 0 then
                vim.fn.jobstop(job_id)
            end
        end,
        on_exit = function(cb) exit_cb = cb end,
    }
end

return M
