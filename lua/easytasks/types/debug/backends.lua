---@class easytasks.debug.Backend
---@field run fun(params: easytasks.debug.Params, ctx: easytasks.RunCtx, on_done: fun(ok: boolean)): fun()
---@field adapters? fun(): string[]
---@field templates? table[]

--- A backend may be supplied as a static table or a zero-arg factory that
--- returns one (returning nil signals the backend is unavailable).
---@alias easytasks.debug.BackendDef
---  | easytasks.debug.Backend
---  | fun(): easytasks.debug.Backend?

local M = {}

---@type table<string, easytasks.debug.BackendDef>
local _defs = {}

---@type table<string, easytasks.debug.Backend|false>  -- false = resolved but unavailable
local _resolved = {}

--- Register a debug backend by name.
---@param name string
---@param def  easytasks.debug.BackendDef
function M.register(name, def)
    _defs[name]     = def
    _resolved[name] = nil
end

--- Resolve the named backend (cached after first call). Returns nil if unavailable.
---@param name string
---@return easytasks.debug.Backend?
function M.get(name)
    local cached = _resolved[name]
    if cached ~= nil then return cached or nil end
    local def = _defs[name]
    if def == nil then return nil end
    local result = type(def) == "function" and def() --[[@as easytasks.debug.Backend]] or def
    _resolved[name] = result or false
    return result
end

-- ── Built-in backends ──────────────────────────────────────────────────────

M.register("easydap",  require("easytasks.types.debug.backends.easydap"))
M.register("nvim-dap", require("easytasks.types.debug.backends.nvim_dap"))

return M
