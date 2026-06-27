local ordered = require("easytasks.util.table_util").ordered
local notify  = require("easytasks.ui")
local project = require("easytasks.project")

-- Names exposed to a lua task: Lua's own standard library plus Neovim's `vim`
-- table. Globals added by plugins/extensions are not exposed, and the obvious
-- escape hatches (`load`, `loadstring`, `require`, `dofile`, `loadfile`,
-- `getfenv`, `setfenv`, `debug`, `package`, `ffi`, `jit`, `_G`) are left out.
--
-- This is NOT a security sandbox. The exposed stdlib tables (`string`, `os`,
-- `io`, `vim`, ...) are the real shared instances, so a task can mutate them
-- process-wide, and `vim` alone is a full escape hatch -- `vim.cmd("lua ...")`,
-- `vim.fn`, `vim.uv`, `os.execute`, etc. all reach the real global environment
-- and the system. The allow-list only keeps honest tasks from *accidentally*
-- leaking globals; treat task code as trusted (same as a Makefile or
-- `.nvim.lua`), not as a confined guest.
local ALLOWED = {
    -- base library
    "assert", "collectgarbage", "error", "ipairs", "next", "pairs",
    "pcall", "xpcall", "select", "tonumber", "tostring", "type", "unpack",
    "rawequal", "rawget", "rawset", "rawlen", "getmetatable", "setmetatable",
    "_VERSION",
    -- standard library tables
    "string", "table", "math", "coroutine", "os", "io", "bit", "utf8",
    -- neovim
    "vim",
}

--- Build the curated environment table for a chunk: the allow-listed builtins,
--- a `print` that routes to `ctx.report`, plus a single `context` global that
--- exposes the run context (`report`, `add_bufnr`, ...) and the task definition
--- (`context.task`).
---@param ctx  table run context (must provide `report`)
---@param task easytasks.LuaFileTask task definition
---@return table
local function _build_env(ctx, task)
    local env = {
        print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do
                parts[i] = tostring((select(i, ...)))
            end
            ctx.report(table.concat(parts, "\t"))
        end,
    }
    for _, name in ipairs(ALLOWED) do
        if env[name] == nil then env[name] = _G[name] end
    end
    return env
end

--- Run a compiled chunk in the restricted environment built from `task`/`ctx`,
--- then report the outcome via `on_done`. The chunk succeeds unless it raises
--- an error or explicitly returns `false`.
---@param chunk function
---@param ctx table
---@param task easytasks.LuaFileTask
---@param on_done fun(ok: boolean)
local function _run_chunk(chunk, ctx, task, on_done)
    -- LuaJIT (Neovim's runtime) has no env parameter on load(); use setfenv
    -- to point the chunk's free variables at `env`. This redirects accidental
    -- global writes away from `_G` -- it does not sandbox a determined task.
    if setfenv then setfenv(chunk, _build_env(ctx, task)) end

    local ok, result = pcall(chunk)
    if not ok then
        ctx.report("error: " .. tostring(result))
        on_done(false)
        return
    end

    -- A chunk may explicitly `return false` to signal failure.
    on_done(result ~= false)
end

--- Resolve a (possibly relative) task file path against the project root.
---@param path string
---@return string
local function _resolve(path)
    path = vim.fs.normalize(path)
    if vim.fn.fnamemodify(path, ":p") == path then
        return path -- already absolute
    end
    local root = project.find_root()
    return root and vim.fs.normalize(vim.fs.joinpath(root, path)) or path
end

-- A `lua_file` task runs a Lua script file referenced from the tasks file.
-- The chunk runs in a restricted environment: only Lua's standard library,
-- `vim`, a `print` that routes to the panel, and a single `context` global
-- (exposing `report`, `context.task`, ...) are visible (see ALLOWED). The chunk
-- succeeds unless it raises an error or explicitly returns `false`.
---@class easytasks.LuaFileTask : easytasks.TaskBase
---@field file? string  path to a Lua script file to execute in a restricted environment

---@type easytasks.TaskTypeDef
local M = {
    ---@type easytasks.RunFn
    start = function(task, ctx, on_done)
        ---@cast task easytasks.LuaFileTask
        local file = task.file
        if type(file) ~= "string" or file == "" then
            notify.notify_error("lua_file task '" .. task.name .. "' has no file")
            on_done(false)
            return function() end
        end

        local path = _resolve(file)
        -- loadfile reads, compiles, and reports a missing/unreadable file in one
        -- step; the chunk name defaults to the path for readable error messages.
        local chunk, compile_err = loadfile(path)
        if not chunk then
            ctx.report("cannot load lua file: " .. tostring(compile_err))
            on_done(false)
            return function() end
        end

        _run_chunk(chunk, ctx, task, on_done)
        return function() end
    end,

    schema = {
        description = "Definition of a `lua_file` task",
        ["x-order"] = { "type", "if_running", "depends_on", "depends_order", "save_buffers", "file" },
        required    = { "file" },
        properties  = {
            file = {
                type        = "string",
                minLength   = 1,
                description =
                [[Path to a Lua script file to execute in a restricted environment.
Lua's standard library and `vim` are available, but plugin/extension globals are not.
`print` routes to the task panel.
The task fails if the chunk errors or returns `false`.]]
            },
        },
    },

    templates = {
        {
            label = "Lua script file",
            task  = ordered({ name = "lua_file", type = "lua_file", file = "" },
                { "name", "type", "file" }),
        },
    },
}

return M
