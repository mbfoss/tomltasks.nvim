---@class easytasks.debug.Module : easytasks.TaskTypeDef
local M = {}

--- Map an easydap configuration placeholder's `kind` to a JSON Schema fragment
--- for the tasks-file LSP.
---@param kind string?
---@return table
local function _placeholder_schema(kind)
    if kind == "port" then
        return { type = "integer", minimum = 0, maximum = 65535 }
    elseif kind == "integer" then
        return { type = "integer" }
    elseif kind == "number" then
        return { type = "number" }
    elseif kind == "boolean" then
        return { type = "boolean" }
    elseif kind == "list" or kind == "shell_args" then
        return { type = "array", items = { type = "string" } }
    elseif kind == "env" then
        return { type = "object", additionalProperties = { type = "string" } }
    else
        return { type = "string" }
    end
end

--- The `parameters` object schema for one (adapter, configuration): one property
--- per placeholder the configuration declares, typed from its `kind`.
---@param sch table  the `easydap.schema` module
---@param adapter string
---@param configuration_name string
---@return table
local function _parameters_schema(sch, adapter, configuration_name)
    local configuration = sch.configuration(adapter, configuration_name)
    local required       = {}
    for _, name in ipairs(configuration.required or {}) do required[#required + 1] = name end
    table.sort(required)

    local props = {}
    for _, name in ipairs(sch.configuration_placeholders(adapter, configuration_name)) do
        local kind  = sch.configuration_placeholder_kind(adapter, configuration_name, name)
        props[name] = _placeholder_schema(kind)
    end

    return {
        type                 = "object",
        additionalProperties = false,
        properties           = props,
        required             = (#required > 0) and required or nil,
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
                    configuration = { enum = configuration_names },
                },
                allOf = (#configuration_branches > 0) and configuration_branches or nil,
            },
        }
    end
    return branches
end

--- The `debug` task schema. easytasks owns only the framework fields; the DAP
--- vocabulary lives entirely under `parameters` (values for the chosen
--- configuration's placeholders) and is projected from easydap's per-adapter
--- named configurations.
---@return table
local function _schema()
    local sch          = require("easydap.schema")
    local all_adapters = sch.quick_run_adapters()

    return {
        description = "Definition of a `debug` task (runs via a DAP adapter)",
        ["x-order"] = {
            "name", "type", "if_running", "depends_on", "depends_order", "save_buffers",
            "adapter", "configuration", "parameters", "raw_messages",
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
---and the values for that configuration's placeholders.
---@class easytasks.DebugTask : easytasks.TaskBase
---@field adapter       string
---@field configuration string
---@field parameters?   table<string, any>
---@field raw_messages? boolean

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

    local body, connect, err = sch.fill_configuration(task.adapter, task.configuration, task.parameters or {})
    if not body then
        ctx.report("debug: " .. tostring(err))
        on_done(false)
        return function() end
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
