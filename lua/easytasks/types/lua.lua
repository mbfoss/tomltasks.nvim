local ordered = require("easytasks.util.table_util").ordered
local notify  = require("easytasks.ui")

-- Names exposed to a lua task: Lua's own standard library plus Neovim's `vim`
-- table. Globals added by plugins/extensions are intentionally excluded, as are
-- the escape hatches (`load`, `loadstring`, `require`, `dofile`, `loadfile`,
-- `getfenv`, `setfenv`, `debug`, `package`, `ffi`, `jit`, `_G`) that could be
-- used to climb back into the real global environment.
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

-- A `lua` task runs a chunk of Lua code supplied directly in the tasks file.
-- The chunk receives the run context as its sole vararg (`local ctx = ...`) and
-- runs in a restricted environment: only Lua's standard library, `vim`, and the
-- predefined `report`, `print`, `task`, are visible (see _ALLOWED).
-- The chunk succeeds unless it raises an error or explicitly returns `false`.
---@type easytasks.TaskTypeDef
local M = {
    ---@return fun()
    start = function(task, ctx, on_done)
        local code = task.code
        if type(code) == "table" then
            code = table.concat(code, "\n")
        end
        if type(code) ~= "string" or code == "" then
            notify.notify_error("lua task '" .. task.name .. "' has no code")
            on_done(false)
            return function() end
        end

        local chunk, compile_err = load(code, "=lua task '" .. task.name .. "'")
        if not chunk then
            ctx.report("compile error: " .. tostring(compile_err))
            on_done(false)
            return function() end
        end

        -- Restricted environment: only the allow-listed builtins plus the
        -- task-specific helpers. No `__index` fallthrough, so plugin-injected
        -- globals are invisible and there is no path back to the real `_G`.
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

        -- LuaJIT (Neovim's runtime) has no env parameter on load(); use setfenv.
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
        ["x-order"] = { "name", "type", "if_running", "depends_on", "depends_order", "save_buffers", "code" },
        required    = { "code" },
        properties  = {
            code = {
                description =
                "Lua code to execute in a restricted environment: Lua's standard library and `vim` are available, but plugin/extension globals and the `load`/`require`/`debug` escape hatches are not. The chunk receives the run context as its sole vararg (`local ctx = ...`); `report`, `print`, `task`, are predefined. The task fails if the chunk errors or returns `false`.",
                oneOf       = {
                    { type = "string", minLength = 1, description = "Lua source code" },
                    {
                        type        = "array",
                        minItems    = 1,
                        description = "Lua source as an array of lines, joined with newlines",
                        items       = { type = "string", description = "A line of Lua source" },
                    },
                },
            },
        },
    },

    templates = {
        {
            label = "Lua code",
            task  = ordered({ name = "lua", type = "lua", code = "" },
                { "name", "type", "code" }),
        },
    },
}

return M
