--- Task schema builder.
--- `base_properties` holds the fields shared by every task type.
--- `build(type_registry)` constructs the full JSON Schema from registered types.
local M = {}

---@alias easytasks.IfRunning "wait"|"restart"|"refuse"|"parallel"
---@alias easytasks.DependsOrder "sequence"|"parallel"

--- Glob-filtered form of a task's `save_buffers` field.
---@class easytasks.TaskSaveBuffers
---@field include?        string[]  glob patterns; only matching buffers are saved (empty/omitted means all)
---@field exclude?        string[]  glob patterns; matching buffers are never saved
---@field include_hidden? boolean   also save hidden files, which are skipped by default

--- Fields shared by every task, regardless of type. The Lua-type mirror of
--- `base_properties` below; concrete task types extend this class with their
--- own fields.
---@class easytasks.TaskBase
---@field name           string                            unique, non-empty task name
---@field type           string                            task type (determines behaviour)
---@field if_running?    easytasks.IfRunning               what happens if the task is already running
---@field depends_on?    string[]                          names of tasks that must complete before this one runs
---@field depends_order? easytasks.DependsOrder            how `depends_on` tasks are executed
---@field save_buffers?  boolean|easytasks.TaskSaveBuffers save modified project buffers before running

--- Properties present on every task regardless of type.
--- The `type` field itself is omitted here; `build` inserts it with the correct enum.
M.base_properties = {
    name = {
        type        = "string",
        minLength   = 1,
        description = "Unique, non-empty name of the task",
    },
    if_running = {
        type                  = "string",
        enum                  = { "wait", "restart", "refuse", "parallel",  },
        ["x-enumDescriptions"] = {
            "Wait for the running instance to finish successfully",
            "Stop the current instance and start a new one",
            "Do not start a new instance if one is already running",
            "Start a new instance alongside any existing ones",
        },
        description = "Specifies what happens if the task is already running",
    },
    depends_on = {
        type        = { "array", "null" },
        description = "List of task names that must complete successfully before this task runs.\nThis enforces a completion-based dependency order.\n",
        items       = {
            type        = "string",
            minLength   = 1,
            description = "Name of a task this task depends on",
        },
    },
    depends_order = {
        type                  = "string",
        enum                  = { "sequence", "parallel" },
        ["x-enumDescriptions"] = { "dependencies run one after another", "dependencies run concurrently" },
        description           = "Specifies how dependencies listed in 'depends_on' are executed",
    },
    save_buffers = {
        description = "Save modified project buffers before the task (and its dependencies) run. Hidden files are skipped unless include_hidden is set.",
        oneOf       = {
            { type = "boolean", description = "true saves every modified project buffer; false (default) saves nothing" },
            {
                type                 = "object",
                additionalProperties = false,
                description          = "Save modified project buffers matching these glob filters",
                properties           = {
                    include = {
                        type        = "array",
                        description = "Glob patterns; only matching buffers are saved (empty/omitted means all)",
                        items       = { type = "string", minLength = 1, description = "Glob pattern" },
                    },
                    exclude = {
                        type        = "array",
                        description = "Glob patterns; matching buffers are never saved",
                        items       = { type = "string", minLength = 1, description = "Glob pattern" },
                    },
                    include_hidden = {
                        type        = "boolean",
                        default     = false,
                        description = "Also save hidden files (dotfiles or files under dot-directories), which are skipped by default",
                    },
                },
            },
        },
    },
}

--- Build the full JSON Schema for a tasks config file from a type registry.
---@param type_registry table<string, easytasks.TaskTypeDef>
---@return table JSON Schema
function M.build(type_registry)
    local type_names = vim.tbl_keys(type_registry)
    table.sort(type_names)

    local allOf = {}
    for _, name in ipairs(type_names) do
        local td = type_registry[name]
        -- A type may expose its schema as a table or as a zero-arg function
        -- (e.g. the `debug` type, whose schema depends on the active backend).
        local ts = td.schema
        if type(ts) == "function" then ts = ts() end
        ts = ts or {}

        -- Merge base properties + type-specific properties.
        -- Type-specific entries win on collision (shouldn't happen, but be explicit).
        local props = vim.tbl_deep_extend(
            "force",
            vim.deepcopy(M.base_properties),
            vim.deepcopy(ts.properties or {})
        )
        props.type = { const = name }

        -- required = ["name", "type"] + whatever the type adds
        local required = { "name", "type" }
        for _, r in ipairs(ts.required or {}) do
            if not vim.tbl_contains(required, r) then
                required[#required + 1] = r
            end
        end

        local then_schema = {
            description           = ts.description,
            ["x-order"]           = ts["x-order"],
            additionalProperties  = false,
            required              = required,
            properties            = props,
        }
        -- carry through any nested conditionals the type defined
        if ts["if"]   then then_schema["if"]   = ts["if"]   end
        if ts["then"] then then_schema["then"] = ts["then"] end
        if ts.allOf   then then_schema.allOf   = ts.allOf   end

        allOf[#allOf + 1] = {
            ["if"] = {
                type       = "object",
                required   = { "type" },
                properties = { type = { const = name } },
            },
            ["then"] = then_schema,
        }
    end

    return {
        title                = "Task Configuration",
        type                 = "object",
        additionalProperties = false,
        required             = { "tasks" },
        properties           = {
            expressions = {
                type                 = "object",
                description          = "Named inline expressions. Each value is an expression template that may reference other expressions (built-in, registered, or inline). Expand one in any task string with ${NAME}.",
                additionalProperties = { type = "string", description = "Expression template (may contain ${...} references)" },
            },
            tasks = {
                type                 = "array",
                description          = "List of task definitions",
                additionalProperties = false,
                items                = {
                    type        = "object",
                    required    = { "name", "type" },
                    ["x-order"] = { "name", "type" },
                    description = "Single task definition entry",
                    properties  = vim.tbl_extend("force", vim.deepcopy(M.base_properties), {
                        type = {
                            type        = "string",
                            enum        = type_names,
                            description = "Task type (used to determine behavior)",
                        },
                    }),
                    allOf = allOf,
                },
            },
        },
    }
end

return M
