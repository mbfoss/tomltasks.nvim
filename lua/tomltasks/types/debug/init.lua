---@class tomltasks.debug.Module : tomltasks.TaskTypeDef
local M = {}

--- Widen one input's schema to every form the tasks file may write it in: the
--- typed form ezdap's input registry states, plus the string form it reads for
--- the same value (`port = "8080"`, `env = "A=1,B=2"`) — `resolve_task` takes
--- either. The typed constraints stay, and apply to the typed form alone.
---@param prop table  the input's typed form, as JSON Schema (mutated in place)
---@return table
local function _authored_forms(prop)
    if prop.type ~= "string" then
        prop.type = { prop.type, "string" }
    end
    return prop
end

--- The `parameters` object schema for one (adapter, mode): one property per
--- input the mode declares, described with the input's own `description` and
--- typed in the authored forms ezdap's input registry states as JSON Schema.
--- Every input resolves to a row there, so every one of them is described.
---@param sch table  the `ezdap.schema` module
---@param adapter string
---@param mode_name string
---@return table
local function _parameters_schema(sch, adapter, mode_name)
    local dap_inputs = require("ezdap.inputs")
    local required   = sch.mode_required(adapter, mode_name)

    local props = {}
    for name, input in pairs(sch.mode_inputs(adapter, mode_name)) do
        local prop = _authored_forms(dap_inputs.json_schema(input))
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

--- A `mode` property schema listing an adapter's mode names,
--- with each name's `description` (from ezdap) attached so the LSP can show
--- it on completion/hover.
---@param sch table  the `ezdap.schema` module
---@param adapter string
---@param mode_names string[]
---@return table
local function _mode_name_schema(sch, adapter, mode_names)
    local one_of = {}
    for _, mode_name in ipairs(mode_names) do
        local mode = sch.mode(adapter, mode_name)
        one_of[#one_of + 1] = {
            const       = mode_name,
            description = mode and mode.description,
        }
    end
    return {
        type      = "string",
        minLength = 1,
        oneOf     = one_of,
    }
end

--- Per-adapter conditional branches: each tests only `adapter` and nests its
--- (adapter, mode) `parameters` branches inside its own `then`, so the
--- navigator walks only the matched adapter's modes.
---@param sch table  the `ezdap.schema` module
---@return table[]
local function _mode_branches(sch)
    local branches = {}
    for _, adapter in ipairs(sch.adapters_with_modes()) do
        local mode_names = sch.mode_names(adapter)

        local mode_branches = {}
        for _, mode_name in ipairs(mode_names) do
            mode_branches[#mode_branches + 1] = {
                ["if"] = {
                    type       = "object",
                    required   = { "mode" },
                    properties = {
                        mode = { const = mode_name },
                    },
                },
                ["then"] = {
                    properties = {
                        parameters = _parameters_schema(sch, adapter, mode_name),
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
                    mode = _mode_name_schema(sch, adapter, mode_names),
                },
                allOf = (#mode_branches > 0) and mode_branches or nil,
            },
        }
    end
    return branches
end

--- The `debug` task schema. tomltasks owns only the framework fields; the DAP
--- vocabulary lives entirely under `parameters` and is projected from ezdap's
--- per-adapter named modes.
---@return table
local function _schema()
    local sch          = require("ezdap.schema")
    local all_adapters = sch.adapters_with_modes()

    return {
        description = "Definition of a `debug` task (runs via a DAP adapter)",
        ["x-order"] = {
            "name", "type", "if_running", "depends_on", "depends_order", "save_buffers",
            "adapter", "mode", "parameters",
        },
        required    = { "adapter", "mode" },
        properties  = {
            adapter       = {
                type        = "string",
                minLength   = 1,
                description = "Name of the DAP adapter to use (e.g. codelldb, delve, debugpy)",
                enum        = all_adapters,
            },
            mode          = {
                type        = "string",
                minLength   = 1,
                description = "Name of the adapter's named mode to run (its available launch/attach shapes)",
            },
            parameters    = {
                type                 = { "object", "null" },
                additionalProperties = true,
                description = "Values for the selected `mode`'s inputs",
            },
        },
        allOf       = _mode_branches(sch),
    }
end

---A `debug` task: the framework base plus the adapter/mode selection
---and the values for that mode's inputs.
---@class tomltasks.DebugTask : tomltasks.TaskBase
---@field adapter        string
---@field mode           string
---@field parameters?    table<string, any>

--- Each live run's ezdap dispose handle, by run id. Entries are dropped as the
--- runs are disposed.
---@type table<string, fun()>
local _ezdap_dispose = {}

---@param task    tomltasks.DebugTask
---@param ctx     tomltasks.RunCtx
---@param on_done fun(ok: boolean)
---@return fun()
function M.start(task, ctx, on_done)
    -- `resolve_task` answers through a callback because a mode's `build` may
    -- prompt the user first, so the task can arrive later than this call. Until
    -- then there is no session to stop — hence `cancel_resolve`.
    local stop, finished = nil, false

    ---`on_done` fires once, whichever of the run and the cancel path gets there first.
    ---@param ok boolean
    local function settle(ok)
        if finished then return end
        finished = true
        on_done(ok)
    end

    local cancel_resolve = require("ezdap.schema").resolve_task({
        adapter = task.adapter,
        mode    = task.mode,
        name    = ctx.name,
        values  = task.parameters,
    }, function(dap_task, err)
        if not dap_task then
            ctx.report("debug: " .. tostring(err))
            return settle(false)
        end

        stop, _ezdap_dispose[ctx.run_id] = require("ezdap").start_task(dap_task, {
            add_bufnr = ctx.add_bufnr,
            report    = ctx.report,
            on_done   = settle,
        })
    end)

    return function()
        cancel_resolve()
        -- Either the session is up and stopping it settles us, or the resolve is
        -- still out (parked on a picker, perhaps forever) and nothing will start.
        if stop then stop() else settle(false) end
    end
end

--- Delete the run's buffers and let ezdap drop what the run left in its own UI.
--- A run that never got as far as starting a session has no handle to call.
---@param run_id string
---@param bufnrs tomltasks.BufEntry[]
function M.dispose(run_id, bufnrs)
    local ezdap_dispose = _ezdap_dispose[run_id]
    _ezdap_dispose[run_id] = nil
    if ezdap_dispose then ezdap_dispose() end

    for _, be in ipairs(bufnrs) do
        if vim.api.nvim_buf_is_valid(be.bufnr) then
            vim.api.nvim_buf_delete(be.bufnr, { force = true })
        end
    end
end

M.schema = _schema

---@return tomltasks.TaskTemplate[]
M.templates = function()
    return require("tomltasks.types.debug.templates")()
end

return M
