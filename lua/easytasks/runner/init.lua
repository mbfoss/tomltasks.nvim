local exec = require("easytasks.runner.exec")

---@class easytasks.Runner
local M = {}

--- Run a named task from a Lua tasks file.
--- Non-blocking: execution is driven by coroutines and libuv callbacks.
---@param task_name string
---@param path string
function M.run(task_name, path)
    exec.run(task_name, path)
end

--- Stop a running task.
---@param task_name string
function M.stop(task_name)
    exec.stop(task_name)
end

--- Dispose a finished run: delete its buffers and remove it from state.
--- Returns false + error string if the run is still active.
---@param run_id string
---@return boolean ok, string? err
function M.dispose(run_id)
    return exec.dispose(run_id)
end

--- Return the current execution state of a task.
---@param task_name string
---@return easytasks.TaskState
function M.state(task_name)
    return exec.state(task_name)
end

--- Return the sorted list of task names and a by-name lookup from a tasks file.
---@param path string
---@return string[]? ordered
---@return table<string,table>? by_name
---@return string? err
function M.list_tasks(path)
    return exec.list(path)
end

return M
