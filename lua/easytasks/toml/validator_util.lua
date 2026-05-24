local M = {}

---Determine displayed type name for tree rendering
---@param v any
---@return string
function M.value_type(v)
    local ty = type(v)
    if ty == "table" then
        return vim.islist(v) and "array" or "object"
    end
    if ty == "boolean" then return "boolean" end
    if ty == "number" then return "number" end
    if ty == "string" then return "string" end
    if v == vim.NIL then return "null" end
    return "unknown"
end

---@param dest table|nil
---@param src table|nil
function M.merge_additional_properties(dest, src)
    if not dest then return end
    if dest.additionalProperties == nil
        and type(src) == "table"
        and type(src.additionalProperties) == "boolean" then
        dest.additionalProperties = src.additionalProperties
    end
end

---@param schema table|nil
---@return string[]
function M.get_schema_allowed_types(schema)
    if not schema then return {} end

    if schema.const ~= nil then
        return { M.value_type(schema.const) }
    end

    if schema.enum then
        ---@type table<string, boolean>
        local types_set = {}
        for _, v in ipairs(schema.enum) do
            types_set[M.value_type(v)] = true
        end
        local types = {}
        for t in pairs(types_set) do
            table.insert(types, t)
        end
        return types
    end

    if schema.oneOf then
        ---@type table<string, boolean>
        local types_set = {}
        for _, subschema in ipairs(schema.oneOf) do
            if subschema.type then
                local t = subschema.type
                if type(t) == "table" then
                    for _, typ in ipairs(t) do types_set[typ] = true end
                else
                    types_set[t] = true
                end
            elseif subschema.const ~= nil then
                types_set[M.value_type(subschema.const)] = true
            end
        end
        local types = {}
        for t in pairs(types_set) do
            table.insert(types, t)
        end
        return types
    end

    if schema.type then
        if type(schema.type) == "table" then
            return schema.type
        else
            return { schema.type }
        end
    end

    return {}
end

function M.deep_merge_tables(dest, src)
    vim.validate({
        dest = { dest, "table" },
        src = { src, "table" },
    })

    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dest[k]) == "table" and not vim.islist(v) then
                M.deep_merge_tables(dest[k], v)
            else
                dest[k] = vim.deepcopy(v)
            end
        else
            dest[k] = v
        end
    end
    return dest
end

return M
