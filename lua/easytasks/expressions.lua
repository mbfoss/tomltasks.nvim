---@class easytasks.ExpressionCtx
---@field task        table                decoded task data (pre-resolution)
---@field tasks       table<string,table>  all tasks in the file
---@field expressions table<string,string> named inline expression templates from the [expressions] table
---@field _resolving? table<string,true>   names of inline expressions currently on the resolution stack (cycle guard)
---@field _args?      {n:integer,[integer]:any}[]  stack of positional-argument frames; the top frame backs ${1}, ${2}, … inside an inline template

---@alias easytasks.ExpressionFn fun(ctx: easytasks.ExpressionCtx, ...): any, string?

local M            = {}

--- Built-in expressions. Private: never exposed for mutation so they cannot be
--- overridden by user-registered expressions.
---@type table<string, easytasks.ExpressionFn>
local _builtins    = {}

--- User-registered expressions, keyed by name. Private; populated via `M.register`.
---@type table<string, easytasks.ExpressionFn>
local _registry    = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local _nofile_err  = "current buffer is not a regular file"
local _badtype_err = "current file type is not `%s`"

local function _is_file()
    local buf = vim.api.nvim_get_current_buf()
    return vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= ""
end

local function _check_file(filetype)
    if not _is_file() then return _nofile_err end
    if filetype and filetype ~= vim.bo.filetype then
        return _badtype_err:format(filetype)
    end
end

-- ── Built-in expressions ──────────────────────────────────────────────────

function _builtins.file(_, filetype)
    local err = _check_file(filetype)
    if err then return nil, err end
    return vim.fn.expand("%:p")
end

function _builtins.filename(_, filetype)
    local err = _check_file(filetype)
    if err then return nil, err end
    return vim.fn.expand("%:t")
end

function _builtins.fileroot(_, filetype)
    local err = _check_file(filetype)
    if err then return nil, err end
    return vim.fn.expand("%:p:r")
end

function _builtins.filedir(_)
    local err = _check_file()
    if err then return nil, err end
    return vim.fn.expand("%:p:h")
end

function _builtins.fileext(_)
    local err = _check_file()
    if err then return nil, err end
    local ext = vim.fn.expand("%:e")
    return (ext ~= "" and ext) or nil
end

---@param ctx easytasks.ExpressionCtx
function _builtins.cwd(ctx)
    return (ctx.task and ctx.task.cwd) or vim.fn.resolve(vim.fn.getcwd())
end

function _builtins.projectdir(_, resolve)
    local cwd = vim.fn.getcwd()
    local tasks_file = vim.fs.joinpath(cwd, require("easytasks.config").tasks_filename)
    if vim.fn.filereadable(tasks_file) == 0 then
        return nil, "tasks file not found in cwd: " .. cwd
    end
    return vim.fn.resolve(cwd)
end

---@param varname string
function _builtins.env(_, varname)
    if not varname then return nil, "env expression requires a variable name" end
    local val = vim.fn.getenv(varname)
    return (val ~= vim.NIL and val) or nil
end

--- Run a shell command and return its stdout with trailing newlines stripped
--- (like `$(...)` command substitution). A non-zero exit status is an error.
--- The argument list is re-joined on `,`, so a command may contain commas
--- without quoting: `${shell:printf a, b}` runs `printf a, b`.
---@param ... string  command words
---@return string? output, string? err
function _builtins.shell(_, ...)
    local cmd = table.concat({ ... }, ",")
    if cmd == "" then return nil, "shell expression requires a command" end
    local out = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then
        return nil, ("shell command failed (exit %d): %s"):format(vim.v.shell_error, vim.trim(out))
    end
    return (out:gsub("[\r\n]+$", ""))
end

--- Evaluate Lua code and return its result. The code is tried first as an
--- expression (`return <code>`) and, failing that, as a statement chunk, so
--- both `${lua:1 + 1}` and `${lua:return os.time()}` work. The argument list is
--- re-joined on `,`, so calls with multiple arguments need no quoting:
--- `${lua:math.max(1, 2)}`. The result must be a string, number, boolean, or nil.
---@param ... string  Lua source fragments
---@return any result, string? err
function _builtins.lua(_, ...)
    local code = table.concat({ ... }, ",")
    if code == "" then return nil, "lua expression requires code" end
    local chunk, load_err = load("return " .. code, "=[easytasks lua expression]", "t")
    if not chunk then
        chunk, load_err = load(code, "=[easytasks lua expression]", "t")
    end
    if not chunk then return nil, "lua parse error: " .. tostring(load_err) end
    local ok, result = pcall(chunk)
    if not ok then return nil, "lua error: " .. tostring(result) end
    return result
end

--- Cast a value to a number. Use as a sole expression so the number survives expression
--- resolution (e.g. `port = "${num:${prompt:Port}}"`); inside a larger string
--- it is stringified like any other expression result.
---@param value string
function _builtins.num(_, value)
    if value == nil or value == "" then return nil, "num expression requires a value" end
    local n = tonumber(value)
    if n == nil then return nil, "not a number: '" .. value .. "'" end
    return n
end

--- Cast a value to a boolean. Accepts true/false, 1/0, yes/no (case-insensitive).
---@param value string
function _builtins.bool(_, value)
    if value == nil then return nil, "bool expression requires a value" end
    local v = vim.trim(value):lower()
    if v == "true" or v == "1" or v == "yes" then return true end
    if v == "false" or v == "0" or v == "no" then return false end
    return nil, "not a boolean: '" .. value .. "'"
end

---@param prompt_text string
---@param default string?
---@param completion string?
function _builtins.prompt(_, prompt_text, default, completion)
    if not prompt_text then return nil, "prompt expression requires prompt text" end
    local co = coroutine.running()
    vim.schedule(function()
        vim.cmd("redraw!")
        vim.ui.input({ prompt = prompt_text .. ": ", default = default, completion = completion },
            function(input) coroutine.resume(co, input) end)
    end)
    local result = coroutine.yield()
    if result == nil then return nil, "Prompt cancelled" end
    if completion == "file" or completion == "dir" then
        if vim.fn.isabsolutepath(result) == 0 then
            return vim.fn.resolve(vim.fs.joinpath(vim.fn.getcwd(), result))
        end
    end
    return result
end

_builtins["select-pid"] = function(_, prompt)
    local lines = vim.fn.systemlist("ps -eo pid,user,comm 2>/dev/null")
    if not lines or #lines == 0 then
        return nil, "No processes found"
    end

    ---@type {label:string, pid:string}[]
    local choices = {}
    for i, line in ipairs(lines) do
        if i > 1 then -- skip header
            local pid, user, name = line:match("^%s*(%d+)%s+(%S+)%s+(.-)%s*$")
            if pid then
                choices[#choices + 1] = {
                    label = ("%8s | %s - %s"):format(pid, user, name),
                    pid   = pid,
                }
            end
        end
    end
    if #choices == 0 then return nil, "No processes found" end

    local co = coroutine.running()
    vim.schedule(function()
        local labels = vim.tbl_map(function(c) return c.label end, choices)
        vim.ui.select(labels, { prompt = type(prompt) == "string" and prompt or  "Select process" }, function(selected)
            if not selected then
                coroutine.resume(co, nil)
                return
            end
            for _, c in ipairs(choices) do
                if c.label == selected then
                    coroutine.resume(co, c.pid)
                    return
                end
            end
            coroutine.resume(co, nil)
        end)
    end)

    local pid = coroutine.yield()
    if not pid then return nil, "Process selection cancelled" end
    return tonumber(pid)
end

-- ── Public API ──────────────────────────────────────────────────────────────

--- Look up a expression function by name. Built-in expressions take precedence over
--- user-registered ones (the latter can never shadow a built-in; see `register`).
---@param name string
---@return easytasks.ExpressionFn?
function M.get(name)
    return _builtins[name] or _registry[name]
end

--- Register a user expression for use in task config values. Built-in expressions cannot
--- be overridden; attempting to do so raises an error.
---@param name string
---@param fn   easytasks.ExpressionFn
function M.register(name, fn)
    if _builtins[name] then
        error("easytasks: cannot override built-in expression '" .. name .. "'", 2)
    end
    _registry[name] = fn
end

return M
