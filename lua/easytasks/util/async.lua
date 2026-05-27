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

return M
