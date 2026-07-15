local ordered = require("easytasks.util.table_util").ordered

--- Debug templates are projected from easydap's per-adapter named configurations
--- rather than hand-maintained: one entry per (adapter, configuration) that
--- easydap declares, with `parameters` prefilled for the configuration's
--- required placeholders. This keeps the template list in lockstep with
--- whatever adapters easydap ships.

--- A starting value for a placeholder, appropriate to its declared
--- `easydap.PlaceholderType`.
---@param placeholder_type string?
---@return any
local function _placeholder(placeholder_type)
    if placeholder_type == "list" or placeholder_type == "shell_args" or placeholder_type == "env" then return {} end
    if placeholder_type == "port" or placeholder_type == "integer" or placeholder_type == "number" then return 0 end
    if placeholder_type == "boolean" then return false end
    return ""
end

--- Build the `parameters` skeleton for one (adapter, configuration): every
--- required placeholder, in sorted order.
---@param sch table  the `easydap.schema` module
---@param adapter string
---@param configuration_name string
---@return table params, string[] order  empty when the configuration requires nothing
local function _parameters(sch, adapter, configuration_name)
    local required = sch.configuration_required(adapter, configuration_name)
    local types = sch.configuration_placeholder_types(adapter, configuration_name)
    local params, order = {}, {}
    for _, name in ipairs(required) do
        params[name] = _placeholder(types[name])
        order[#order + 1] = name
    end
    return params, order
end

---@return easytasks.TaskTemplate[]
return function()
    local sch = require("easydap.schema")
    local templates = {}
    for _, adapter in ipairs(sch.quick_run_adapters()) do
        for _, configuration_name in ipairs(sch.configuration_names(adapter)) do
            local task_keys = { "name", "type", "adapter", "configuration" }
            local task = {
                name          = "debug-" .. adapter,
                type          = "debug",
                adapter       = adapter,
                configuration = configuration_name,
            }
            local params, order = _parameters(sch, adapter, configuration_name)
            if #order > 0 then
                task.parameters = ordered(params, order)
                task_keys[#task_keys + 1] = "parameters"
            end
            templates[#templates + 1] = {
                label = ("%s (%s)"):format(adapter, configuration_name),
                task  = ordered(task, task_keys),
            }
        end
    end
    return templates
end
