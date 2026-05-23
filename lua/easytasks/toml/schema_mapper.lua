local M = {}

local utils     = require('easytasks.toml.validatorutils')
local validator = require('easytasks.toml.validator')

local EXCLUDED_KEYS = { "if", "then", "else", "allOf", "oneOf" }

---@param dt     easytasks.toml.DecodeTree
---@param path   string
---@param schema table
---@param data   any
local function _populate(dt, path, schema, data)
    local existing = dt:get_schema(path) or {}
    utils.deep_merge_tables(existing, schema)
    for _, key in ipairs(EXCLUDED_KEYS) do existing[key] = nil end
    dt:set_schema(path, existing)

    if schema.type == "object" or (type(schema.type) == "table" and vim.tbl_contains(schema.type, "object")) then
        if type(data) == "table" and not vim.islist(data) then
            local props        = schema.properties or {}
            local pattern_props = schema.patternProperties or {}

            for key, subschema in pairs(props) do
                if data[key] ~= nil then
                    _populate(dt, utils.join_path(path, key), subschema, data[key])
                end
            end

            local addl = schema.additionalProperties
            for key, value in pairs(data) do
                local handled = props[key] ~= nil
                for pattern, subschema in pairs(pattern_props) do
                    if type(key) == "string" and key:match(pattern) then
                        handled = true
                        _populate(dt, utils.join_path(path, key), subschema, value)
                    end
                end
                if not handled and type(addl) == "table" then
                    _populate(dt, utils.join_path(path, key), addl, value)
                end
            end
        end
    end

    if schema.type == "array" or (type(schema.type) == "table" and vim.tbl_contains(schema.type, "array")) then
        if vim.islist(data) and schema.items then
            for i, value in ipairs(data) do
                _populate(dt, utils.join_path(path, tostring(i)), schema.items, value)
            end
        end
    end

    if schema["if"] then
        local ok = validator.validate(schema["if"], data)
        if ok then
            if schema["then"] then _populate(dt, path, schema["then"], data) end
        else
            if schema["else"] then _populate(dt, path, schema["else"], data) end
        end
    end

    if schema.allOf then
        for _, sub in ipairs(schema.allOf) do
            _populate(dt, path, sub, data)
        end
    end

    if schema.oneOf then
        local best_sub, best_count = nil, math.huge
        for _, sub in ipairs(schema.oneOf) do
            local _, errs = validator.validate(sub, data)
            if #errs < best_count then
                best_count = #errs
                best_sub   = sub
            end
            if best_count == 0 then break end
        end
        if best_sub then
            _populate(dt, path, best_sub, data)
        end
    end
end

-- Populate schema references on the nodes of an existing DecodeTree.
-- Each node's .schema field receives the merged schema fragment for that path.
---@param schema table
---@param data   any
---@param dt     easytasks.toml.DecodeTree
function M.populate(schema, data, dt)
    _populate(dt, "/", schema, data)
end

return M
