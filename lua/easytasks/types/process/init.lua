local ordered  = require("easytasks.util.table_util").ordered
local term     = require("easytasks.types.process.term")
local spawn    = require("easytasks.types.process.spawn").spawn

---@type easytasks.TaskTypeDef
return {
    run = function(task, ctx)
        if not task.command then
            vim.notify("[easytasks] process task '" .. task.name .. "' has no command", vim.log.levels.ERROR)
            return false
        end

        local bufnr = term.open(task.name)
        ctx.set_bufnr(bufnr)

        -- A terminal buffer must be in a visible window for jobstart {term=true}.
        -- Open a minimal float for the duration of the job, then discard it.
        -- The buffer stays listed so the user can open it from the status panel.
        local float_win = vim.api.nvim_open_win(bufnr, false, {
            relative  = "editor",
            row       = 0,
            col       = 0,
            width     = math.max(1, vim.o.columns),
            height    = math.max(1, vim.o.lines - 2),
            style     = "minimal",
            focusable = false,
            zindex    = 1,
        })

        local code = spawn(task.command, { cwd = task.cwd, env = task.env }, bufnr)

        pcall(vim.api.nvim_win_close, float_win, true)

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
                    { type = "string", minLength = 1,                       description = "Command or process to execute, can include arguments" },
                    {
                        type        = "array",
                        minItems    = 1,
                        description = "Command with arguments, executed without shell interpolation",
                        items       = { type = "string", minLength = 1, description = "Command or argument token" },
                    },
                    { type = "null",   description = "No command execution" },
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
    templates = {
        {
            label = "Shell command",
            task  = ordered({ name = "my-cmd", type = "process", command = "echo hello" },
                { "name", "type", "command" }),
        },
        {
            label = "Watch mode",
            task  = ordered({ name = "watch", type = "process", command = "npm run watch" },
                { "name", "type", "command" }),
        },
    }
}
