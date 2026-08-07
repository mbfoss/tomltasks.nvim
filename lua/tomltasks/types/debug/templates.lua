local ordered = require("tomltasks.util.table_util").ordered

--- Debug templates are projected from ezdap's per-adapter named profiles
--- rather than hand-maintained: one entry per (adapter, profile) that
--- ezdap declares, with `parameters` prefilled for the profile's
--- required inputs. This keeps the template list in lockstep with whatever
--- adapters ezdap ships.

--- Build the `parameters` skeleton for one (adapter, profile): every required
--- input, sorted. Starting values come from ezdap's input registry, so the task
--- is seeded in the authored form the tasks-file schema demands.
---@param sch table  the `ezdap.schema` module
---@param adapter string
---@param profile_name string
---@return table params, string[] order  empty when the profile requires nothing
local function _parameters(sch, adapter, profile_name)
    local dap_inputs = require("ezdap.inputs")
    local required   = sch.profile_required(adapter, profile_name)
    local inputs     = sch.profile_inputs(adapter, profile_name)
    local params, order = {}, {}
    for _, name in ipairs(required) do
        params[name] = dap_inputs.seed(inputs[name])
        order[#order + 1] = name
    end
    return params, order
end

---@return tomltasks.TaskTemplate[]
return function()
    local sch = require("ezdap.schema")
    local templates = {}
    for _, adapter in ipairs(sch.profiled_adapters()) do
        for _, profile_name in ipairs(sch.profile_names(adapter)) do
            local task_keys = { "name", "type", "adapter", "profile" }
            local task = {
                name    = "debug-" .. adapter,
                type    = "debug",
                adapter = adapter,
                profile = profile_name,
            }
            local params, order = _parameters(sch, adapter, profile_name)
            if #order > 0 then
                task.parameters = ordered(params, order)
                task_keys[#task_keys + 1] = "parameters"
            end
            templates[#templates + 1] = {
                label = ("%s - %s"):format(adapter, profile_name),
                task  = ordered(task, task_keys),
            }
        end
    end
    return templates
end
