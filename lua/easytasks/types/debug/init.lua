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
    elseif spec.type == "table" then
        out.type = "object"
    elseif spec.type == "list" then
        out.type = "array"
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
            -- A task with no `request` defaults to "launch" at run time (see
            -- `M.start`), so the "launch" branch must also match when the field
            -- is absent, not just when it's explicitly set to "launch".
            local request_cond
            if request == "launch" then
                request_cond = {
                    anyOf = {
                        { ["not"] = { required = { "request" } } },
                        { required = { "request" }, properties = { request = { const = request } } },
                    },
                }
            else
                request_cond = {
                    required   = { "request" },
                    properties = { request = { const = request } },
                }
            end

            branches[#branches + 1] = {
                ["if"] = vim.tbl_deep_extend("force", {
                    type       = "object",
                    required   = { "adapter" },
                    properties = {
                        adapter = { const = adapter },
                    },
                }, request_cond),
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
            "adapter", "request", "command", "cwd", "env", "pid", "host", "port", "parameters", "raw_messages",
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
            command      = {
                description =
                "Program to launch with its arguments — a convenience over spelling out `parameters`. Its first word is mapped onto the adapter's program field and the rest onto its arguments field (the fields the adapter tags with the `target`/`args` roles). Implies a `launch` request when `request` is unset.",
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
            cwd          = {
                type        = { "string", "null" },
                minLength   = 1,
                description =
                "Working directory for the debuggee — a convenience over `parameters`, mapped onto whatever native key the adapter tags with the `cwd` role.",
            },
            env          = {
                type                 = { "object", "null" },
                additionalProperties = { type = "string" },
                description          =
                "Environment variables for the debuggee — a convenience over `parameters`, mapped onto whatever native key the adapter tags with the `env` role.",
            },
            pid          = {
                type        = { "integer", "null" },
                minimum     = 1,
                description =
                "Process ID to attach to — a convenience over `parameters`, mapped onto whatever native key the adapter tags with the `pid` role (attach only).",
            },
            host         = {
                type        = { "string", "null" },
                minLength   = 1,
                description =
                "Host to attach to (attach only). Sets the task-level TCP connection for adapters that use one (e.g. `remote`) and/or the adapter's `host`-role field.",
            },
            port         = {
                type        = { "integer", "null" },
                minimum     = 1,
                maximum     = 65535,
                description =
                "Port to attach to (attach only). Sets the task-level TCP connection for adapters that use one (required for `remote`) and/or the adapter's `port`-role field.",
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
---@field command?      string|string[]        program + args mapped onto the adapter's target/args roles
---@field cwd?          string                 working directory mapped onto the adapter's cwd role
---@field env?          table<string, string>  environment mapped onto the adapter's env role
---@field pid?          integer                PID to attach to, mapped onto the adapter's pid role
---@field host?         string
---@field port?         integer
---@field parameters?   table
---@field raw_messages? boolean

---@param task easytasks.DebugTask
---@return easytasks.debug.Params
local function _build_params(task)
    -- `host`/`port` are deliberately omitted here: whether they set the task-level
    -- TCP endpoint depends on the adapter (see `M.start`), so they can't be a plain
    -- task→params copy like the other fields.
    return {
        name         = task.name,
        adapter      = task.adapter,
        request      = task.request,
        parameters   = task.parameters,
        raw_messages = task.raw_messages,
    }
end

---Fold a task's `command` (a command line, or a `{ program, arg1, … }` list) into
---the native-body `values`, mapping its program and arguments onto whatever native
---keys the adapter tags with the `target`/`args` roles — the file-task equivalent
---of `:Debug run_target`. String commands are shell-split; list commands are taken
---as already-split. Mutates `values` in place.
---@param sch     table            the `easydap.schema` module
---@param adapter string
---@param request string           "launch"|"attach"
---@param command string|string[]
---@param values  table<string, any>
---@return boolean ok, string? err
local function _apply_target(sch, adapter, request, command, values)
    local parts
    if type(command) == "string" then
        parts = str_util.split_shell_args(command)
    elseif type(command) == "table" then
        parts = command
    else
        return false, "command must be a string or a list of strings"
    end
    if #parts == 0 then
        return false, "command is empty"
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

---The 1-to-1 convenience fields. Each names a `debug` task key whose value maps
---directly onto the single native param the adapter tags with the matching
---`role` — unlike `target`, which fans out across the `target`/`args` roles.
---@type string[]
local _ROLE_FIELDS = { "cwd", "env", "pid", "host", "port" }

---Whether any convenience field (`command` or a 1-to-1 role field) is set. These
---fold into the native `parameters` body, so they need a concrete request to
---resolve the adapter's role-tagged keys against.
---@param task easytasks.DebugTask
---@return boolean
local function _has_convenience(task)
    if task.command ~= nil then return true end
    for _, role in ipairs(_ROLE_FIELDS) do
        if task[role] ~= nil then return true end
    end
    return false
end

---Whether a set convenience field must be folded into the request body (and so
---needs the adapter to declare a schema). `host`/`port` on a task-level TCP
---adapter are carried by the connection endpoint instead, so they don't count.
---@param task easytasks.DebugTask
---@param is_tcp boolean
---@return boolean
local function _needs_body_schema(task, is_tcp)
    if task.command ~= nil or task.cwd ~= nil or task.env ~= nil or task.pid ~= nil then
        return true
    end
    return not is_tcp and (task.host ~= nil or task.port ~= nil)
end

---Fold the 1-to-1 convenience fields set on `task` onto the adapter's role-tagged
---native keys for `request` — the single-key analogue of `_apply_target`. Each
---value is already a schema-typed native value (unlike a `quick_run` CLI string),
---so it is placed verbatim; `build` supplies the surrounding defaults. `host`/`port`
---may have no body field on a task-level TCP adapter (its endpoint carries them,
---set by the caller), so there they are allowed to map onto nothing. Mutates
---`values` in place.
---@param sch     table              the `easydap.schema` module
---@param adapter string
---@param request string             "launch"|"attach"
---@param task    easytasks.DebugTask
---@param values  table<string, any>
---@param is_tcp  boolean            adapter connects over a task-level TCP endpoint
---@return boolean ok, string? err
local function _apply_roles(sch, adapter, request, task, values, is_tcp)
    for _, role in ipairs(_ROLE_FIELDS) do
        local value = task[role]
        if value ~= nil then
            local key = sch.key_of_role(adapter, request, role)
            if key then
                values[key] = value
            elseif not (is_tcp and (role == "host" or role == "port")) then
                return false, ("adapter %s has no %s %s field"):format(adapter, request, role)
            end
        end
    end
    return true
end

---@param task    easytasks.DebugTask
---@param ctx     easytasks.RunCtx
---@param on_done fun(ok: boolean)
---@return fun()
function M.start(task, ctx, on_done)
    local params = _build_params(task)

    local base   = require("easydap.adapters")[params.adapter]
    -- A task-level TCP adapter (its def carries a host/port) connects over an
    -- endpoint; there host/port set the connection, not (only) a body field.
    local is_tcp = base ~= nil and (base.host ~= nil or base.port ~= nil)

    -- Convenience fields fold into the native `parameters` body, which needs a
    -- concrete request to resolve the adapter's role-tagged keys against. A bare
    -- `command` (program + args) implies a launch; the rest fall back to the
    -- adapter's own default request (e.g. `remote` attaches), so an attach task
    -- need not spell out `request`.
    if _has_convenience(task) and not params.request then
        params.request = (task.command ~= nil and "launch") or (base and base.request) or "launch"
    end

    -- host/port on a TCP adapter set the connection endpoint (in addition to any
    -- body field they also map onto below). A stdio adapter with host/port body
    -- fields (e.g. lldb's gdb-remote-*) is NOT task-level, so its host/port stay
    -- in the body — setting the endpoint would wrongly flip it to a TCP connection.
    if is_tcp then
        params.host = task.host
        params.port = task.port
    end

    -- When the adapter declares a schema for this request, assemble the native
    -- body through easydap so file-defined tasks get the same defaulting and
    -- required-field checks that `:Debug quick_run` applies (and so the
    -- convenience fields can be mapped onto the adapter's native keys). Adapters
    -- without a schema receive `parameters` verbatim.
    if params.request then
        local sch = require("easydap.schema")
        if sch.schema(params.adapter, params.request) then
            local values = vim.deepcopy(params.parameters or {})

            if task.command ~= nil then
                local ok, terr = _apply_target(sch, params.adapter, params.request, task.command, values)
                if not ok then
                    ctx.report("debug: " .. terr)
                    on_done(false)
                    return function() end
                end
            end

            local ok, rerr = _apply_roles(sch, params.adapter, params.request, task, values, is_tcp)
            if not ok then
                ctx.report("debug: " .. rerr)
                on_done(false)
                return function() end
            end

            local body, err = sch.build(params.adapter, params.request, values)
            if not body then
                ctx.report("debug: " .. tostring(err))
                on_done(false)
                return function() end
            end
            params.parameters = body
        elseif _needs_body_schema(task, is_tcp) then
            ctx.report(("debug: adapter %s has no %s schema; convenience fields (command/cwd/env/pid/host/port) need one (set `parameters` instead)")
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
