local config = require("easytasks.config")

---@class easytasks.debug.Module : easytasks.TaskTypeDef
local M = {}

--- Rich, generic-field schema. easydap was designed around it and derives the
--- DAP launch/attach `request_args` from the generic fields (`command`, `cwd`,
--- `env`, `stop_on_entry`, …).
---@param adapters (fun(): string[])?  adapter-name enum source for the schema
---@return table
local function _schema(adapters)
    return {
        description = "Definition of a `debug` task (runs via a DAP adapter)",
        ["x-order"] = {
            "name", "type", "if_running", "depends_on", "depends_order", "save_buffers",
            "adapter", "request", "host", "port",
            "command", "cwd", "env", "clear_env", "run_in_terminal", "stop_on_entry",
            "request_args", "raw_messages",
        },
        required    = { "adapter" },
        properties  = {
            adapter         = {
                type        = "string",
                minLength   = 1,
                description = "Name of the DAP adapter to use (e.g. codelldb, delve, debugpy)",
                enum        = adapters,
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
            request         =
            {
                type                   = { "string", "null" },
                enum                   = { "launch", "attach" },
                ["x-enumDescriptions"] = { "Start the program under the debugger", "Attach to an already-running process" },
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
            process_id   = {
                type        = { "number", "string", "null" },
                description = "Process Id. used when attaching to a process, use ${select-pid} to open selector",
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
end


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

---A `debug` task: the generic debug fields plus the shared task base.
---@class easytasks.DebugTask : easytasks.TaskBase
---@field adapter          string
---@field request?         "launch"|"attach"
---@field host?            string
---@field port?            integer
---@field command?         string|string[]
---@field cwd?             string
---@field env?             table<string,string>
---@field clear_env?       boolean
---@field run_in_terminal? boolean
---@field stop_on_entry?   boolean
---@field process_id?      number
---@field request_args?    table
---@field raw_messages?    boolean

---@param task easytasks.DebugTask
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
        process_id      = task.process_id,
        request_args    = task.request_args,
        raw_messages    = task.raw_messages,
    }
end

---@param task    easytasks.DebugTask
---@param ctx     easytasks.RunCtx
---@param on_done fun(ok: boolean)
---@return fun()
function M.start(task, ctx, on_done)
    local m = require("easydap.task")
    return m.start(_build_params(task), {
        add_bufnr = ctx.add_bufnr,
        report    = ctx.report,
        on_done   = on_done,
    })
end

M.schema = function()
    return _schema(function()
        local adapters = require("easydap.adapters") or {}
        local names = vim.tbl_keys(adapters)
        table.sort(names)
        return names
    end)
end

---@return table[]
M.templates = function()
    return require("easytasks.types.debug.templates")
end

return M
