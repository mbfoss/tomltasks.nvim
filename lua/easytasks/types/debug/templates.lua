local ordered = require("easytasks.util.table_util").ordered

--- Debug templates are projected from easydap's per-adapter schemas rather than
--- hand-maintained: one entry per (adapter, request) that easydap declares a
--- launch/attach schema for, with `parameters` prefilled from the schema's
--- required and default-bearing params. This keeps the template list in lockstep
--- with whatever adapters easydap ships.

--- A starting value for a schema param: its literal default when it has one,
--- otherwise a type/kind-appropriate placeholder.
---@param spec table  an `easydap.ParamSpec` (type/kind/default/required)
---@return any
local function _placeholder(spec)
    if spec.default ~= nil and type(spec.default) ~= "function" then
        return spec.default
    end
    local kind = spec.kind
    if kind == "argv" then return {} end
    if kind == "env" then return {} end
    if kind == "port" then return 0 end
    if spec.type == "boolean" then return false end
    if spec.type == "integer" or spec.type == "number" then return 0 end
    return ""
end

--- Build the `parameters` skeleton for one (adapter, request): every required
--- param plus every param that carries a default, in the schema's sorted order.
---@param sch  table  the `easydap.schema` module
---@param adapter string
---@param request string
---@return table params, string[] order  empty when the request has no such params
local function _parameters(sch, adapter, request)
    local params, order = {}, {}
    for _, key in ipairs(sch.param_names(adapter, request)) do
        local spec = sch.spec(adapter, request, key)
        if spec and (spec.required and spec.default ~= nil) then
            params[key] = _placeholder(spec)
            order[#order + 1] = key
        end
    end
    return params, order
end

---@return easytasks.TaskTemplate[]
return function()
    local sch = require("easydap.schema")
    local templates = {}
    for _, adapter in ipairs(sch.adapter_names()) do
        for _, request in ipairs(sch.requests(adapter)) do
            local task_keys = { "name", "type", "adapter", "request" }
            local task = {
                name    = "debug-" .. adapter,
                type    = "debug",
                adapter = adapter,
                request = request,
            }
            local params, order = _parameters(sch, adapter, request)
            if #order > 0 then
                task.parameters = ordered(params, order)
                task_keys[#task_keys + 1] = "parameters"
            end
            templates[#templates + 1] = {
                label = ("%s (%s)"):format(adapter, request),
                task  = ordered(task, task_keys),
            }
        end
    end
    return templates
end
