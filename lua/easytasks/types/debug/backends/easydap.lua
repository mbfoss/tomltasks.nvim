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
end

---@return easytasks.debug.Backend?
return function()
    local ok, m      = pcall(require, "easydap.task")
    local ok2, adaps = pcall(require, "easydap.adapters")
    if not ok then return nil end
    local adapters = ok2 and function()
        local names = vim.tbl_keys(adaps)
        table.sort(names)
        return names
    end or nil
    return {
        schema    = _schema(adapters),
        -- easydap.task.start takes (task, opts, callbacks); adapt the backend's
        -- (params, ctx, on_done). easytasks owns the buffers/progress, so default
        -- opts (REPL + output buffers) are used and registered through ctx.
        run       = function(params, ctx, on_done)
            return m.start(params, {
                add_bufnr = ctx.add_bufnr,
                report    = ctx.report,
                on_done   = on_done,
            })
        end,
        adapters  = adapters,
        templates = m.templates,
    }
end
