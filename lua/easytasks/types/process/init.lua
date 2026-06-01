local ordered        = require("easytasks.util.table_util").ordered
local term           = require("easytasks.types.process.term")
local spawn          = require("easytasks.types.process.spawn").spawn
local _notify        = require("easytasks.ui")
local enumfuncs      = require("easytasks.lsp.enumfuncs")
local qfmatchers     = require("easytasks.types.process.qfmatchers")

---@type table<string, easytasks.QfMatcher>
local _user_matchers = {}

enumfuncs.register("easytasks.process.qfmatchers", function()
    local names = {}
    for k in pairs(qfmatchers) do names[#names + 1] = k end
    for k in pairs(_user_matchers) do names[#names + 1] = k end
    table.sort(names)
    return names
end)

---@param s string
---@return string
local function strip_ansi(s)
    return (s:gsub("\27%[[%d;]*[A-Za-z]", ""))
end

---@param name string?
---@return (fun(line: string): easytasks.QfItem?)?, string?
local function make_qf_parser(name)
    if not name or name == "" then return nil end
    local fn = _user_matchers[name] or qfmatchers[name]
    if not fn then return nil, "unknown quickfix matcher: " .. name end
    local ctx = {}
    return function(line) return fn(strip_ansi(line), ctx) end
end

--- Register a custom quickfix matcher for process tasks.
---@param name string
---@param fn   easytasks.QfMatcher
local function register_qfmatcher(name, fn)
    _user_matchers[name] = fn
end

---@type easytasks.TaskTypeDef & { register_qfmatcher: fun(name: string, fn: easytasks.QfMatcher) }
local M = {
    register_qfmatcher = register_qfmatcher,

    run = function(task, ctx, on_done)
        if not task.command then
            _notify.notify_error("process task '" .. task.name .. "' has no command")
            on_done(false)
            return
        end

        local qf_parse, qf_err = make_qf_parser(task.quickfix_matcher)
        if qf_err then
            _notify.notify_error(qf_err)
            on_done(false)
            return
        end

        if qf_parse then
            vim.fn.setqflist({}, "r")
        end

        local bufnr = term.open(task.name)
        ctx.add_bufnr(bufnr)

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

        local handle = spawn(task.command, { cwd = task.cwd, env = task.env, on_stdout = on_data, on_stderr = on_data },
            bufnr)
        ctx.set_cancel(function() handle.stop() end)
        handle.on_exit(function(code) on_done(code == 0) end)
    end,

    schema = {
        description = "Definition of a `process` task",
        ["x-order"] = { "name", "type", "save_buffers", "if_running", "depends_on", "depends_order", "command", "cwd", "env", "quickfix_matcher" },
        required    = { "command" },
        properties  = {
            command          = {
                description = "Command to execute. Can be a single string or a list of strings (program + args).",
                oneOf = {
                    { type = "string", minLength = 1,                       description = "Command executed in the shell" },
                    {
                        type        = "array",
                        minItems    = 1,
                        description = "Command with arguments, executed without shell interpolation",
                        items       = { type = "string", minLength = 1, description = "Command or argument token" },
                    },
                    { type = "null",   description = "No command execution" },
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
                type           = { "string", "null" },
                description    = "Name of a quickfix matcher used to parse command output into quickfix entries",
                ["x-enumfunc"] = "easytasks.process.qfmatchers",
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
        {
            label = "Shell command with quickfix",
            task  = ordered({ name = "build", type = "process", command = "make", quickfix_matcher = "gcc" },
                { "name", "type", "command", "quickfix_matcher" }),
        },
    },
}

return M
