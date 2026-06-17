---@alias easytasks.TypeLoader string|fun(): easytasks.TaskTypeDef|easytasks.TaskTypeDef

--- A template offered by `:Tasks template`: a label and a task `spec` table
--- that is rendered to a Lua snippet and inserted at the cursor.
---@class easytasks.TaskTemplate
---@field label string
---@field spec  table   task-shaped spec (may include `name`/`type`)

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

--- Validate a (resolved) task against its type. Returns ok plus an error string.
--- Unknown types and per-type `validate` hooks are both reported here.
---@param task table
---@return boolean ok, string? err
function M.validate(task)
    if type(task.type) ~= "string" then
        return false, "task '" .. tostring(task.name) .. "' has no `type`"
    end
    local def = _resolve(task.type)
    if not def then
        return false, "unknown task type: " .. task.type
    end
    if def.validate then
        return def.validate(task)
    end
    return true
end

-- Built-in task types (loaded lazily on first use)
M.register("run",       "easytasks.types.run")
M.register("composite", "easytasks.types.composite")
M.register("debug",     "easytasks.types.debug")

return M
