local schema_mod = require("easytasks.types.schema")

---@class easytasks.Types
local M = {}

---@type table<string, easytasks.TaskTypeDef>
local registry = {}

---@param name     string
---@param type_def easytasks.TaskTypeDef
function M.register(name, type_def)
    registry[name] = type_def
end

---@return table<string, easytasks.TaskTypeDef>
function M.get_all()
    return registry
end

---@return table JSON Schema
function M.build_schema()
    return schema_mod.build(registry)
end

-- Built-in task types
M.register("process",   require("easytasks.types.process"))
M.register("composite", require("easytasks.types.composite"))
M.register("build",     require("easytasks.types.build"))
M.register("debug",     require("easytasks.types.debug"))

return M
