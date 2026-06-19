local ordered = require("easytasks.util.table_util").ordered
local notify  = require("easytasks.ui")
local project = require("easytasks.project")

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
local _ALLOWED = {
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

-- A `lua` task runs a Lua script file referenced from the tasks file. The
-- chunk receives the run context as its sole vararg (`local ctx = ...`) and runs
-- in a restricted environment: only Lua's standard library, `vim`, and the
-- predefined `report`, `print`, `task`, are visible (see _ALLOWED).
-- The chunk succeeds unless it raises an error or explicitly returns `false`.
---@type easytasks.TaskTypeDef
local M = {
    ---@return fun()
    start = function(task, ctx, on_done)
        local file = task.file
        if type(file) ~= "string" or file == "" then
            notify.notify_error("lua task '" .. task.name .. "' has no file")
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

        -- Curated environment: only the allow-listed builtins plus the
        -- task-specific helpers. No `__index` fallthrough, so plugin-injected
        -- globals are invisible and a bare `x = 1` lands here instead of `_G`.
        -- This is convenience, not confinement -- see the _ALLOWED note above:
        -- `vim`/`os`/`io` still reach the real globals and the system.
        local env = {
            report = ctx.report,
            task   = vim.deepcopy(task or {}),
            print  = function(...)
                local parts = {}
                for i = 1, select("#", ...) do
                    parts[i] = tostring((select(i, ...)))
                end
                ctx.report(table.concat(parts, "\t"))
            end,
        }
        for _, name in ipairs(_ALLOWED) do
            if env[name] == nil then env[name] = _G[name] end
        end

        -- LuaJIT (Neovim's runtime) has no env parameter on load(); use setfenv
        -- to point the chunk's free variables at `env`. This redirects accidental
        -- global writes away from `_G` -- it does not sandbox a determined task.
        if setfenv then setfenv(chunk, env) end

        local ok, result = pcall(chunk, ctx)
        if not ok then
            ctx.report("error: " .. tostring(result))
            on_done(false)
            return function() end
        end

        -- A chunk may explicitly `return false` to signal failure.
        on_done(result ~= false)
        return function() end
    end,

    schema = {
        description = "Definition of a `lua` task",
        ["x-order"] = { "name", "type", "if_running", "depends_on", "depends_order", "save_buffers", "file" },
        required    = { "file" },
        properties  = {
            file = {
                type        = "string",
                minLength   = 1,
                description =
                "Path to a Lua script file to execute in a restricted environment: Lua's standard library and `vim` are available, but plugin/extension globals and the `load`/`require`/`debug` escape hatches are not. Relative paths are resolved against the project root (the directory containing the tasks file). The chunk receives the run context as its sole vararg (`local ctx = ...`); `report`, `print`, `task`, are predefined. The task fails if the chunk errors or returns `false`.",
            },
        },
    },

    templates = {
        {
            label = "Lua script",
            task  = ordered({ name = "lua", type = "lua", file = "" },
                { "name", "type", "file" }),
        },
    },
}

return M
