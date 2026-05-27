--- Minimal coroutine scheduler.
---
--- Coroutines never resume themselves. Instead they yield a request table
--- ({ kind = "signal"|"wait_all", ... }) and step() handles the scheduling.
--- This guarantees on_done is always called and eliminates external bookkeeping.
---@class easytasks.async
local M = {}

--- Drive one step of a coroutine, then dispatch its yielded request.
--- All resumes funnel through here so on_done is always invoked.
---@param co      thread
---@param on_done fun(ok: boolean, result: any)
---@param ...     any  passed to coroutine.resume
local function step(co, on_done, ...)
    local ok, val = coroutine.resume(co, ...)
    if not ok then
        on_done(false, val)
    elseif coroutine.status(co) == "dead" then
        on_done(true, val)
    elseif val.kind == "signal" then
        local function listener()
            val.signal:unsubscribe(listener)
            vim.schedule(function() step(co, on_done) end)
        end
        val.signal:subscribe(listener)
    elseif val.kind == "wait_all" then
        local fns     = val.fns
        local pending = #fns
        local results = {}
        for i, fn in ipairs(fns) do
            M.go(fn, function(r_ok, r_val)
                results[i] = { ok = r_ok, result = r_val }
                pending    = pending - 1
                if pending == 0 then
                    vim.schedule(function() step(co, on_done, results) end)
                end
            end)
        end
    end
end

--- Drive `fn` as a coroutine. Calls `on_done(ok, result)` when it finishes or errors.
---@param fn      fun(...): any
---@param on_done fun(ok: boolean, result: any)
---@param ...     any  arguments forwarded to fn
function M.go(fn, on_done, ...)
    local args = { ... }
    local co = coroutine.create(function() return fn(unpack(args)) end)
    step(co, on_done)
end

--- Run a list of coroutine functions in parallel; yield until all finish.
--- Must be called from within a coroutine (via M.go).
---@param fns (fun(): any)[]
---@return {ok: boolean, result: any}[]
function M.wait_all(fns)
    if #fns == 0 then return {} end
    assert(coroutine.running(), "async.wait_all must be called inside a coroutine")
    return coroutine.yield({ kind = "wait_all", fns = fns })
end

--- Yield until `signal` emits once, then return.
--- Must be called from within a coroutine (via M.go).
---@param signal easytasks.util.Signal<fun()>
function M.wait_signal(signal)
    assert(coroutine.running(), "async.wait_signal must be called inside a coroutine")
    coroutine.yield({ kind = "signal", signal = signal })
end

return M
