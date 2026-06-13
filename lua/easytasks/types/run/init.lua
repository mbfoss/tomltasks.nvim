local ordered        = require("easytasks.util.table_util").ordered
local term           = require("easytasks.util.term")
local notify         = require("easytasks.ui")
local qfmatchers     = require("easytasks.types.run.qfmatchers")
local save_buffers   = require("easytasks.types.run.save_buffers")
local project        = require("easytasks.project")
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

    ---@return fun()
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

        if task.save_buffers then
            local root = project.find_root()
            if root then
                local n, paths = save_buffers.save(root, { include_globs = {}, exclude_globs = {} })
                if n > 0 then
                    local lines = { ("saved %d file%s:"):format(n, n == 1 and "" or "s") }
                    for i = 1, math.min(n, 5) do lines[#lines + 1] = "  " .. paths[i] end
                    if n > 5 then lines[#lines + 1] = ("  … and %d more"):format(n - 5) end
                    ctx.report(table.concat(lines, "\n"))
                end
            end
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
        ctx.add_bufnr(handle.bufnr, label)
        return function() handle.stop() end
    end,

    schema = {
        description = "Definition of a `run` task",
        ["x-order"] = { "name", "type", "save_buffers", "if_running", "depends_on", "depends_order", "shell", "command", "cwd", "env", "quickfix_matcher" },
        required    = { "command" },
        properties  = {
            save_buffers     = {
                type        = "boolean",
                default     = false,
                description = "If true, all modified project buffers will be saved before running the task",
            },
            shell            = {
                type        = "boolean",
                default     = false,
                description = "When true, the command string is passed to the shell for interpretation. When false (default), the command is executed directly — strings are split into argv via POSIX shell-word rules, arrays are used as-is.",
            },
            command          = {
                description = "Command to execute.",
                oneOf = {
                    { type = "string",  minLength = 1, description = "Command string. Shell mode: evaluated by the shell. Direct mode: split into argv via POSIX shell-word rules." },
                    {
                        type        = "array",
                        minItems    = 1,
                        description = "Program and arguments, used as-is in direct mode (shell = false).",
                        items       = { type = "string", minLength = 1, description = "Command or argument token" },
                    },
                    { type = "null", description = "No command execution" },
                },
            },
            cwd              = { type = { "string", "null" }, description = "Working directory used when executing the command" },
            env              = {
                description = "Environment variables applied to the command execution",
                {
                    type                 = { "object", "null" },
                    description          = "Environment variables as a key-value map",
                    additionalProperties = { type = "string" },
                },
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
            label = "Direct process",
            task  = ordered({ name = "my-proc", type = "run", command = { "npm", "run", "build" } },
                { "name", "type", "command" }),
        },
        {
            label = "Shell command",
            task  = ordered({ name = "my-cmd", type = "run", shell = true, command = "echo hello" },
                { "name", "type", "shell", "command" }),
        },
        {
            label = "Watch mode",
            task  = ordered({ name = "watch", type = "run", shell = true, command = "npm run watch" },
                { "name", "type", "shell", "command" }),
        },
        {
            label = "Shell command with quickfix",
            task  = ordered({ name = "build", type = "run", shell = true, command = "make", quickfix_matcher = "gcc" },
                { "name", "type", "shell", "command", "quickfix_matcher" }),
        },
    },
}

return M
