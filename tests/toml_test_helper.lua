-- tests/toml_test_helper.lua
-- Converts decoded TOML data into the tagged-JSON format expected by toml-test.
-- Uses decoder.decode with opts.type_map=true to get path→literalkind mapping.

local decoder = require("easytasks.toml.decoder")
local vu      = require("easytasks.toml.validatorutils")

local M       = {}

local function tagged_from_data(data, path, type_map)
    local t = type_map[path]

    if t == "array" then
        local arr = {}
        for i, item in ipairs(data) do
            table.insert(arr, tagged_from_data(item, vu.join_path(path, tostring(i)), type_map))
        end
        return arr
    elseif t == "table" then
        local tbl = vim.empty_dict()
        for k, v in pairs(data) do
            tbl[k] = tagged_from_data(v, vu.join_path(path, k), type_map)
        end
        return tbl
    elseif t == "string" then
        return { type = "string", value = data }
    elseif t == "bool" then
        return { type = "bool", value = tostring(data) }
    elseif t == "integer" then
        return { type = "integer", value = tostring(math.floor(data)) }
    elseif t == "float" then
        if data ~= data then
            return { type = "float", value = "nan" }
        elseif data == math.huge then
            return { type = "float", value = "inf" }
        elseif data == -math.huge then
            return { type = "float", value = "-inf" }
        else
            return { type = "float", value = string.format("%.17g", data) }
        end
    elseif t then
        -- "datetime", "datetime-local", "date-local", "time-local" — value is already a string
        return { type = t, value = data }
    end

    return vim.NIL
end

function M.parse_to_tagged_json(toml_str)
    local result = decoder.decode(toml_str, { type_map = true, strict = true })

    if not result.ok then
        local msgs = {}
        for _, e in ipairs(result.errors) do
            table.insert(msgs, e.message)
        end
        return nil, table.concat(msgs, "; ")
    end

    return vim.json.encode(tagged_from_data(result.data, "", result.type_map)), nil
end

return M
