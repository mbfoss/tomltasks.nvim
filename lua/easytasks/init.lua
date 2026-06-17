---@class easytasks
local M      = {}

local config = require("easytasks.config")

-- ─── Task constructors ────────────────────────────────────────────────────────
-- A `tasks.lua` file returns a map of name → task. Each task is built with a
-- typed constructor, which simply tags the spec with its `type` and returns it.
-- Built-ins are real (annotated) functions so lua-language-server can offer
-- per-type completion; the metatable below produces constructors for any other
-- registered task type on demand (`require("easytasks").mytype { … }`).

---@param spec easytasks.RunSpec
---@return easytasks.RunSpec
function M.run(spec)
    spec.type = "run"
    return spec
end

---@param spec easytasks.CompositeSpec
---@return easytasks.CompositeSpec
function M.composite(spec)
    spec.type = "composite"
    return spec
end

---@param spec easytasks.DebugSpec
---@return easytasks.DebugSpec
function M.debug(spec)
    spec.type = "debug"
    return spec
end

--- Generic constructor for a task of any registered `type` (escape hatch for
--- custom types that don't have a dedicated builder).
---@param type string
---@param spec table?
---@return table
function M.task(type, spec)
    spec      = spec or {}
    spec.type = type
    return spec
end

--- Macro-equivalent helpers (file paths, env, prompt, …) for use as task field
--- values. See `easytasks.expand` for the available helpers.
M.expand = require("easytasks.expand")

-- Module method names that must never be shadowed by a type constructor.
local _reserved = {
    setup = true, enable = true, disable = true, in_project = true,
    run = true, composite = true, debug = true, task = true, expand = true,
    register_task_type = true, register_qfmatcher = true, register_debug_backend = true,
}

setmetatable(M, {
    __index = function(_, key)
        if _reserved[key] or type(key) ~= "string" then return nil end
        -- Only registered task types get an auto-generated constructor, so a
        -- typo (`t.runn{…}`) raises a clear "nil value" error at load time.
        if not vim.tbl_contains(require("easytasks.types").get_names(), key) then
            return nil
        end
        return function(spec)
            spec      = spec or {}
            spec.type = key
            return spec
        end
    end,
})

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
