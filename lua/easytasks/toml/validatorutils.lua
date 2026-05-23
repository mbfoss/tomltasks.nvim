local M = {}


local function _escape_ptr(token)
    return (tostring(token)
        :gsub("~", "~0")
        :gsub("/", "~1"))
end

local function _unescape_ptr(token)
    return (token
        :gsub("~1", "/")
        :gsub("~0", "~"))
end
---@param base string
---@param key string
---@return string
function M.join_path(base, key)
    local escaped = _escape_ptr(key)
    if base == "" then
        return "/" .. escaped
    end
    return base .. "/" .. escaped
end

---@param parts string[]
---@return string
function M.join_path_parts(parts)
    local arr = {}
    for _, seg in ipairs(parts) do
        if seg ~= nil then
            table.insert(arr, _escape_ptr(seg))
        end
    end
    return "/" .. table.concat(arr, "/")
end

---@param path string -- -- JSON Pointer (defined in RFC 6901)
---@return string[]
function M.split_path(path)
    if path == "" then
        return {}
    end

    local rest  = path:sub(2)
    local parts = {}
    for seg in (rest .. "/"):gmatch("([^/]*)%/") do
        table.insert(parts, _unescape_ptr(seg))
    end
    return parts
end

---@param root any
---@param path string -- JSON Pointer (RFC 6901)
---@return any value, string? error
function M.get_at_path(root, path)
    if path == "" then
        return root
    end
    local parts = M.split_path(path)
    local current = root
    for i, key in ipairs(parts) do
        if type(current) ~= "table" then
            return nil, ("Cannot index non-table at segment %d ('%s')"):format(i, key)
        end
        if vim.islist(current) then
            local idx = tonumber(key)
            if not idx then
                return nil, ("Invalid array index '%s' at segment %d"):format(key, i)
            end
            current = current[idx]
        else
            current = current[key]
        end
        if current == nil then
            return nil, ("Path not found at segment %d ('%s')"):format(i, key)
        end
    end
    return current
end

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
