---@class easytasks.MacroCtx
---@field task      table                decoded task data (pre-resolution)
---@field tasks     table<string,table>  all tasks in the file
---@field variables table<string,string> project-level variables from the [variables] table

---@alias easytasks.MacroFn fun(ctx: easytasks.MacroCtx, ...): any, string?

local M            = {}

--- Built-in macros. Private: never exposed for mutation so they cannot be
--- overridden by user-registered macros.
---@type table<string, easytasks.MacroFn>
local _builtins    = {}

--- User-registered macros, keyed by name. Private; populated via `M.register`.
---@type table<string, easytasks.MacroFn>
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

-- ── Built-in macros ───────────────────────────────────────────────────────────

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

---@param ctx easytasks.MacroCtx
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
    if not varname then return nil, "env macro requires a variable name" end
    local val = vim.fn.getenv(varname)
    return (val ~= vim.NIL and val) or nil
end

---@param ctx     easytasks.MacroCtx
---@param name    string
---@param default string?
function _builtins.var(ctx, name, default)
    if not name or name == "" then return nil, "var macro requires a variable name" end
    local val = (ctx.variables or {})[name]
    if val == nil then
        if default ~= nil then return default end
        return nil, "undefined variable: '" .. name .. "'"
    end
    return val
end

---@param prompt_text string
---@param default string?
---@param completion string?
function _builtins.prompt(_, prompt_text, default, completion)
    if not prompt_text then return nil, "prompt macro requires prompt text" end
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

_builtins["select-pid"] = function(_)
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
        vim.ui.select(labels, { prompt = "Select process to attach" }, function(selected)
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
    return pid
end

-- ── Public API ──────────────────────────────────────────────────────────────

--- Look up a macro function by name. Built-in macros take precedence over
--- user-registered ones (the latter can never shadow a built-in; see `register`).
---@param name string
---@return easytasks.MacroFn?
function M.get(name)
    return _builtins[name] or _registry[name]
end

--- Register a user macro for use in task config values. Built-in macros cannot
--- be overridden; attempting to do so raises an error.
---@param name string
---@param fn   easytasks.MacroFn
function M.register(name, fn)
    if _builtins[name] then
        error("easytasks: cannot override built-in macro '" .. name .. "'", 2)
    end
    _registry[name] = fn
end

return M
