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

--- Yield until `signal` emits once, then return.
--- Must be called from within a coroutine.
---@param signal easytasks.util.Signal<fun()>
function M.wait_signal(signal)
    local co = assert(coroutine.running(), "async.wait_signal must be called inside a coroutine")
    local function listener()
        signal:unsubscribe(listener)
        vim.schedule(function() coroutine.resume(co) end)
    end
    signal:subscribe(listener)
    coroutine.yield()
end

return M
