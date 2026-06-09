---@class easytasks.async
local M = {}

local log = require("easytasks.util.log")

local _co_counter = 0
local function _co_id()
    _co_counter = _co_counter + 1
    return "co#" .. _co_counter
end

--- Drive `fn` as a coroutine. Calls `on_done(ok, result)` when it finishes or errors.
--- When the coroutine yields it must yield a function `setup(waker)`. The step
--- function calls `setup(step)` immediately, handing the coroutine's own resume
--- path to whoever will wake it later (a timer, an on_exit callback, etc.).
---@param fn     fun(...): any
---@param on_done fun(ok: boolean, result: any)
---@param ...    any  arguments forwarded to fn
function M.go(fn, on_done, ...)
    local args = { ... }
    local id = _co_id()
    local co = coroutine.create(function()
        return fn(unpack(args))
    end)
    log.debug("async.go: %s created", id)
    local function step(...)
        log.debug("async.go: %s step resume", id)
        local ok, val = coroutine.resume(co, ...)
        local status = coroutine.status(co)
        log.debug("async.go: %s resume ok=%s status=%s val_type=%s",
            id, tostring(ok), status, type(val))
        if not ok then
            log.error("async.go: %s error: %s", id, tostring(val))
            on_done(false, val)
        elseif status == "dead" then
            log.debug("async.go: %s dead result=%s", id, tostring(val))
            on_done(true, val)
        elseif type(val) == "function" then
            val(step)
        else
            log.error("async.go: %s unexpected yield type=%s", id, type(val))
            on_done(false, "unexpected yield value: " .. type(val))
        end
    end
    step()
end

--- Yield the calling coroutine until `sig` emits once.
--- Must be called from within a coroutine (started with async.go).
---@param sig easytasks.util.Signal<fun()>
function M.wait_signal(sig)
    coroutine.yield(function(waker)
        local handler
        handler = function()
            sig:unsubscribe(handler)
            waker()
        end
        sig:subscribe(handler)
    end)
end

--- Run fn as a sub-coroutine and yield until it completes.
--- Must be called from within a coroutine (started with async.go).
---@param fn fun(): any
---@return { ok: boolean, result: any }
function M.wait_one(fn)
    log.debug("async.wait_one: yield")
    return coroutine.yield(function(waker)
        M.go(fn, function(ok, result)
            log.debug("async.wait_one: waking ok=%s result=%s", tostring(ok), tostring(result))
            waker({ ok = ok, result = result })
        end)
    end)
end

--- Run all fns as parallel coroutines and yield until all complete.
--- Must be called from within a coroutine (started with async.go).
--- Returns an array of { ok: boolean, result: any } in the same order as fns.
---@param fns (fun(): any)[]
---@return { ok: boolean, result: any }[]
function M.wait_all(fns)
    if #fns == 0 then return {} end
    log.debug("async.wait_all: yield count=%d", #fns)
    return coroutine.yield(function(waker)
        local results = {}
        local pending = #fns
        for i, fn in ipairs(fns) do
            M.go(fn, function(ok, result)
                results[i] = { ok = ok, result = result }
                pending = pending - 1
                log.debug("async.wait_all: slot %d done ok=%s pending=%d", i, tostring(ok), pending)
                if pending == 0 then
                    log.debug("async.wait_all: all done, waking")
                    waker(results)
                end
            end)
        end
    end)
end

return M
