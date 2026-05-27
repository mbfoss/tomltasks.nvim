---@class easytasks.async
local M = {}

---@type table<thread, fun(...): any>
local _steps = {}

--- Drive `fn` as a coroutine. Calls `on_done(ok, result)` when it finishes or errors.
---@param fn     fun(...): any
---@param on_done fun(ok: boolean, result: any)
---@param ...    any  arguments forwarded to fn
function M.go(fn, on_done, ...)
    local args = { ... }
    local co = coroutine.create(function()
        return fn(unpack(args))
    end)
    local function step(...)
        local ok, val = coroutine.resume(co, ...)
        if not ok then
            _steps[co] = nil
            on_done(false, val)
        elseif coroutine.status(co) == "dead" then
            _steps[co] = nil
            on_done(true, val)
        end
        -- still suspended: a callback will call M.resume(co, ...) to continue
    end
    _steps[co] = step
    step()
end

--- Resume a coroutine managed by M.go, routing through its step function so
--- on_done is fired when the coroutine finishes. All async resume sites (spawn,
--- wait_signal, wait_all) must use this instead of coroutine.resume directly.
---@param co thread
---@param ... any
function M.resume(co, ...)
    local step = _steps[co]
    if step then
        step(...)
    end
end

--- Yield the calling coroutine until `sig` emits once.
--- Must be called from within a coroutine (started with async.go).
---@param sig easytasks.util.Signal<fun()>
function M.wait_signal(sig)
    local co = assert(coroutine.running(), "wait_signal must be called inside a coroutine")
    local handler
    handler = function()
        sig:unsubscribe(handler)
        M.resume(co)
    end
    sig:subscribe(handler)
    coroutine.yield()
end

--- Run all fns as parallel coroutines and yield until all complete.
--- Must be called from within a coroutine (started with async.go).
--- Returns an array of { ok: boolean, result: any } in the same order as fns.
---@param fns (fun(): any)[]
---@return { ok: boolean, result: any }[]
function M.wait_all(fns)
    if #fns == 0 then return {} end
    local co = assert(coroutine.running(), "wait_all must be called inside a coroutine")
    local results = {}
    local pending = #fns
    for i, fn in ipairs(fns) do
        M.go(fn, function(ok, result)
            results[i] = { ok = ok, result = result }
            pending = pending - 1
            if pending == 0 then
                M.resume(co, results)
            end
        end)
    end
    return coroutine.yield()
end

return M
