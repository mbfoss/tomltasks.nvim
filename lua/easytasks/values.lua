--- Convenience helpers for dynamic task field values, ported from the old
--- `${…}` macro set. Each helper is a *builder*: it takes its (optional)
--- arguments and returns a `fun(ctx: easytasks.ValueCtx): any, string?` suitable
--- for use directly as a task field value. The returned function is evaluated
--- lazily at run time by the resolver.
---
--- Example:
---     local types = require("easytasks.types")
---     local v     = require("easytasks").values
---     return {
---       open   = types.run { command = { "nvim", v.file() } },
---       deploy = types.run { command = v.prompt("Deploy target") },
---     }
---
---@class easytasks.values
local M            = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local _nofile_err  = "current buffer is not a regular file"
local _badtype_err = "current file type is not `%s`"

local function _is_file()
    local buf = vim.api.nvim_get_current_buf()
    return vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= ""
end

---@param filetype string?
---@return string? err
local function _check_file(filetype)
    if not _is_file() then return _nofile_err end
    if filetype and filetype ~= vim.bo.filetype then
        return _badtype_err:format(filetype)
    end
end

-- ── File path helpers ─────────────────────────────────────────────────────────

--- Absolute path of the current buffer (`%:p`).
---@param filetype string?  if given, error unless the current file has this filetype
---@return fun(): string?, string?
function M.file(filetype)
    return function()
        local err = _check_file(filetype)
        if err then return nil, err end
        return vim.fn.expand("%:p")
    end
end

--- Tail of the current buffer's name (`%:t`).
---@param filetype string?
---@return fun(): string?, string?
function M.filename(filetype)
    return function()
        local err = _check_file(filetype)
        if err then return nil, err end
        return vim.fn.expand("%:t")
    end
end

--- Current buffer path without extension (`%:p:r`).
---@param filetype string?
---@return fun(): string?, string?
function M.fileroot(filetype)
    return function()
        local err = _check_file(filetype)
        if err then return nil, err end
        return vim.fn.expand("%:p:r")
    end
end

--- Directory of the current buffer (`%:p:h`).
---@return fun(): string?, string?
function M.filedir()
    return function()
        local err = _check_file()
        if err then return nil, err end
        return vim.fn.expand("%:p:h")
    end
end

--- Extension of the current buffer (`%:e`), or nil if none.
---@return fun(): string?, string?
function M.fileext()
    return function()
        local err = _check_file()
        if err then return nil, err end
        local ext = vim.fn.expand("%:e")
        return (ext ~= "" and ext) or nil
    end
end

--- The task's own `cwd` if it set one, else the resolved current working dir.
---@return fun(ctx: easytasks.ValueCtx): string
function M.cwd()
    return function(ctx)
        local c = ctx.task and ctx.task.cwd
        if type(c) == "string" then return c end
        return vim.fn.resolve(vim.fn.getcwd())
    end
end

--- The project root (the cwd, asserting the tasks file lives there).
---@return fun(): string?, string?
function M.projectdir()
    return function()
        local cwd        = vim.fn.getcwd()
        local tasks_file = vim.fs.joinpath(cwd, require("easytasks.config").tasks_filename)
        if vim.fn.filereadable(tasks_file) == 0 then
            return nil, "tasks file not found in cwd: " .. cwd
        end
        return vim.fn.resolve(cwd)
    end
end

-- ── Environment / interactive helpers ─────────────────────────────────────────

--- Value of environment variable `varname`, or nil if unset.
---@param varname string
---@return fun(): string?, string?
function M.env(varname)
    return function()
        if not varname then return nil, "env requires a variable name" end
        local val = vim.fn.getenv(varname)
        return (val ~= vim.NIL and val) or nil
    end
end

--- Prompt the user for a value via `vim.ui.input`.
---@param prompt_text string
---@param default string?
---@param completion string?  e.g. "file" or "dir" (resolves relative paths)
---@return fun(): string?, string?
function M.prompt(prompt_text, default, completion)
    return function()
        if not prompt_text then return nil, "prompt requires prompt text" end
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
end

--- Let the user pick a running process; resolves to its PID.
---@return fun(): string?, string?
function M.select_pid()
    return function()
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
end

return M
