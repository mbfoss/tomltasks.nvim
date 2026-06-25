local ordered        = require("easytasks.util.table_util").ordered
local term           = require("easytasks.util.term")
local notify         = require("easytasks.ui")
local qfmatchers     = require("easytasks.types.run.qfmatchers")
local str_util       = require("easytasks.util.str_util")

---@type table<string, easytasks.QfMatcher>
local _user_matchers = {}

---@param s string
---@return string
local function _strip_ansi(s)
    return (s:gsub("\27%[[%d;]*[A-Za-z]", ""))
end

---@param name string?
---@return (fun(line: string): easytasks.QfItem?)?, string?
local function _make_qf_parser(name)
    if not name or name == "" then return nil end
    local fn = _user_matchers[name] or qfmatchers[name]
    if not fn then return nil, "unknown quickfix matcher: " .. name end
    local ctx = {}
    return function(line) return fn(_strip_ansi(line), ctx) end
end

--- Register a custom quickfix matcher for run tasks.
---@param name string
---@param fn   easytasks.QfMatcher
local function _register_qfmatcher(name, fn)
    _user_matchers[name] = fn
end

---@type easytasks.TaskTypeDef & { register_qfmatcher: fun(name: string, fn: easytasks.QfMatcher) }
local M = {
    register_qfmatcher = _register_qfmatcher,

    dispose = function(bufnrs)
        for _, be in ipairs(bufnrs) do
            if vim.api.nvim_buf_is_valid(be.bufnr) then
                pcall(vim.api.nvim_buf_delete, be.bufnr, { force = true })
            end
        end
    end,

    ---@type easytasks.RunFn
    start = function(task, ctx, on_done)
        if not task.command then
            notify.notify_error("run task '" .. task.name .. "' has no command")
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

        -- Resolve command into the form vim.fn.jobstart expects.
        local cmd
        if task.shell then
            if type(task.command) ~= "string" then
                notify.notify_error("run task '" .. task.name .. "': shell mode requires a string command")
                on_done(false)
                return function() end
            end
            cmd = task.command
        else
            if type(task.command) == "string" then
                cmd = str_util.split_shell_args(task.command)
                if #cmd == 0 then
                    notify.notify_error("run task '" .. task.name .. "': command string is empty")
                    on_done(false)
                    return function() end
                end
            else
                cmd = task.command
            end
        end

        local cmd_exe = type(cmd) == "string" and cmd:match("^%S+") or cmd[1] or nil
        local label = cmd_exe and vim.fn.fnamemodify(cmd_exe, ":t") or nil

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
        description = "Definition of a `run` task",
        ["x-order"] = { "name", "type", "if_running", "depends_on", "depends_order", "save_buffers", "shell", "command", "cwd", "env", "clear_env", "quickfix_matcher" },
        required    = { "command" },
        properties  = {
            shell            = {
                type        = "boolean",
                default     = false,
                description =
                "When true, the command string is passed to the shell for interpretation. When false (default), the command is executed directly — strings are split into argv via POSIX shell-word rules, arrays are used as-is.",
            },
            command          = {
                description = "Command to execute.",
                oneOf = {
                    { type = "string", minLength = 1,                       description = "Command string. Shell mode: evaluated by the shell. Direct mode: split into argv via POSIX shell-word rules." },
                    {
                        type        = "array",
                        minItems    = 1,
                        description = "Program and arguments, used as-is in direct mode (shell = false).",
                        items       = { type = "string", minLength = 1, description = "Command or argument token" },
                    },
                    { type = "null",   description = "No command execution" },
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
                enum        = function()
                    local names = {}
                    for k in pairs(qfmatchers) do names[#names + 1] = k end
                    for k in pairs(_user_matchers) do names[#names + 1] = k end
                    table.sort(names)
                    return names
                end,
            },
        },
    },

    templates = {
        {
            label = "Process",
            task  = ordered({ name = "run", type = "run", command = "" },
                { "name", "type", "command" }),
        },
        {
            label = "Shell command",
            task  = ordered({ name = "command", type = "run", shell = true, command = "" },
                { "name", "type", "shell", "command" }),
        },
    },
}

return M
