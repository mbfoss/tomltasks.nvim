local str_util = require("easytasks.util.str_util")

---@class easytasks.debug.Module : easytasks.TaskTypeDef
local M = {}

--- Map one easydap `ParamSpec` to a JSON Schema fragment for the tasks-file LSP.
--- `kind` (the spec's semantic refinement) drives the shape; `type` is the
--- fallback for plain params.
---@param spec table  an `easydap.ParamSpec`
---@return table
local function _param_schema(spec)
    local out = { description = spec.desc }
    local kind = spec.kind
    if kind == "argv" then
        out.type  = "array"
        out.items = { type = "string" }
    elseif kind == "env" then
        out.type                 = "object"
        out.additionalProperties = { type = "string" }
    elseif kind == "port" then
        out.type    = "integer"
        out.minimum = 0
        out.maximum = 65535
    elseif kind == "enum" then
        out.type = spec.type or "string"
        out.enum = spec.enum
    else
        out.type = spec.type or "string"
    end
    if spec.default ~= nil and type(spec.default) ~= "function" then
        out.default = spec.default
    end
    return out
end

--- Per-(adapter, request) conditional branches constraining `parameters` to the
--- adapter's own native launch/attach keys. Evaluated by the schema navigator
--- against the task data, so completion inside `parameters` is adapter-aware.
---@param sch table  the `easydap.schema` module
---@return table[]
local function _parameter_branches(sch)
    local branches = {}
    for _, adapter in ipairs(sch.adapter_names()) do
        for _, request in ipairs(sch.requests(adapter)) do
            local props, required = {}, {}
            for _, key in ipairs(sch.param_names(adapter, request)) do
                local spec = sch.spec(adapter, request, key)
                if spec then
                    props[key] = _param_schema(spec)
                    if spec.required then required[#required + 1] = key end
                end
            end
            branches[#branches + 1] = {
                ["if"] = {
                    type       = "object",
                    required   = { "adapter", "request" },
                    properties = {
                        adapter = { const = adapter },
                        request = { const = request },
                    },
                },
                ["then"] = {
                    properties = {
                        parameters = {
                            type                 = "object",
                            additionalProperties = true,
                            properties           = props,
                            required             = (#required > 0) and required or nil,
                        },
                    },
                },
            }
        end
    end
    return branches
end

--- The `debug` task schema. easytasks owns only the framework fields; the DAP
--- vocabulary lives entirely under `parameters` (the adapter's native launch/
--- attach body) and is projected from easydap's per-adapter schemas.
---@return table
local function _schema()
    local sch          = require("easydap.schema")
    local all_adapters = vim.tbl_keys(require("easydap.adapters"))
    table.sort(all_adapters)

    return {
        description = "Definition of a `debug` task (runs via a DAP adapter)",
        ["x-order"] = {
            "name", "type", "if_running", "depends_on", "depends_order", "save_buffers",
            "adapter", "request", "target", "host", "port", "parameters", "raw_messages",
        },
        required    = { "adapter" },
        properties  = {
            adapter      = {
                type        = "string",
                minLength   = 1,
                description = "Name of the DAP adapter to use (e.g. codelldb, delve, debugpy)",
                enum        = all_adapters,
            },
            request      = {
                type                   = { "string", "null" },
                enum                   = { "launch", "attach" },
                ["x-enumDescriptions"] = { "Start the program under the debugger", "Attach to an already-running process" },
            },
            target       = {
                description =
                "Program to launch with its arguments — a convenience over spelling out `parameters`. Its first word is mapped onto the adapter's program field and the rest onto its arguments field (the fields the adapter tags with the `target`/`args` roles), like `:Debug run_target`. Implies a `launch` request when `request` is unset.",
                oneOf       = {
                    {
                        type        = "string",
                        description = "Command line, split into program + arguments with shell word-splitting",
                    },
                    {
                        type        = "array",
                        description = "Program and its arguments as an already-split list ({ program, arg1, … })",
                        items       = { type = "string", minLength = 1 },
                        minItems    = 1,
                    },
                },
            },
            host         = {
                type        = { "string", "null" },
                minLength   = 1,
                description =
                "Hostname or IP address of the DAP server to connect to (attach only; overrides the adapter default)",
            },
            port         = {
                type        = { "integer", "null" },
                minimum     = 1,
                maximum     = 65535,
                description = "TCP port of the DAP server to connect to (attach only; required for `remote` adapter)",
            },
            parameters   = {
                type                 = { "object", "null" },
                additionalProperties = true,
                description          =
                "Native DAP launch/attach body sent verbatim to the chosen adapter. The valid keys depend on `adapter` and `request` (completed from the adapter's own schema).",
            },
            raw_messages = {
                type        = { "boolean", "null" },
                description = "Capture all raw DAP protocol messages in a dedicated buffer attached to the task",
            },
        },
        allOf       = _parameter_branches(sch),
    }
end


---Debug-relevant fields extracted from a task before dispatch to a backend.
---Backends receive this instead of the raw task so they remain independent of
---the easytasks task schema (which also carries framework fields like `type`,
---`depends_on`, `if_running`, etc.).
---The native DAP task handed to easydap. `parameters` is the adapter's raw
---launch/attach body, sent verbatim; easytasks no longer carries a generic
---field vocabulary. Mirrors `easydap.Task`.
---@class easytasks.debug.Params
---@field name         string
---@field adapter      string
---@field request      "launch"|"attach"|nil
---@field host         string|nil
---@field port         integer|nil
---@field parameters   table|nil
---@field raw_messages boolean|nil

---A `debug` task: the framework base plus the adapter selection and the native
---DAP `parameters` body.
---@class easytasks.DebugTask : easytasks.TaskBase
---@field adapter       string
---@field request?      "launch"|"attach"
---@field target?       string|string[]  program + args mapped onto the adapter's target/args fields
---@field host?         string
---@field port?         integer
---@field parameters?   table
---@field raw_messages? boolean

---@param task easytasks.DebugTask
---@return easytasks.debug.Params
local function _build_params(task)
    return {
        name         = task.name,
        adapter      = task.adapter,
        request      = task.request,
        host         = task.host,
        port         = task.port,
        parameters   = task.parameters,
        raw_messages = task.raw_messages,
    }
end

---Fold a task's `target` (a command line, or a `{ program, arg1, … }` list) into
---the native-body `values`, mapping its program and arguments onto whatever native
---keys the adapter tags with the `target`/`args` roles — the file-task equivalent
---of `:Debug run_target`. String targets are shell-split; list targets are taken
---as already-split. Mutates `values` in place.
---@param sch     table            the `easydap.schema` module
---@param adapter string
---@param request string           "launch"|"attach"
---@param target  string|string[]
---@param values  table<string, any>
---@return boolean ok, string? err
local function _apply_target(sch, adapter, request, target, values)
    local parts
    if type(target) == "string" then
        parts = str_util.split_shell_args(target)
    elseif type(target) == "table" then
        parts = target
    else
        return false, "target must be a string or a list of strings"
    end
    if #parts == 0 then
        return false, "target is empty"
    end

    local target_key = sch.key_of_role(adapter, request, "target")
    if not target_key then
        return false, ("adapter %s has no %s target field"):format(adapter, request)
    end
    local target_spec = sch.spec(adapter, request, target_key)
    local value, cerr = sch.coerce(target_spec, parts[1])
    if cerr then
        return false, target_key .. ": " .. cerr
    end
    values[target_key] = value

    local args = vim.list_slice(parts, 2)
    if #args > 0 then
        local args_key = sch.key_of_role(adapter, request, "args")
        if not args_key then
            return false, ("adapter %s takes no program arguments"):format(adapter)
        end
        values[args_key] = args
    end
    return true
end

---@param task    easytasks.DebugTask
---@param ctx     easytasks.RunCtx
---@param on_done fun(ok: boolean)
---@return fun()
function M.start(task, ctx, on_done)
    local params = _build_params(task)

    -- A bare `target` (program + args) implies a launch, so it can stand in for a
    -- full `request`/`parameters` pair.
    if task.target ~= nil and not params.request then
        params.request = "launch"
    end

    -- When the adapter declares a schema for this request, assemble the native
    -- body through easydap so file-defined tasks get the same defaulting and
    -- required-field checks that `:Debug quick_run` applies (and so a `target`
    -- can be mapped onto the adapter's native program/args keys). Adapters
    -- without a schema receive `parameters` verbatim.
    if params.request then
        local sch = require("easydap.schema")
        if sch.schema(params.adapter, params.request) then
            local values = vim.deepcopy(params.parameters or {})

            if task.target ~= nil then
                local ok, terr = _apply_target(sch, params.adapter, params.request, task.target, values)
                if not ok then
                    ctx.report("debug: " .. terr)
                    on_done(false)
                    return function() end
                end
            end

            local body, err = sch.build(params.adapter, params.request, values)
            if not body then
                ctx.report("debug: " .. tostring(err))
                on_done(false)
                return function() end
            end
            params.parameters = body
        elseif task.target ~= nil then
            ctx.report(("debug: adapter %s has no %s schema; `target` needs one (set `parameters` instead)")
                :format(params.adapter, params.request))
            on_done(false)
            return function() end
        end
    end

    return require("easydap.task").start(params, {
        add_bufnr = ctx.add_bufnr,
        report    = ctx.report,
        on_done   = on_done,
    })
end

M.schema = _schema

---@return easytasks.TaskTemplate[]
M.templates = function()
    return require("easytasks.types.debug.templates")()
end

return M
