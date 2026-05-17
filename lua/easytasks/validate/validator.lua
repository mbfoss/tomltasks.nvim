local M = {}

local utils = require('easytasks.validate.validatorutils')

---@param errors loop.json.ValidationError[]
---@param path string -- path is a JSON Pointer (defined in RFC 6901)
---@param msg string
local function add_error(errors, path, msg)
    table.insert(errors, {
        path = path,
        err_msg = msg,
    })
end

local function deep_equal(a, b)
    if a == b then return true end
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return false end
    for k, v in pairs(a) do if not deep_equal(v, b[k]) then return false end end
    for k, v in pairs(b) do if not deep_equal(v, a[k]) then return false end end
    return true
end
local function check_enum(enum_tbl, value)
    for _, v in ipairs(enum_tbl) do
        if v == value then
            return true
        end
    end
    return false
end

---@class loop.json.ValidationError
---@field path string
---@field err_msg string
---@param schema table
---@param data any
---@param path string
---@param errors loop.json.ValidationError[]
---@param schema_map table<string, table>?
local function _validate(schema, data, path, errors, schema_map)
    if schema_map then
        local map = schema_map[path] or {}
        utils.deep_merge_tables(map, schema)
        schema_map[path] = map
        for _, key in ipairs({ "if", "then", "else", "allOf", "oneOf" }) do
            map[key] = nil
        end
    end
    local allowed_types = type(schema.type) == "table" and schema.type or { schema.type }
    if allowed_types and not vim.tbl_isempty(allowed_types) then
        local ok = false
        for _, t in ipairs(allowed_types) do
            if t == "null" and data == nil then
                ok = true
            elseif t == "object" and type(data) == "table" and not vim.islist(data) then
                ok = true
            elseif t == "array" and vim.islist(data) then
                ok = true
            elseif t == "string" and type(data) == "string" then
                ok = true
            elseif t == "number" and type(data) == "number" then
                ok = true
            elseif t == "boolean" and type(data) == "boolean" then
                ok = true
            end
            if ok then break end
        end

        if not ok then
            local expected = table.concat(allowed_types, " or ")
            ---@type string
            local got = type(data)
            if got == "table" then
                got = vim.islist(data) and "array" or "object"
            elseif data == nil then
                got = "null"
            end
            add_error(errors, path, ("expected %s, got %s"):format(expected, got))
        end
    end
    if schema.enum and not check_enum(schema.enum, data) then
        local enum_strs = {}
        for _, v in ipairs(schema.enum) do
            table.insert(enum_strs, tostring(v))
        end
        add_error(errors, path, "valid values: " .. table.concat(enum_strs, ", "))
    end
    if schema.const ~= nil then
        if not deep_equal(data, schema.const) then
            add_error(
                errors,
                path,
                ("expecting %s, got %s"):format(tostring(schema.const), tostring(data))
            )
        end
    end
    if schema.type == "object" or (type(schema.type) == "table" and vim.tbl_contains(schema.type, "object")) then
        if type(data) ~= "table" or vim.islist(data) then
            add_error(errors, path, "expected object")
        else
            local props = schema.properties or {}
            local required = schema.required or {}
            local pattern_props = schema.patternProperties or {}

            local missing
            for _, key in ipairs(required) do
                if data[key] == nil then
                    missing = missing or {}
                    table.insert(missing, key)
                end
            end
            if missing then
                add_error(errors, path,
                    ("required propert%s missing: %s"):format(#missing == 1 and "y" or "ies", table.concat(missing, ', ')))
            end

            for key, subschema in pairs(props) do
                if data[key] ~= nil then
                    _validate(subschema, data[key], utils.join_path(path, key), errors, schema_map)
                end
            end

            local addl = schema.additionalProperties
            for key, value in pairs(data) do
                local handled = props[key] ~= nil
                for pattern, subschema in pairs(pattern_props) do
                    if type(key) == "string" and key:match(pattern) then
                        handled = true
                        _validate(subschema, value, utils.join_path(path, key), errors, schema_map)
                    end
                end
                if not handled then
                    if addl == false then
                        add_error(errors, utils.join_path(path, key), "invalid property name")
                    elseif type(addl) == "table" then
                        _validate(addl, value, utils.join_path(path, key), errors, schema_map)
                    end
                end
            end
        end
    end
    if schema.type == "array" or (type(schema.type) == "table" and vim.tbl_contains(schema.type, "array")) then
        if not vim.islist(data) then
            add_error(errors, path, "expected array")
        else
            if schema.items then
                for i, value in ipairs(data) do
                    _validate(schema.items, value, utils.join_path(path, tostring(i)), errors, schema_map)
                end
            end
        end
    end
    if schema.pattern and type(data) == "string" and not data:match(schema.pattern) then
        add_error(errors, path, ("string does not match pattern %q"):format(schema.pattern))
    end
    if type(schema.minLength) == "number" and type(data) == "string" and #data < schema.minLength then
        local err = schema.minLength > 1 and ("string must be at least %d character"):format(schema.minLength) or
            "string cannot be empty"
        add_error(errors, path, err)
    end
    if schema["if"] then
        local tmp_errors = {}
        _validate(schema["if"], data, path, tmp_errors, nil)
        if #tmp_errors == 0 then
            if schema["then"] then
                _validate(schema["then"], data, path, errors, schema_map)
            end
        else
            if schema["else"] then
                _validate(schema["else"], data, path, errors, schema_map)
            end
        end
    end
    if schema.allOf then
        local count = #errors
        for _, sub in ipairs(schema.allOf) do
            if #errors ~= count then break end
            _validate(sub, data, path, errors, schema_map)
        end
    end
    if schema.oneOf then
        local best_errors = nil
        local best_count = math.huge
        local best_schema_map

        for _, sub in ipairs(schema.oneOf) do
            local tmp_errors = {}
            local tmp_schema_map = schema_map and {}
            _validate(sub, data, path, tmp_errors, tmp_schema_map)
            local count = #tmp_errors
            if count < best_count then
                best_count = count
                best_errors = tmp_errors
                best_schema_map = tmp_schema_map
            end
            if best_count == 0 then
                break
            end
        end
        if schema_map and best_schema_map then
            utils.deep_merge_tables(schema_map, best_schema_map)
        end
        if best_count > 0 and best_errors then
            vim.list_extend(errors, best_errors)
        end
    end
end

---@param schema table
---@param data any
---@param opts {build_schema_map:boolean?}?
---@return boolean valid
---@return loop.json.ValidationError[] errors
---@return table<string, table>? schema map
function M.validate(schema, data, opts)
    opts = opts or {}
    local schema_map
    if opts.build_schema_map then
        schema_map = {}
    end
    local errors = {}
    _validate(schema, data, "/", errors, schema_map)
    return #errors == 0, errors, schema_map
end

---@param errors loop.json.ValidationError[]
---@return string
function M.errors_to_string(errors)
    local err = {}
    for _, e in ipairs(errors) do
        table.insert(err, e.path .. ": " .. e.err_msg)
    end
    return table.concat(err, '\n')
end

---@param errors loop.json.ValidationError[]
---@return string[]
function M.errors_to_string_arr(errors)
    local ret = {}
    for _, e in ipairs(errors) do
        table.insert(ret, e.path .. ": " .. e.err_msg)
    end
    return ret
end

return M
