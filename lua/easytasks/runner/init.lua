local exec       = require("easytasks.runner.exec")
local schema_mod = require("easytasks.schema")

---@class easytasks.Runner
local M = {}

---@type table<string, easytasks.TaskTypeDef>
local types = {}

--- Register a task type.
---@param name     string
---@param type_def easytasks.TaskTypeDef
function M.register(name, type_def)
    types[name] = type_def
end

--- Build the full JSON Schema for the tasks config from all registered types.
---@return table JSON Schema
function M.build_schema()
    return schema_mod.build(types)
end

--- Run a named task from a TOML config file.
--- Non-blocking: execution is driven by coroutines and libuv callbacks.
---@param task_name  string
---@param toml_path  string
---@param opts       {show_output?: boolean}?
function M.run(task_name, toml_path, opts)
    exec.run(task_name, toml_path, types, opts)
end

--- Stop a running task.
---@param task_name string
function M.stop(task_name)
    exec.stop(task_name)
end

--- Return the current execution state of a task.
---@param task_name string
---@return easytasks.TaskState
function M.state(task_name)
    return exec.state(task_name)
end

-- Register built-in task types at load time.
-- Users can override these by calling register() with the same name before setup().
M.register("process",   require("easytasks.runner.types.process"))
M.register("composite", require("easytasks.runner.types.composite"))
M.register("build",     require("easytasks.runner.types.build"))
M.register("debug",     require("easytasks.runner.types.debug"))

return M
