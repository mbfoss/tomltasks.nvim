local exec = require("easytasks.runner.exec")

---@class easytasks.Runner
local M = {}

--- Run a named task from a TOML config file.
--- Non-blocking: execution is driven by coroutines and libuv callbacks.
---@param task_name string
---@param toml_path string
---@param opts      {show_output?: boolean}?
function M.run(task_name, toml_path, opts)
    exec.run(task_name, toml_path, opts)
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

--- Return the sorted list of task names from a TOML file, or nil + error string.
---@param toml_path string
---@return string[]?, string?
function M.list_tasks(toml_path)
    return exec.list(toml_path)
end

return M
