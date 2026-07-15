---@class easytasks.debug.Module : easytasks.TaskTypeDef
local M = {}

--- Map an easydap input to a JSON Schema fragment for the tasks-file LSP.
--- An input declares what it *is* (`easydap.InputType`) and, separately, how a
--- raw string is read into that type (`easydap.InputFormat`). A `table` input
--- only says which shape it takes via its format, and `port` narrows an integer
--- to its range, so the format is consulted first and the type answers the rest.
--- The path-ish formats (`file`, `dir`, `cwd`, `host`) and an undeclared type
--- both fall through to a plain string.
---@param input table  an `easydap.Input`
---@return table
local function _input_schema(input)
    local format = input.format ---@type string?
    if format == "port" then
        return { type = "integer", minimum = 0, maximum = 65535 }
    elseif format == "shell_args" then
        -- Written as a command line, the way it would be typed at a shell;
        -- easydap splits it into arguments when it fills the configuration.
        return { type = "string" }
    elseif format == "list" then
        return { type = "array", items = { type = "string" } }
    elseif format == "env" then
        return { type = "object", additionalProperties = { type = "string" } }
    end

    local input_type = input.type ---@type string?
    if input_type == "integer" then
        return { type = "integer" }
    elseif input_type == "number" then
        return { type = "number" }
    elseif input_type == "boolean" then
        return { type = "boolean" }
    else
        return { type = "string" }
    end
end

--- The `parameters` object schema for one (adapter, configuration): one property
--- per input the configuration declares, typed from its declared `type`/`format`
--- and described with the input's own `description`.
---@param sch table  the `easydap.schema` module
---@param adapter string
---@param configuration_name string
---@return table
local function _parameters_schema(sch, adapter, configuration_name)
    local configuration = sch.configuration(adapter, configuration_name)
    local required      = sch.configuration_required(adapter, configuration_name)
    local inputs        = configuration.inputs or {}

    local props = {}
    for name, input in pairs(inputs) do
        local prop = _input_schema(input)
        prop.description = input.description
        props[name] = prop
    end

    return {
        type                 = "object",
        additionalProperties = false,
        properties           = props,
        required             = (#required > 0) and required or nil,
    }
end

--- A `configuration` property schema listing an adapter's configuration names,
--- with each name's `description` (from easydap) attached so the LSP can show
--- it on completion/hover.
---@param sch table  the `easydap.schema` module
---@param adapter string
---@param configuration_names string[]
---@return table
local function _configuration_name_schema(sch, adapter, configuration_names)
    local one_of = {}
    for _, configuration_name in ipairs(configuration_names) do
        local configuration = sch.configuration(adapter, configuration_name)
        one_of[#one_of + 1] = {
            const       = configuration_name,
            description = configuration and configuration.description,
        }
    end
    return {
        type      = "string",
        minLength = 1,
        oneOf     = one_of,
    }
end

--- Per-adapter conditional branches: each branch first tests only `adapter`,
--- and nests the (adapter, configuration) branches for `parameters` inside its
--- own `then`. This way the schema navigator only has to walk the
--- configuration-level branches of the adapter that actually matched, rather
--- than re-testing every adapter's configuration names against every task
--- (which mattered once the adapter count got large).
---@param sch table  the `easydap.schema` module
---@return table[]
local function _configuration_branches(sch)
    local branches = {}
    for _, adapter in ipairs(sch.quick_run_adapters()) do
        local configuration_names = sch.configuration_names(adapter)

        local configuration_branches = {}
        for _, configuration_name in ipairs(configuration_names) do
            configuration_branches[#configuration_branches + 1] = {
                ["if"] = {
                    type       = "object",
                    required   = { "configuration" },
                    properties = {
                        configuration = { const = configuration_name },
                    },
                },
                ["then"] = {
                    properties = {
                        parameters = _parameters_schema(sch, adapter, configuration_name),
                    },
                },
            }
        end

        branches[#branches + 1] = {
            ["if"] = {
                type       = "object",
                required   = { "adapter" },
                properties = { adapter = { const = adapter } },
            },
            ["then"] = {
                properties = {
                    configuration = _configuration_name_schema(sch, adapter, configuration_names),
                },
                allOf = (#configuration_branches > 0) and configuration_branches or nil,
            },
        }
    end
    return branches
end

--- The `debug` task schema. easytasks owns only the framework fields; the DAP
--- vocabulary lives entirely under `parameters` (values for the chosen
--- configuration's inputs) and is projected from easydap's per-adapter named
--- configurations.
---@return table
local function _schema()
    local sch          = require("easydap.schema")
    local all_adapters = sch.quick_run_adapters()

    return {
        description = "Definition of a `debug` task (runs via a DAP adapter)",
        ["x-order"] = {
            "name", "type", "if_running", "depends_on", "depends_order", "save_buffers",
            "adapter", "configuration", "parameters", "request_overrides", "raw_messages",
        },
        required    = { "adapter", "configuration" },
        properties  = {
            adapter       = {
                type        = "string",
                minLength   = 1,
                description = "Name of the DAP adapter to use (e.g. codelldb, delve, debugpy)",
                enum        = all_adapters,
            },
            configuration = {
                type        = "string",
                minLength   = 1,
                description = "Name of the adapter's named configuration to run (its available launch/attach shapes)",
            },
            parameters    = {
                type                 = { "object", "null" },
                additionalProperties = true,
                description = "Values for the selected `configuration`'s inputs",
            },
            request_overrides = {
                type                 = { "object", "null" },
                additionalProperties = true,
                description = "Raw DAP request-body fields, deep-merged over the resolved configuration (advanced escape hatch; not validated against the adapter)",
            },
            raw_messages  = {
                type        = { "boolean", "null" },
                description = "Capture all raw DAP protocol messages in a dedicated buffer attached to the task",
            },
        },
        allOf       = _configuration_branches(sch),
    }
end

---A `debug` task: the framework base plus the adapter/configuration selection
---and the values for that configuration's inputs.
---@class easytasks.DebugTask : easytasks.TaskBase
---@field adapter        string
---@field configuration  string
---@field parameters?    table<string, any>
---@field request_overrides? table<string, any>
---@field raw_messages?  boolean

---@param task    easytasks.DebugTask
---@param ctx     easytasks.RunCtx
---@param on_done fun(ok: boolean)
---@return fun()
function M.start(task, ctx, on_done)
    local sch           = require("easydap.schema")
    local configuration = sch.configuration(task.adapter, task.configuration)
    if not configuration then
        ctx.report(("debug: adapter %s has no configuration %q (available: %s)")
            :format(task.adapter, tostring(task.configuration), table.concat(sch.configuration_names(task.adapter), ", ")))
        on_done(false)
        return function() end
    end

    -- `fill_configuration` answers through a callback because a configuration's
    -- `build` may ask the user something first (an attach shape picks a process
    -- for an unset `pid`), so the body can arrive a picker later than this call.
    -- Until it does there is no session to stop — a cancel in that window has to
    -- be remembered and honoured when the answer lands.
    local stop, cancelled, finished = nil, false, false

    ---@param ok boolean
    local function settle(ok)
        if finished then return end
        finished = true
        on_done(ok)
    end

    sch.fill_configuration(task.adapter, task.configuration, task.parameters or {}, function(body, connect, err)
        if cancelled then
            return settle(false)
        end
        if not body then
            ctx.report("debug: " .. tostring(err))
            return settle(false)
        end

        if task.request_overrides then
            body = vim.tbl_deep_extend("force", body, task.request_overrides)
        end

        local params = {
            name         = ctx.name,
            adapter      = task.adapter,
            request      = configuration.request,
            parameters   = body,
            host         = connect and connect.host,
            port         = connect and connect.port,
            raw_messages = task.raw_messages,
        }

        stop = require("easydap").start_task(params, {
            add_bufnr = ctx.add_bufnr,
            report    = ctx.report,
            on_done   = settle,
        })
    end)

    return function()
        cancelled = true
        if stop then
            stop()
        else
            -- Cancelled while `build` still holds the answer: nothing will start,
            -- and a `build` parked on a picker may never call back at all.
            settle(false)
        end
    end
end

M.schema = _schema

---@return easytasks.TaskTemplate[]
M.templates = function()
    return require("easytasks.types.debug.templates")()
end

return M
