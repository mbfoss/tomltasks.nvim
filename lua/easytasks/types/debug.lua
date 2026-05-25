---@type easytasks.TaskTypeDef
return {
    run = function()
        return true -- TODO
    end,

    schema = {
        description = "Definition of a `debug` task",
        ["x-order"] = { "name", "type", "save_buffers", "if_running", "depends_on", "depends_order", "command", "cwd", "debugger", "host", "port", "request", "terminate_on_disconnect", "debug_options" },
        required    = { "debugger", "request" },
        properties  = {
            debugger = {
                type                = "string",
                ["x-valueSelector"] = "loop-debug.tools.dbgselect.select",
                description         = "Debugger backend to use (e.g. gdb, lldb, node, python).",
            },
            request = {
                type        = "string",
                enum        = { "launch", "attach" },
                description = "How to start debugging: 'launch' starts a new process, 'attach' connects to an existing one.",
            },
            command = {
                description = "Command used to start the debugger or debug adapter.",
                oneOf = {
                    { type = "string" },
                    { type = "array", items = { type = "string" } },
                },
            },
            cwd                    = { type = "string", description = "Working directory for the debug session. Defaults to `${wsdir}` if not specified" },
            env                    = { type = "object", description = "Environment variables passed to the debugged process.", additionalProperties = { type = "string" } },
            host                   = { type = "string", minLength = 1, description = "Host name for the remote debugger" },
            port                   = { type = "number", description = "Port number for the remote debugger" },
            terminate_on_disconnect = { type = "boolean", description = "Terminate the debugged process when the debugger disconnects." },
            debug_options          = { type = "object", additionalProperties = true, description = "Arbitrary key-value pairs passed specifically to the debugger backend." },
        },
        -- when debugger = "remote", host and port are required
        ["if"]   = { type = "object", properties = { debugger = { const = "remote" } } },
        ["then"] = { type = "object", required = { "host", "port" } },
    },
}
