---@class easytasks
local M      = {}

local config = require("easytasks.config")

-- ─── Authoring API ────────────────────────────────────────────────────────────
-- A `tasks.lua` file returns a map of name → task. Each task is built with a
-- typed constructor from the `easytasks.types` submodule, re-exported here for
-- convenience: `require("easytasks.types").run { … }` or `et.types.run { … }`.
M.types = require("easytasks.types")

--- Helpers (file paths, env, prompt, …) for dynamic task field values; each
--- returns a `fun(ctx)` evaluated lazily at run time (replaces the old `${…}`
--- macros). See `easytasks.values`.
M.values = require("easytasks.values")

-- ─── Registration / extension points ──────────────────────────────────────────

--- Register a task type. Can be called at any time before setup() to have the
--- type included, or after setup() for runtime-only use.
--- `loader` may be a module path string, a zero-arg factory function, or a
--- fully-resolved TaskTypeDef table.
---@param name   string
---@param loader easytasks.TypeLoader
function M.register_task_type(name, loader)
    require("easytasks.types").register(name, loader)
end

--- Register a custom quickfix matcher for use in run tasks.
---@param name string
---@param fn   easytasks.QfMatcher
function M.register_qfmatcher(name, fn)
    require("easytasks.types.run").register_qfmatcher(name, fn)
end

--- Register a debug backend definition under `name`, for use by `debug` tasks
--- (selected via `config.debug_backend`). Overrides any existing backend with
--- the same name.
---@param name string
---@param def  easytasks.debug.BackendDef
function M.register_debug_backend(name, def)
    require("easytasks.types.debug").register_backend(name, def)
end

-- ─── Lifecycle ────────────────────────────────────────────────────────────────

local _enabled = false

function M.enable()
    if _enabled then return end
    _enabled = true
    require("easytasks.commands").register(config.command)
end

function M.disable()
    if not _enabled then return end
    _enabled = false
    pcall(vim.api.nvim_del_user_command, config.command)
end

---@param opts easytasks.Config?
function M.setup(opts)
    local tmp = vim.tbl_deep_extend("force", config or {}, opts or {})
    for k, v in pairs(tmp) do
        config[k] = v
    end
    if config.enabled then
        M.enable()
    else
        M.disable()
    end
end

---@return boolean
function M.in_project()
    return require("easytasks.project").find_root() ~= nil
end

return M
