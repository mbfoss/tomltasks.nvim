--- Resolves dynamic task field values. Any field whose value is a function is
--- called (lazily, at run time) and replaced with its return value. Functions
--- run inside a coroutine, so they may yield — e.g. to prompt the user (see
--- `easytasks.values`). This replaces the old `${…}` string-macro engine.
---@class easytasks.runner.resolver
local M = {}

---@param tbl table
---@param ctx easytasks.ValueCtx
local function _resolve_into(tbl, ctx)
    for k, v in pairs(tbl) do
        local tv = type(v)
        if tv == "function" then
            local val, err = v(ctx)
            if val == nil and err then error(err, 0) end
            if type(val) == "table" then _resolve_into(val, ctx) end
            tbl[k] = val
        elseif tv == "table" then
            _resolve_into(v, ctx)
        end
    end
end

--- Resolve all function-valued fields in `val` against `ctx`, asynchronously.
--- `val` is deep-copied first, so the caller's table is never mutated and the
--- original (pre-resolution) values remain visible via `ctx.task`.
---@param val      table|any              the task table (or any value) to resolve
---@param ctx      easytasks.ValueCtx
---@param callback fun(ok: boolean, result: any, err: string?)
function M.resolve_values(val, ctx, callback)
    coroutine.wrap(function()
        local ok, result = xpcall(function()
            if type(val) ~= "table" then return val end
            local copy = vim.deepcopy(val)
            _resolve_into(copy, ctx)
            return copy
        end, debug.traceback)

        if ok then
            vim.schedule(function() callback(true, result, nil) end)
        else
            local err = type(result) == "string" and result or tostring(result)
            local clean = err:match(":%d+: (.*)\nstack traceback:")
            if clean then err = clean end
            vim.schedule(function() callback(false, nil, err) end)
        end
    end)()
end

return M
