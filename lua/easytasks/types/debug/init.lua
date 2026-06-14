local backends = require("easytasks.types.debug.backends")
local config = require("easytasks.config")

local M = {}

---Debug-relevant fields extracted from a task before dispatch to a backend.
---Backends receive this instead of the raw task so they remain independent of
---the easytasks task schema (which also carries framework fields like `type`,
---`depends_on`, `if_running`, etc.).
---@class easytasks.debug.Params
---@field name            string
---@field adapter         string
---@field request         "launch"|"attach"|nil
---@field host            string|nil
---@field port            integer|nil
---@field command         string|string[]|nil
---@field cwd             string|nil
---@field env             table<string,string>|nil
---@field clear_env       boolean|nil
---@field run_in_terminal boolean|nil
---@field stop_on_entry   boolean|nil
---@field request_args    table|nil
---@field raw_messages    boolean|nil

---@param task table
---@return easytasks.debug.Params
local function _build_params(task)
    return {
        name            = task.name,
        adapter         = task.adapter,
        request         = task.request,
        host            = task.host,
        port            = task.port,
        command         = task.command,
        cwd             = task.cwd,
        env             = task.env,
        clear_env       = task.clear_env,
        run_in_terminal = task.run_in_terminal,
        stop_on_entry   = task.stop_on_entry,
        request_args    = task.request_args,
        raw_messages    = task.raw_messages,
    }
end

---@param task    table
---@param ctx     easytasks.RunCtx
---@param on_done fun(ok: boolean)
---@return fun()
function M.start(task, ctx, on_done)
    local backend_name = config.debug_backend
    if not backend_name then
        ctx.report("Debug backend name missing from configuration")
        on_done(false)
        return function() end
    end
    local backend = backends.get(backend_name)
    if not backend then
        ctx.report("Invalid debug backend in configuration: " .. tostring(backend_name) .. "")
        on_done(false)
        return function() end
    end
    return backend.run(_build_params(task), ctx, on_done)
end

M.schema = {
    description = "Definition of a `debug` task (runs via a DAP adapter)",
    ["x-order"] = {
        "name", "type", "if_running", "depends_on", "depends_order",
        "adapter", "request", "host", "port",
        "command", "args", "cwd", "env", "clear_env", "run_in_terminal", "stop_on_entry",
        "request_args", "raw_messages",
    },
    required    = { "adapter" },
    properties  = {
        adapter         = {
            type        = "string",
            minLength   = 1,
            description = "Name of the DAP adapter to use (e.g. codelldb, delve, debugpy)",
            enum        = function()
                local bname = config.debug_backend
                if bname then
                    local b = backends.get(bname)
                    return b and b.adapters and b.adapters() or {}
                end
            end
        },
        host            = {
            type        = { "string", "null" },
            minLength   = 1,
            description =
            "Hostname or IP address of the DAP server to connect to (attach only; overrides the adapter default)",
        },
        port            = {
            type        = { "integer", "null" },
            minimum     = 1,
            maximum     = 65535,
            description = "TCP port of the DAP server to connect to (attach only; required for `remote` adapter)",
        },
        request         = {
            description = "Whether to launch a new process or attach to a running one",
            oneOf       = {
                { type = "string", const = "launch", description = "Start the program under the debugger" },
                { type = "string", const = "attach", description = "Attach to an already-running process" },
            },
        },
        command         = {
            description =
            "Program to debug. A string is a plain path; an array is [program, arg1, …] shorthand (args are merged with `args` if also set)",
            oneOf       = {
                { type = "string", minLength = 1,               description = "Path to the executable" },
                { type = "array",  items = { type = "string" }, minItems = 1,                          description = "Executable followed by arguments" },
            },
        },
        cwd             = {
            type        = { "string", "null" },
            minLength   = 1,
            description = "Working directory for the debugged program",
        },
        env             = {
            type                 = { "object", "null" },
            description          = "Environment variables for the debugged program",
            additionalProperties = { type = "string" },
        },
        clear_env       = {
            type        = { "boolean", "null" },
            description = "Pass `env` verbatim without merging with the current process environment",
        },
        run_in_terminal = {
            type        = { "boolean", "null" },
            description = "Ask the DAP client to spawn an integrated terminal for the program's stdio",
        },
        stop_on_entry   = {
            type        = { "boolean", "null" },
            description = "Pause execution at the program's entry point before running any user code",
        },
        request_args    = {
            type                 = { "object", "null" },
            description          =
            "Arguments sent verbatim in the DAP launch or attach request (takes precedence over all generic fields above)",
            additionalProperties = true,
        },
        raw_messages    = {
            type        = { "boolean", "null" },
            description = "Capture all raw DAP protocol messages in a dedicated buffer attached to the task",
        },
    },
}

---@return table[]
M.templates = function()
    local b = backends.current()
    return b and b.templates or {}
end

return M --[[@as easytasks.TaskTypeDef]]
