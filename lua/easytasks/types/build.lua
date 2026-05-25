---@type easytasks.TaskTypeDef
return {
    run = function()
        return true -- TODO
    end,

    schema = {
        description = "Definition of a `build` task",
        ["x-order"] = { "name", "type", "save_buffers", "if_running", "depends_on", "depends_order", "command", "cwd", "env", "quickfix_matcher" },
        required    = { "command" },
        properties  = {
            command = {
                description = "Command to execute. Can be a single string, a list of arguments, or null to disable execution.",
                oneOf = {
                    { type = "string",  minLength = 1,  description = "Shell command executed as-is" },
                    {
                        type        = "array",
                        minItems    = 1,
                        description = "Command with arguments, executed without shell interpolation",
                        items       = { type = "string", minLength = 1, description = "Command or argument token" },
                    },
                    { type = "null", description = "No command execution" },
                },
            },
            cwd             = { type = { "string", "null" }, description = "Working directory used when executing the command" },
            quickfix_matcher = { type = { "string", "null" }, description = "Name of a quickfix matcher used to parse command output into quickfix entries" },
            env = {
                description = "Environment variables applied to the command execution",
                oneOf = {
                    { type = "string", minLength = 1, description = "Environment variables in VAR1=VALUE1 VAR2=VALUE2 format" },
                    {
                        type                 = { "object", "null" },
                        description          = "Environment variables as a key-value map",
                        additionalProperties = { type = "string" },
                    },
                },
            },
        },
    },
}
