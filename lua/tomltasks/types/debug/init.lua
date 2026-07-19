---@class tomltasks.debug.Module : tomltasks.TaskTypeDef
local M = {}

--- The `parameters` object schema for one (adapter, profile): one property
--- per input the profile declares, described with the input's own
--- `description`. A tasks file is a *typed* document, so each property is the
--- input's typed authored form — which easydap's input registry states directly,
--- as JSON Schema, alongside the parse/seed/completion faces of the same format.
---@param sch table  the `easydap.schema` module
---@param adapter string
---@param profile_name string
---@return table
local function _parameters_schema(sch, adapter, profile_name)
    local dap_inputs = require("easydap.inputs")
    local required   = sch.profile_required(adapter, profile_name)

    local props = {}
    for name, input in pairs(sch.profile_inputs(adapter, profile_name)) do
        local prop = dap_inputs.json_schema(input)
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

--- A `profile` property schema listing an adapter's profile names,
--- with each name's `description` (from easydap) attached so the LSP can show
--- it on completion/hover.
---@param sch table  the `easydap.schema` module
---@param adapter string
---@param profile_names string[]
---@return table
local function _profile_name_schema(sch, adapter, profile_names)
    local one_of = {}
    for _, profile_name in ipairs(profile_names) do
        local profile = sch.profile(adapter, profile_name)
        one_of[#one_of + 1] = {
            const       = profile_name,
            description = profile and profile.description,
        }
    end
    return {
        type      = "string",
        minLength = 1,
        oneOf     = one_of,
    }
end

--- Per-adapter conditional branches: each branch first tests only `adapter`,
--- and nests the (adapter, profile) branches for `parameters` inside its
--- own `then`. This way the schema navigator only has to walk the
--- profile-level branches of the adapter that actually matched, rather
--- than re-testing every adapter's profile names against every task
--- (which mattered once the adapter count got large).
---@param sch table  the `easydap.schema` module
---@return table[]
local function _profile_branches(sch)
    local branches = {}
    for _, adapter in ipairs(sch.profiled_adapters()) do
        local profile_names = sch.profile_names(adapter)

        local profile_branches = {}
        for _, profile_name in ipairs(profile_names) do
            profile_branches[#profile_branches + 1] = {
                ["if"] = {
                    type       = "object",
                    required   = { "profile" },
                    properties = {
                        profile = { const = profile_name },
                    },
                },
                ["then"] = {
                    properties = {
                        parameters = _parameters_schema(sch, adapter, profile_name),
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
                    profile = _profile_name_schema(sch, adapter, profile_names),
                },
                allOf = (#profile_branches > 0) and profile_branches or nil,
            },
        }
    end
    return branches
end

--- The `debug` task schema. tomltasks owns only the framework fields; the DAP
--- vocabulary lives entirely under `parameters` (values for the chosen
--- profile's inputs) and is projected from easydap's per-adapter named
--- profiles.
---@return table
local function _schema()
    local sch          = require("easydap.schema")
    local all_adapters = sch.profiled_adapters()

    return {
        description = "Definition of a `debug` task (runs via a DAP adapter)",
        ["x-order"] = {
            "name", "type", "if_running", "depends_on", "depends_order", "save_buffers",
            "adapter", "profile", "parameters", "request_overrides", "raw_messages",
        },
        required    = { "adapter", "profile" },
        properties  = {
            adapter       = {
                type        = "string",
                minLength   = 1,
                description = "Name of the DAP adapter to use (e.g. codelldb, delve, debugpy)",
                enum        = all_adapters,
            },
            profile       = {
                type        = "string",
                minLength   = 1,
                description = "Name of the adapter's named profile to run (its available launch/attach shapes)",
            },
            parameters    = {
                type                 = { "object", "null" },
                additionalProperties = true,
                description = "Values for the selected `profile`'s inputs",
            },
            request_overrides = {
                type                 = { "object", "null" },
                additionalProperties = true,
                description = "Raw DAP request-body fields, deep-merged over the resolved profile (advanced escape hatch; not validated against the adapter)",
            },
            raw_messages  = {
                type        = { "boolean", "null" },
                description = "Capture all raw DAP protocol messages in a dedicated buffer attached to the task",
            },
        },
        allOf       = _profile_branches(sch),
    }
end

---A `debug` task: the framework base plus the adapter/profile selection
---and the values for that profile's inputs.
---@class tomltasks.DebugTask : tomltasks.TaskBase
---@field adapter        string
---@field profile        string
---@field parameters?    table<string, any>
---@field request_overrides? table<string, any>
---@field raw_messages?  boolean

---@param task    tomltasks.DebugTask
---@param ctx     tomltasks.RunCtx
---@param on_done fun(ok: boolean)
---@return fun()
function M.start(task, ctx, on_done)
    -- `resolve_task` answers through a callback because a profile's `build`
    -- may ask the user something first (an attach shape picks a process for an unset
    -- `pid`), so the task can arrive a picker later than this call. Until it does
    -- there is no session to stop, which is what `cancel_resolve` is for: it drops
    -- the answer if one ever lands, leaving us free to settle right away.
    local stop, finished = nil, false

    ---`on_done` fires once, whichever of the run and the cancel path gets there first.
    ---@param ok boolean
    local function settle(ok)
        if finished then return end
        finished = true
        on_done(ok)
    end

    local cancel_resolve = require("easydap.schema").resolve_task({
        adapter = task.adapter,
        profile = task.profile,
        name    = ctx.name,
        values  = task.parameters,
    }, function(dap_task, err)
        if not dap_task then
            ctx.report("debug: " .. tostring(err))
            return settle(false)
        end

        if task.request_overrides then
            dap_task.parameters = vim.tbl_deep_extend("force", dap_task.parameters, task.request_overrides)
        end
        dap_task.raw_messages = task.raw_messages

        stop = require("easydap").start_task(dap_task, {
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

M.schema = _schema

---@return tomltasks.TaskTemplate[]
M.templates = function()
    return require("tomltasks.types.debug.templates")()
end

return M
