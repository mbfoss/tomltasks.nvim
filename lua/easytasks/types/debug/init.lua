local config = require("easytasks.config")

---@class easytasks.debug.Module : easytasks.TaskTypeDef
local M = {}

---@class easytasks.debug.Backend
---@field run fun(params: easytasks.debug.Params, ctx: easytasks.RunCtx, on_done: fun(ok: boolean)): fun()
---@field adapters? fun(): string[]
---@field templates? easytasks.TaskTemplate[]

--- A backend may be supplied as a static table or a zero-arg factory that
--- returns one (returning nil signals the backend is unavailable).
---@alias easytasks.debug.BackendDef
---  | easytasks.debug.Backend
---  | fun(): easytasks.debug.Backend?

--- Registry of debug backend definitions, keyed by name.
---@type table<string, easytasks.debug.BackendDef>
local _backends = {
    ["easydap"]  = require("easytasks.types.debug.backends.easydap"),
    ["nvim-dap"] = require("easytasks.types.debug.backends.nvim_dap"),
}

---@type table<string, easytasks.debug.Backend|false>  -- false = resolved but unavailable
local _resolved = {}

--- Register a debug backend definition under `name`. Overrides any existing
--- backend with the same name and clears its cached resolution.
---@param name string
---@param def easytasks.debug.BackendDef
function M.register_backend(name, def)
    _backends[name] = def
    _resolved[name] = nil
end

--- Resolve a backend definition by name, invoking a factory at most once and
--- caching the result. Returns nil if the backend is unknown or unavailable.
---@param name string
---@return easytasks.debug.Backend?
local function _resolve(name)
    local cached = _resolved[name]
    if cached ~= nil then return cached or nil end
    local def = _backends[name]
    if def == nil then return nil end
    ---@type easytasks.debug.Backend?
    local result
    if type(def) == "function" then
        result = def() --[[@as easytasks.debug.Backend?]]
    else
        result = def
    end
    _resolved[name] = result or false
    return result or nil
end

--- Resolve the backend named by `config.debug_backend`. Returns nil if none is
--- configured or the configured backend is unavailable. Errors if the name is
--- set but not a registered backend.
---@return easytasks.debug.Backend?
local function _current()
    local name = config.debug_backend
    if not name then return nil end
    if _backends[name] == nil then
        error(("easytasks: invalid debug_backend %q (not a registered backend)"):format(name))
    end
    return _resolve(name)
end

---Debug-relevant fields extracted from a task before dispatch to a backend.
---Backends receive this instead of the raw task so they remain independent of
---the easytasks task schema (which also carries framework fields like `type`,
---`depends_on`, `if_running`, etc.).
---@class easytasks.debug.Params
---@field name            string
---@field adapter         string
---@field request         "launch"|"attach"|nil
---@field host            string|nil
---@field port            integer|nil
---@field command         string|string[]|nil
---@field cwd             string|nil
---@field env             table<string,string>|nil
---@field clear_env       boolean|nil
---@field run_in_terminal boolean|nil
---@field stop_on_entry   boolean|nil
---@field request_args    table|nil
---@field raw_messages    boolean|nil

---@param task table
---@return easytasks.debug.Params
local function _build_params(task)
    return {
        name            = task.name,
        adapter         = task.adapter,
        request         = task.request,
        host            = task.host,
        port            = task.port,
        command         = task.command,
        cwd             = task.cwd,
        env             = task.env,
        clear_env       = task.clear_env,
        run_in_terminal = task.run_in_terminal,
        stop_on_entry   = task.stop_on_entry,
        request_args    = task.request_args,
        raw_messages    = task.raw_messages,
    }
end

---@param task    table
---@param ctx     easytasks.RunCtx
---@param on_done fun(ok: boolean)
---@return fun()
function M.start(task, ctx, on_done)
    local backend_name = config.debug_backend
    if not backend_name then
        ctx.report("Debug backend name missing from configuration")
        on_done(false)
        return function() end
    end
    local backend = _resolve(backend_name)
    if not backend then
        ctx.report("Invalid debug backend in configuration: " .. tostring(backend_name) .. "")
        on_done(false)
        return function() end
    end
    return backend.run(_build_params(task), ctx, on_done)
end

--- Validate a `debug` task: it needs a backend and an adapter name.
---@param task table
---@return boolean ok, string? err
M.validate = function(task)
    local b = _current()
    if not b then
        return false, "no debug backend available (config.debug_backend = "
            .. tostring(config.debug_backend) .. ")"
    end
    if type(task.adapter) ~= "string" or task.adapter == "" then
        return false, "debug task '" .. tostring(task.name) .. "' has no `adapter`"
    end
    return true
end

---@return table[]
M.templates = function()
    local b = _current()
    return b and b.templates or {}
end

return M
