---@class easytasks.async
local M = {}

--- Drive `fn` as a coroutine. Calls `on_done(ok, result)` when it finishes or errors.
---@param fn     fun(...): any
---@param on_done fun(ok: boolean, result: any)
---@param ...    any  arguments forwarded to fn
function M.go(fn, on_done, ...)
    local args = { ... }
    local co = coroutine.create(function()
        return fn(unpack(args))
    end)
	local last_status = false
    local function step(...)
        local ok, val = coroutine.resume(co, ...)
			vim.notify('coro ret:' .. tostring(ok) .. tostring(val))
        if not ok then
			vim.notify('coro ended')
            on_done(false, val)
        elseif coroutine.status(co) == "dead" then
			vim.notify('coro dead')
            on_done(true, val)
        end
        -- still suspended: libuv / jobstart callback will call step again
    end
    step()
end

--- Yield the calling coroutine until `sig` emits once.
--- Must be called from within a coroutine (started with async.go).
---@param sig easytasks.util.Signal<fun()>
function M.wait_signal(sig)
    local co = assert(coroutine.running(), "wait_signal must be called inside a coroutine")
    local handler
    handler = function()
        sig:unsubscribe(handler)
        coroutine.resume(co)
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
                coroutine.resume(co, results)
            end
        end)
    end
    return coroutine.yield()
end

return M
