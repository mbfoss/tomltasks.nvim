local ordered    = require("easytasks.util.table_util").ordered
local term       = require("easytasks.util.term")
local notify     = require("easytasks.ui")
local str_util   = require("easytasks.util.str_util")
local qfmatchers = require("easytasks.types.qfmatchers")

---@param s string
---@return string
local function _strip_ansi(s)
    return (s:gsub("\27%[[%d;]*[A-Za-z]", ""))
end

---@param name string?
---@return (fun(line: string): easytasks.QfItem?)?, string?
local function _make_qf_parser(name)
    if not name or name == "" then return nil end
    local fn = qfmatchers.get(name)
    if not fn then return nil, "unknown quickfix matcher: " .. name end
    local ctx = {}
    return function(line) return fn(_strip_ansi(line), ctx) end
end

---@class easytasks.ProcessTask : easytasks.TaskBase
---@field command?          string|string[]       command to run directly (string split via shell-word rules, array used as-is)
---@field cwd?              string                working directory used when executing the command
---@field env?              table<string,string>  environment variables as a key-value map
---@field clear_env?        boolean               pass `env` verbatim without merging the current environment
---@field quickfix_matcher? string                name of a quickfix matcher used to parse output

--- The `process` task type: runs a command directly, without a shell. A string
--- command is split into argv via POSIX shell-word rules; an array is used as-is.
---@type easytasks.TaskTypeDef & { register_qfmatcher: fun(name: string, fn: easytasks.QfMatcher) }
local M = {
    register_qfmatcher = qfmatchers.register,

    ---@type easytasks.DisposeFn
    dispose = function(bufnrs)
        for _, be in ipairs(bufnrs) do
            if vim.api.nvim_buf_is_valid(be.bufnr) then
                pcall(vim.api.nvim_buf_delete, be.bufnr, { force = true })
            end
        end
    end,

    ---@type easytasks.RunFn
    start = function(task, ctx, on_done)
        ---@cast task easytasks.ProcessTask
        local command = task.command
        if not command then
            notify.notify_error("process task '" .. task.name .. "' has no command")
            on_done(false)
            return function() end
        end

        local qf_parse, qf_err = _make_qf_parser(task.quickfix_matcher)
        if qf_err then
            notify.notify_error(qf_err)
            on_done(false)
            return function() end
        end

        if qf_parse then
            vim.fn.setqflist({}, "r")
        end

        -- Direct execution: a string is split into argv, an array is used as-is.
        ---@type string[]
        local cmd
        if type(command) == "string" then
            cmd = str_util.split_shell_args(command)
            if #cmd == 0 then
                notify.notify_error("process task '" .. task.name .. "': command string is empty")
                on_done(false)
                return function() end
            end
        else
            cmd = command
        end

        local label = cmd[1] and vim.fn.fnamemodify(cmd[1], ":t") or nil

        local on_data
        if qf_parse then
            on_data = function(_, data)
                vim.schedule(function()
                    if not data then return end
                    local items = {}
                    for _, line in ipairs(data) do
                        if line ~= "" then
                            local qf_item = qf_parse(line)
                            if qf_item then items[#items + 1] = qf_item end
                        end
                    end
                    if #items > 0 then vim.fn.setqflist(items, "a") end
                end)
            end
        end

        local handle, spawn_err = term.spawn(cmd, {
            cwd       = task.cwd,
            env       = task.env,
            clear_env = task.clear_env,
            on_stdout = on_data,
            on_stderr = on_data,
            on_exit   = function(code) on_done(code == 0) end,
        })

        if not handle then
            vim.schedule(function()
                ctx.report("job start failed: " .. tostring(spawn_err))
                on_done(false)
            end)
            return function() end
        end
        ctx.add_bufnr(handle.bufnr, { label = label })
        return function() handle.stop() end
    end,

    schema = {
        description = "Definition of a `process` task",
        ["x-order"] = { "name", "type", "if_running", "depends_on", "depends_order", "save_buffers", "command", "cwd", "env", "clear_env", "quickfix_matcher" },
        required    = { "command" },
        properties  = {
            command          = {
                description = "Command to execute directly, without a shell.",
                oneOf = {
                    { type = "string", minLength = 1, description = "Command string, split into argv via POSIX shell-word rules." },
                    {
                        type        = "array",
                        minItems    = 1,
                        description = "Program and arguments, used as-is.",
                        items       = { type = "string", minLength = 1, description = "Command or argument token" },
                    },
                    { type = "null", description = "No command execution" },
                },
            },
            cwd              = { type = { "string", "null" }, description = "Working directory used when executing the command" },
            env              = {
                type                 = { "object", "null" },
                description          = "Environment variables as a key-value map",
                additionalProperties = { type = "string" },
            },
            clear_env        = {
                type        = { "boolean", "null" },
                description = "Pass `env` verbatim without merging with the current process environment",
            },
            quickfix_matcher = {
                type        = { "string", "null" },
                description = "Name of a quickfix matcher used to parse command output into quickfix entries",
                enum        = qfmatchers.names,
            },
        },
    },

    templates = {
        {
            label = "Process",
            task  = ordered({ name = "process", type = "process", command = "" },
                { "name", "type", "command" }),
        },
    },
}

return M
