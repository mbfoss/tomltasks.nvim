local M = {}

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

    local target_win
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == bufnr then
            target_win = win
            break
        end
    end
    assert(target_win, "spawn: terminal buffer must be visible in a window")

    local saved_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(target_win)

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
