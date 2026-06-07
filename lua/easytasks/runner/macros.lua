---@class easytasks.MacroCtx
---@field task  table               decoded task data (pre-resolution)
---@field tasks table<string,table> all tasks in the file

---@class easytasks.runner.macros
local M = {}

local _user = {}

---@param name string
---@param fn   fun(ctx: easytasks.MacroCtx, ...): any, string?
function M.register(name, fn) _user[name] = fn end

---@param name string
---@return (fun(ctx: easytasks.MacroCtx, ...): any, string?)?
function M.get(name) return _user[name] or M[name] end

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

function M.file(ctx, filetype)
    local err = _check_file(filetype)
    if err then return nil, err end
    return vim.fn.expand("%:p")
end

function M.filename(ctx, filetype)
    local err = _check_file(filetype)
    if err then return nil, err end
    return vim.fn.expand("%:t")
end

function M.fileroot(ctx, filetype)
    local err = _check_file(filetype)
    if err then return nil, err end
    return vim.fn.expand("%:p:r")
end

function M.filedir(ctx)
    local err = _check_file()
    if err then return nil, err end
    return vim.fn.expand("%:p:h")
end

function M.fileext(ctx)
    local err = _check_file()
    if err then return nil, err end
    local ext = vim.fn.expand("%:e")
    return (ext ~= "" and ext) or nil
end

---@param ctx easytasks.MacroCtx
function M.cwd(ctx)
    return (ctx.task and ctx.task.cwd) or vim.fn.getcwd()
end

---@param ctx easytasks.MacroCtx
---@param varname string
function M.env(ctx, varname)
    if not varname then return nil, "env macro requires a variable name" end
    local val = vim.fn.getenv(varname)
    return (val ~= vim.NIL and val) or nil
end

---@param ctx easytasks.MacroCtx
---@param prompt_text string
---@param default string?
---@param completion string?
function M.prompt(ctx, prompt_text, default, completion)
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
            return vim.fs.joinpath(vim.fn.getcwd(), result)
        end
    end
    return result
end

M["select-pid"] = function(ctx)
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

return M
