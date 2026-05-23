local parser     = require("easytasks.toml.parser")
local DecodeTree = require("easytasks.toml.DecodeTree")
local vu         = require("easytasks.toml.validatorutils")
local NodeKind = require("easytasks.toml.parser_util").NodeKind

local M          = {}

---@param ast easytasks.toml.Ast
---@param with_type_map boolean?
---@return any                       data
---@return easytasks.toml.DecodeTree decode_tree
---@return table[]                   errors
---@return table<string,string>?     value_types  path → TOML type, only when with_type_map is true
local function evaluate(ast, with_type_map)
    local root        = vim.empty_dict()
    local dt          = DecodeTree.new()
    local errors      = {}
    local path_kinds  = {}
    local value_types = with_type_map and {} or nil
    local function set_type(p, t) if value_types then value_types[p] = t end end
    local function add_err(e) table.insert(errors, e) end

    local dead_end_table    = vim.empty_dict()
    local current_table     = root
    local current_path      = ""
    local inline_table_paths = {}
    local dotted_key_paths  = {}

    dt:set_range("", { 0, 0, 0, 0 })
    path_kinds[""] = "Table"
    set_type("", "table")

    local eval_value
    eval_value = function(node, path)
        if not node then return nil end

        if node.kind == NodeKind.Literal then
            path_kinds[path] = "Literal"
            local v = node.token.value
            set_type(path, node.token.literalkind)
            return v
        elseif node.kind == NodeKind.Array then
            path_kinds[path] = "Array"
            set_type(path, "array")
            local result = {}
            for index, item_node in ipairs(node.items) do
                local item_path = vu.join_path(path, tostring(index))
                local val = eval_value(item_node, item_path)
                table.insert(result, val)
                dt:set_range(item_path, item_node.range)
            end
            return result
        elseif node.kind == NodeKind.InlineTable then
            path_kinds[path] = "Table"
            set_type(path, "table")
            if node.explicit then inline_table_paths[path] = true
            else dotted_key_paths[path] = true end
            local result = vim.empty_dict()
            for _, pair in ipairs(node.pairs) do
                local key       = pair.key.value
                local pair_path = vu.join_path(path, key)
                if result[key] ~= nil then
                    add_err({
                        message = "Duplicate key in inline table: " .. key,
                        range   = pair.key.range or pair.value.range,
                    })
                else
                    local val = eval_value(pair.value, pair_path)
                    result[key] = val
                    dt:set_range(pair_path, {
                        pair.key.range[1], pair.key.range[2],
                        pair.value.range[3], pair.value.range[4],
                    })
                end
            end
            return result
        end

        return nil
    end

    -- Deeply merges inline values produced by sequential dotted-key definitions
    local function merge_values(target_tbl, incoming_val, path)
        if type(target_tbl) == "table" and type(incoming_val) == "table" and path_kinds[path] == "Table" then
            for k, v in pairs(incoming_val) do
                local sub_path = vu.join_path(path, k)
                if target_tbl[k] ~= nil then
                    merge_values(target_tbl[k], v, sub_path)
                else
                    target_tbl[k] = v
                end
            end
        else
            add_err({
                message = "Duplicate key definition structure conflict at: " .. path,
                range   = { 0, 0, 0, 0 }
            })
        end
    end

    local function process_kvp(node)
        if not node.key or not node.value then return end
        local key           = node.key.value
        local path          = vu.join_path(current_path, key)
        local existing_kind = path_kinds[path]

        if existing_kind then
            if existing_kind == "Table" and node.value.kind == NodeKind.InlineTable then
                if inline_table_paths[path] then
                    add_err({ message = "Cannot extend inline table: " .. key, range = node.key.range or node.range })
                elseif node.value.explicit then
                    add_err({ message = "Cannot redefine implicit table as inline table: " .. key, range = node.key.range or node.range })
                else
                    local fresh_val = eval_value(node.value, path)
                    merge_values(current_table[key], fresh_val, path)
                    dt:set_range(path, node.range)
                end
            else
                local msg = "Duplicate key: " .. key
                if existing_kind == "Table" then
                    msg = "Cannot overwrite table structure with key: " .. key
                elseif existing_kind == "ArrayOfTables" then
                    msg = "Cannot overwrite array of tables structure with key: " .. key
                end
                add_err({ message = msg, range = node.key.range or node.range })
            end
        else
            current_table[key] = eval_value(node.value, path)
            dt:set_range(path, node.range)
        end
    end

    for _, root_item in ipairs(ast:get_roots()) do
        local id   = root_item.id
        local node = root_item.data

        if node.kind == NodeKind.TableSection then
            current_table = root
            current_path  = ""
            local invalid = false

            for _, key_token in ipairs(node.keys) do
                local key       = key_token.value
                local next_path = vu.join_path(current_path, key)
                local kind      = path_kinds[next_path]

                if kind == "ArrayOfTables" then
                    local arr          = current_table[key]
                    local idx          = #arr
                    local arr_idx_path = vu.join_path(next_path, tostring(idx))
                    current_table      = arr[idx]
                    current_path       = arr_idx_path
                    dt:set_range(next_path, key_token.range or node.range)
                elseif kind and kind ~= "Table" then
                    add_err({
                        message = "Cannot redefine non-table target: " .. key,
                        range   = key_token.range or node.range,
                    })
                    invalid = true
                    break
                else
                    if inline_table_paths[next_path] then
                        add_err({
                            message = "Cannot extend inline table with table header: " .. key,
                            range   = key_token.range or node.range,
                        })
                        invalid = true
                        break
                    end
                    if current_table[key] == nil then
                        current_table[key] = vim.empty_dict()
                        path_kinds[next_path] = "Table"
                    end
                    set_type(next_path, "table")

                    current_table = current_table[key]
                    current_path  = next_path
                    dt:set_range(next_path, key_token.range or node.range)
                end
            end

            if not invalid and dotted_key_paths[current_path] then
                add_err({ message = "Cannot redefine table created by dotted key: " .. current_path, range = node.range })
                invalid = true
            end

            if invalid then
                current_table = dead_end_table
                current_path  = "/_error_sink"
            end

            for _, child in ipairs(ast:get_children(id)) do
                if child.data.kind == NodeKind.KeyValuePair then
                    process_kvp(child.data)
                end
            end
        elseif node.kind == NodeKind.ArrayOfTablesSection then
            current_table  = root
            current_path   = ""
            local invalid  = false
            local num_keys = #node.keys

            for i, key_token in ipairs(node.keys) do
                local key       = key_token.value
                local next_path = vu.join_path(current_path, key)
                local is_last   = (i == num_keys)

                if is_last then
                    local kind = path_kinds[next_path]
                    if kind and kind ~= "ArrayOfTables" then
                        add_err({
                            message = "Cannot redefine non-array target as array of tables: " .. key,
                            range   = key_token.range or node.range,
                        })
                        invalid = true
                        break
                    end

                    if current_table[key] == nil then
                        current_table[key] = {}
                        path_kinds[next_path] = "ArrayOfTables"
                    end
                    set_type(next_path, "array")

                    local tbl_arr  = current_table[key]
                    local next_tbl = vim.empty_dict()
                    table.insert(tbl_arr, next_tbl)

                    local arr_idx_path       = vu.join_path(next_path, tostring(#tbl_arr))
                    path_kinds[arr_idx_path] = "Table"
                    set_type(arr_idx_path, "table")
                    dt:set_range(arr_idx_path, key_token.range or node.range)

                    current_table = next_tbl
                    current_path  = arr_idx_path
                else
                    local kind = path_kinds[next_path]
                    if kind == "ArrayOfTables" then
                        local arr          = current_table[key]
                        local idx          = #arr
                        local arr_idx_path = vu.join_path(next_path, tostring(idx))
                        current_table      = arr[idx]
                        current_path       = arr_idx_path
                    elseif kind and kind ~= "Table" then
                        add_err({
                            message = "Cannot redefine non-table structural ancestor: " .. key,
                            range   = key_token.range or node.range,
                        })
                        invalid = true
                        break
                    else
                        if inline_table_paths[next_path] then
                            add_err({
                                message = "Cannot extend inline table with array-of-tables header: " .. key,
                                range   = key_token.range or node.range,
                            })
                            invalid = true
                            break
                        end
                        if current_table[key] == nil then
                            current_table[key] = vim.empty_dict()
                            path_kinds[next_path] = "Table"
                        end
                        set_type(next_path, "table")

                        current_table = current_table[key]
                        current_path  = next_path
                    end
                end

                dt:set_range(next_path, key_token.range or node.range)
            end

            if invalid then
                current_table = dead_end_table
                current_path  = "/_error_sink"
            end

            for _, child in ipairs(ast:get_children(id)) do
                if child.data.kind == NodeKind.KeyValuePair then
                    process_kvp(child.data)
                end
            end
        elseif node.kind == NodeKind.KeyValuePair then
            process_kvp(node)
        end
    end

    return root, dt, errors, value_types
end

function M.decode(input, opts)
    local ast

    if type(input) == "string" then
        local parsed = parser.parse(input)

        if not parsed.ok then
            return {
                ok          = false,
                data        = nil,
                errors      = parsed.errors,
                decode_tree = DecodeTree.new(),
            }
        end

        ast = parsed.ast
    else
        ast = input
    end

    local data, dt, errors, value_types = evaluate(ast, opts and opts.type_map)

    if #errors > 0 then
        return {
            ok          = false,
            data        = nil,
            errors      = errors,
            decode_tree = dt,
        }
    end

    return {
        ok          = true,
        data        = data,
        errors      = {},
        decode_tree = dt,
        type_map    = (opts and opts.type_map) and value_types or nil,
    }
end

return M
