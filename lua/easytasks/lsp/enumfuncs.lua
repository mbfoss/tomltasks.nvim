--- Registry of named enum generator functions used via the x-enumfunc schema field.
--- Each generator receives the decoded root data and a context describing the cursor
--- location, and returns a list of completion values.
local M = {}

---@alias easytasks.EnumFunc fun(data: any, ctx: easytasks.EnumFuncContext):((string|{label:string,description:string?})[])

---@class easytasks.EnumFuncContext
---@field data any       decoded root data
---@field path string[]  key path from root to the field being completed (e.g. {"tasks","2","depends_on"})

---@type table<string, (string|{label:string,description:string?})[]>
local _static = {}

---@type table<string,easytasks.EnumFunc>
local _registry = {
    -- Returns all task names except the one currently being edited.
    -- Useful for depends_on so a task cannot list itself as a dependency.
    ["easytasks.tasks.names"] = function(data, ctx)
        local exclude
        -- path = {"tasks", "<idx>", "depends_on"} when inside an AoT task entry
        if ctx and ctx.path and ctx.path[1] == "tasks" then
            local idx = tonumber(ctx.path[2])
            if idx and type(data) == "table" and type(data.tasks) == "table" then
                local task = data.tasks[idx]
                if type(task) == "table" then exclude = task.name end
            end
        end
        local names = {}
        if type(data) == "table" and type(data.tasks) == "table" then
            for _, task in ipairs(data.tasks) do
                if type(task) == "table" and type(task.name) == "string"
                    and task.name ~= exclude then
                    names[#names + 1] = task.name
                end
            end
        end
        return names
    end,
}

--- Register a custom enum generator.
---@param key string  the x-enumfunc value used in schema fields
---@param fn easytasks.EnumFunc
function M.register(key, fn)
    _registry[key] = fn
end

--- Load pre-computed static enum values. Called in the subprocess on initialize
--- so that enumfuncs registered only in the main process are still usable.
---@param tbl table<string, (string|{label:string,description:string?})[]>
function M.load_static(tbl)
    _static = tbl or {}
end

--- Collect results from all registered enumfuncs by calling each with nil data.
--- Used to build the static_enums payload passed to the subprocess.
---@return table<string, (string|{label:string,description:string?})[]>
function M.collect_static()
    local out = {}
    for key, fn in pairs(_registry) do
        local ok, vals = pcall(fn, nil, { data = nil, path = {} })
        if ok and type(vals) == "table" then
            out[key] = vals
        end
    end
    return out
end

--- Resolve a generator by key. Checks the live registry first, then the static
--- fallback table (for keys registered only in the main process), then falls
--- back to a dotted Lua global path (e.g. "mymod.sub.fn").
---@param  key string
---@return easytasks.EnumFunc?
function M.resolve(key)
    if _registry[key] then return _registry[key] end
    if _static[key] then
        local vals = _static[key]
        return function() return vals end
    end
    local obj = _G
    for part in key:gmatch("[^.]+") do
        if type(obj) ~= "table" then return nil end
        obj = obj[part]
    end
    return type(obj) == "function" and obj or nil
end

return M
