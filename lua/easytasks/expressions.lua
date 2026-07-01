---@class easytasks.ExpressionCtx
---@field task        table                decoded task data (pre-resolution)
---@field tasks       table<string,table>  all tasks in the file
---@field expressions table<string,string> named inline expression templates from the [expressions] table
---@field _resolving? table<string,true>   names of inline expressions currently on the resolution stack (cycle guard)
---@field _args?      {n:integer,[integer]:any}[]  stack of positional-argument frames; the top frame backs {{1}}, {{2}}, … inside an inline template

---@alias easytasks.ExpressionFn fun(ctx: easytasks.ExpressionCtx, ...): any, string?

local M            = {}

--- All expressions, built-in and user-registered, keyed by name. Private;
--- built-ins are defined below via `function _expressions.<name>`, and
--- `M.register` adds user ones. A single map keeps lookup (`M.get`) and
--- enumeration (`M.list`, used by LSP completion) trivial and complete.
---@type table<string, easytasks.ExpressionFn>
local _expressions = {}

--- Set of built-in names, snapshotted once all built-ins are defined. Used to
--- forbid overriding a built-in via `M.register`.
---@type table<string, boolean>
local _builtin     = {}

--- Names of *raw-body* expressions: instead of tokenized arguments they receive
--- everything after their name verbatim (quotes and separators intact, only
--- nested `{{ … }}` holes expanded) so a sublanguage keeps its own quoting.
--- `shell` and `lua` are raw; users may opt in via `M.register(name, fn, {raw=true})`.
---@type table<string, boolean>
local _raw         = { shell = true, lua = true }

--- One-line descriptions, keyed by name, surfaced in LSP completion. Built-in
--- descriptions are seeded below; `M.register` may add one via `opts.description`.
---@type table<string, string>
local _descriptions = {}

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

function _expressions.file(_, filetype)
    local err = _check_file(filetype)
    if err then return nil, err end
    return vim.fn.expand("%:p")
end

function _expressions.filename(_, filetype)
    local err = _check_file(filetype)
    if err then return nil, err end
    return vim.fn.expand("%:t")
end

function _expressions.fileroot(_, filetype)
    local err = _check_file(filetype)
    if err then return nil, err end
    return vim.fn.expand("%:p:r")
end

function _expressions.filedir(_)
    local err = _check_file()
    if err then return nil, err end
    return vim.fn.expand("%:p:h")
end

function _expressions.fileext(_)
    local err = _check_file()
    if err then return nil, err end
    local ext = vim.fn.expand("%:e")
    return (ext ~= "" and ext) or nil
end

---@param ctx easytasks.ExpressionCtx
function _expressions.cwd(ctx)
    return (ctx.task and ctx.task.cwd) or vim.fn.resolve(vim.fn.getcwd())
end

function _expressions.projectdir(_, resolve)
    local cwd = vim.fn.getcwd()
    local tasks_file = vim.fs.joinpath(cwd, require("easytasks.config").tasks_filename)
    if vim.fn.filereadable(tasks_file) == 0 then
        return nil, "tasks file not found in cwd: " .. cwd
    end
    return vim.fn.resolve(cwd)
end

---@param varname string
function _expressions.env(_, varname)
    if not varname then return nil, "env expression requires a variable name" end
    local val = vim.fn.getenv(varname)
    return (val ~= vim.NIL and val) or nil
end

--- Run a shell command and return its stdout with trailing newlines stripped
--- (like `$(...)` command substitution). A non-zero exit status is an error.
--- `shell` is a raw-body expression: the whole command reaches the shell
--- verbatim, so it keeps its own quoting: `{{ shell printf 'a, b' }}`.
---@param cmd string  the command
---@return string? output, string? err
function _expressions.shell(_, cmd)
    cmd = cmd or ""
    if cmd == "" then return nil, "shell expression requires a command" end
    local out = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then
        return nil, ("shell command failed (exit %d): %s"):format(vim.v.shell_error, vim.trim(out))
    end
    return (out:gsub("[\r\n]+$", ""))
end

--- Evaluate Lua code and return its result. The code is tried first as an
--- expression (`return <code>`) and, failing that, as a statement chunk, so
--- both `{{ lua 1 + 1 }}` and `{{ lua return os.time() }}` work. `lua` is a
--- raw-body expression: the source reaches the interpreter verbatim, keeping its
--- own quoting: `{{ lua math.max(1, 2) }}`, `{{ lua return 'hi' }}`. The result
--- must be a string, number, boolean, or nil.
---@param code string  Lua source
---@return any result, string? err
function _expressions.lua(_, code)
    code = code or ""
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
function _expressions.num(_, value)
    if value == nil or value == "" then return nil, "num expression requires a value" end
    local n = tonumber(value)
    if n == nil then return nil, "not a number: '" .. value .. "'" end
    return n
end

--- Cast a value to a boolean. Accepts true/false, 1/0, yes/no (case-insensitive).
---@param value string
function _expressions.bool(_, value)
    if value == nil then return nil, "bool expression requires a value" end
    local v = vim.trim(value):lower()
    if v == "true" or v == "1" or v == "yes" then return true end
    if v == "false" or v == "0" or v == "no" then return false end
    return nil, "not a boolean: '" .. value .. "'"
end

---@param prompt_text string
---@param default string?
---@param completion string?
function _expressions.prompt(_, prompt_text, default, completion)
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

_expressions["select-pid"] = function(_, prompt)
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

-- Everything defined above is a built-in; snapshot the name set so `M.register`
-- can forbid overriding one, and seed their completion descriptions.
for name in pairs(_expressions) do _builtin[name] = true end

_descriptions.file        = "Absolute path of the current file (optionally require a filetype)"
_descriptions.filename    = "Filename (with extension) of the current file"
_descriptions.fileroot    = "Absolute path of the current file without its extension"
_descriptions.filedir     = "Absolute directory of the current file"
_descriptions.fileext     = "Extension of the current file (without the dot)"
_descriptions.cwd         = "The task's working directory, or the editor cwd"
_descriptions.projectdir  = "Absolute path of the project root (where the tasks file lives)"
_descriptions.env         = "Value of an environment variable: env VARNAME"
_descriptions.shell       = "stdout of a shell command, trailing newlines stripped: shell CMD…"
_descriptions.lua         = "Result of evaluating Lua source: lua CODE…"
_descriptions.num         = "Cast a value to a number: num VALUE"
_descriptions.bool        = "Cast a value to a boolean: bool VALUE"
_descriptions.prompt      = "Ask for input at run time: prompt TEXT [default] [completion]"
_descriptions["select-pid"] = "Pick a running process and yield its PID"

-- ── Public API ──────────────────────────────────────────────────────────────

--- Look up an expression function by name (built-in or user-registered; both
--- live in the same map, and a user one can never shadow a built-in — see
--- `register`).
---@param name string
---@return easytasks.ExpressionFn?
function M.get(name)
    return _expressions[name]
end

--- Whether `name` is a raw-body expression (receives its body verbatim rather
--- than as tokenized arguments). See `_raw`.
---@param name string
---@return boolean
function M.is_raw(name)
    return _raw[name] == true
end

--- List every expression (built-in and user-registered) as `{ name, description }`
--- entries, sorted by name. Marshaled to the tasks-file LSP so completion can
--- offer expression names inside a `{{ … }}` hole. Inline `[expressions]` are not
--- included here (they live in the document, not this registry).
---@return { name: string, description: string? }[]
function M.list()
    local names = vim.tbl_keys(_expressions)
    table.sort(names)
    local out = {} ---@type { name: string, description: string? }[]
    for _, name in ipairs(names) do
        out[#out + 1] = { name = name, description = _descriptions[name] }
    end
    return out
end

--- Register a user expression for use in task config values. Built-in expressions cannot
--- be overridden; attempting to do so raises an error. `opts.raw` makes it a
--- raw-body expression (see `M.is_raw`); `opts.description` is shown in LSP
--- completion.
---@param name string
---@param fn   easytasks.ExpressionFn
---@param opts? { raw?: boolean, description?: string }
function M.register(name, fn, opts)
    if _builtin[name] then
        error("easytasks: cannot override built-in expression '" .. name .. "'", 2)
    end
    _expressions[name]  = fn
    _raw[name]          = opts and opts.raw or nil
    _descriptions[name] = opts and opts.description or nil
end

return M
