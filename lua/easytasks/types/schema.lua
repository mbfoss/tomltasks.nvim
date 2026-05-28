--- Task schema builder.
--- `base_properties` holds the fields shared by every task type.
--- `build(type_registry)` constructs the full JSON Schema from registered types.
local M = {}

--- Properties present on every task regardless of type.
--- The `type` field itself is omitted here; `build` inserts it with the correct enum.
M.base_properties = {
    name = {
        type        = "string",
        minLength   = 1,
        description = "Unique, non-empty name of the task",
    },
    save_buffers = {
        type        = "boolean",
        default     = false,
        description = "If true, all modified workspace buffers will be saved before running the task",
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
            type                = "string",
            minLength           = 1,
            ["x-enumfunc"] = "easytasks.tasks.names",
            description         = "Name of a task this task depends on",
        },
    },
    depends_order = {
        type                  = "string",
        enum                  = { "sequence", "parallel" },
        ["x-enumDescriptions"] = { "dependencies run one after another", "dependencies run concurrently" },
        description           = "Specifies how dependencies listed in 'depends_on' are executed",
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
        local ts = td.schema or {}

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
