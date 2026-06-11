local schema_mod = require("easytasks.types.schema")

---@alias easytasks.TypeLoader string|fun(): easytasks.TaskTypeDef|easytasks.TaskTypeDef

---@class easytasks.Types
local M = {}

---@type table<string, easytasks.TypeLoader>
local _loaders = {}

---@type table<string, easytasks.TaskTypeDef>
local _cache = {}

---@param name string
---@return easytasks.TaskTypeDef?
local function _resolve(name)
    if _cache[name] then return _cache[name] end
    local loader = _loaders[name]
    if loader == nil then return nil end
    local def
    if type(loader) == "string" then
        def = require(loader) ---@type easytasks.TaskTypeDef
    elseif type(loader) == "function" then
        def = loader()
    else
        def = loader
    end
    _cache[name] = def
    return def
end

--- Register a task type.
--- `loader` may be a module path string, a zero-arg factory function, or a
--- fully-resolved TaskTypeDef table.
---@param name   string
---@param loader easytasks.TypeLoader
function M.register(name, loader)
    _loaders[name] = loader
    _cache[name]   = nil
end

--- Return the resolved TaskTypeDef for `name`, or nil if unknown.
---@param name string
---@return easytasks.TaskTypeDef?
function M.get(name)
    return _resolve(name)
end

--- Return all registered type names without resolving any loaders.
---@return string[]
function M.get_names()
    return vim.tbl_keys(_loaders)
end

--- Resolve and return all registered types.
---@return table<string, easytasks.TaskTypeDef>
function M.get_all()
    local result = {}
    for name in pairs(_loaders) do
        result[name] = _resolve(name)
    end
    return result
end

---@return table JSON Schema
function M.build_schema()
    return schema_mod.build(M.get_all())
end

-- Built-in task types (loaded lazily on first use)
M.register("run",         "easytasks.types.run")
M.register("composite",   "easytasks.types.composite")

return M
