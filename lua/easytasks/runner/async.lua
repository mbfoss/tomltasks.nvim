---@class easytasks.async
local M = {}

--- Drive `fn` as a coroutine. Calls `on_done(ok, result)` when it finishes or errors.
---@param fn fun(...): any
---@param on_done fun(ok: boolean, result: any)
---@param ... any  arguments forwarded to fn
function M.go(fn, on_done, ...)
    local args = { ... }
    local co = coroutine.create(function()
        return fn(unpack(args))
    end)
    local function step(...)
        local ok, val = coroutine.resume(co, ...)
        if not ok then
            on_done(false, val)
        elseif coroutine.status(co) == "dead" then
            on_done(true, val)
        end
        -- still suspended: libuv / jobstart callback will call step again
    end
    step()
end

--- Spawn a command in a terminal buffer and yield until it exits.
--- Must be called from within a coroutine (started with `go`).
--- `bufnr` must already be visible in a window (call `term.show` first).
--- termopen handles all output rendering including ANSI colours.
---@param cmd  string|string[]
---@param opts {cwd?: string, env?: table<string,string>}
---@param bufnr integer  terminal buffer (must be visible in a window)
---@return integer exit_code
function M.spawn(cmd, opts, bufnr)
    local co = assert(coroutine.running(), "async.spawn must be called inside a coroutine")

    -- termopen must be called while bufnr is the current buffer in a window
    local target_win
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == bufnr then
            target_win = win
            break
        end
    end
    assert(target_win, "async.spawn: terminal buffer must be visible in a window")

    local saved_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(target_win)

    local job_id = vim.fn.jobstart(cmd, {
        term    = true,
        cwd     = opts.cwd,
        env     = opts.env,  -- dict {KEY = value} or nil
        on_exit = function(_, code)
            vim.schedule(function()
                coroutine.resume(co, code)
            end)
        end,
    })

    vim.api.nvim_set_current_win(saved_win)

    if job_id <= 0 then
        return -1
    end

    return coroutine.yield()
end

--- Run a list of coroutine functions in parallel; yield until all finish.
--- Must be called from within a coroutine.
---@param fns (fun(): any)[]
---@return {ok: boolean, result: any}[]
function M.wait_all(fns)
    if #fns == 0 then return {} end
    local co      = assert(coroutine.running(), "async.wait_all must be called inside a coroutine")
    local pending = #fns
    local results = {}

    for i, fn in ipairs(fns) do
        M.go(fn, function(ok, val)
            results[i] = { ok = ok, result = val }
            pending = pending - 1
            if pending == 0 then
                vim.schedule(function()
                    coroutine.resume(co, results)
                end)
            end
        end)
    end

    return coroutine.yield()
end

return M
