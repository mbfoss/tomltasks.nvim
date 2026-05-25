---@type easytasks.TaskTypeDef
return {
    run = function(task, ctx)
        if not task.command then
            vim.notify("[easytasks] process task '" .. task.name .. "' has no command", vim.log.levels.ERROR)
            return false
        end
        local code = ctx.spawn(task.command, { cwd = task.cwd, env = task.env })
        return code == 0
    end,

    schema = {
        description = "Definition of a `process` task",
        ["x-order"] = { "name", "type", "save_buffers", "if_running", "depends_on", "depends_order", "command", "cwd", "env" },
        required    = { "command" },
        properties  = {
            command = {
                description = "Command to execute. Can be a single string or a list of strings (program + args).",
                oneOf = {
                    { type = "string",  minLength = 1,  description = "Command or process to execute, can include arguments" },
                    {
                        type        = "array",
                        minItems    = 1,
                        description = "Command with arguments, executed without shell interpolation",
                        items       = { type = "string", minLength = 1, description = "Command or argument token" },
                    },
                    { type = "null", description = "No command execution" },
                },
            },
            cwd = { type = { "string", "null" }, description = "Working directory used when executing the command" },
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
