local M          = {}

local parser     = require("easytasks.toml.parser")
local DecodeTree = require("easytasks.toml.DecodeTree")
local Ast        = require("easytasks.toml.Ast")

local NodeKind   = Ast.NodeKind

---@param ast easytasks.toml.Ast
---@param with_type_map boolean?
---@return any                       data
---@return easytasks.toml.DecodeTree decode_tree
---@return table[]                   errors
---@return table<integer,string>?    value_types  node_id → TOML type, only when with_type_map is true
local function evaluate(ast, with_type_map)
    local root       = vim.empty_dict()
    local dt         = DecodeTree.new()
    local errors     = {}
    local kind_by_id = {}
    local type_by_id = with_type_map and {} or nil
    local function set_type(id, t) if type_by_id then type_by_id[id] = t end end
    local function add_err(e) table.insert(errors, e) end

    local dead_end_table     = vim.empty_dict()
    local current_table      = root
    local inline_table_ids   = {}
    local dotted_key_ids     = {}
    local explicit_table_ids = {}

    local root_id            = dt:root_id()
    dt:add_range_by_id(root_id, { 0, 0, 0, 0 })
    kind_by_id[root_id] = "Table"
    set_type(root_id, "table")

    ---@type integer?
    local current_id = root_id

    local eval_value
    eval_value = function(node, id)
        if not node then return nil end

        if node.kind == NodeKind.Literal then
            kind_by_id[id] = "Literal"
            set_type(id, node.token.literalkind)
            return node.token.value
        elseif node.kind == NodeKind.Array then
            kind_by_id[id] = "Array"
            set_type(id, "array")
            local result = {}
            for _, item_node in ipairs(node.items) do
                if item_node.kind ~= NodeKind.Comment then
                    local index   = #result + 1
                    local item_id = dt:add_child(id, tostring(index), item_node.range)
                    table.insert(result, eval_value(item_node, item_id))
                end
            end
            return result
        elseif node.kind == NodeKind.InlineTable then
            kind_by_id[id] = "Table"
            set_type(id, "table")
            if node.explicit then
                inline_table_ids[id] = true
            else
                dotted_key_ids[id] = true
            end
            local result = vim.empty_dict()
            for _, pair in ipairs(node.pairs) do
                local key = pair.key.value
                if result[key] ~= nil then
                    add_err({
                        message = "Duplicate key in inline table: " .. key,
                        range   = pair.key.range or pair.value.range,
                    })
                else
                    local pair_range = pair.value and {
                        pair.key.range[1], pair.key.range[2],
                        pair.value.range[3], pair.value.range[4],
                    } or pair.key.range
                    local found_id   = dt:get_child_id(id, key)
                    local pair_id    = found_id or dt:add_child(id, key, pair_range)
                    if found_id then dt:add_range_by_id(pair_id, pair_range) end
                    if pair.value == nil then dt:mark_as_key_node(pair_id) end
                    result[key] = eval_value(pair.value, pair_id)
                end
            end
            return result
        end

        return nil
    end

    local function merge_values(target_tbl, incoming_val, id)
        if explicit_table_ids[id] then
            add_err({ message = "Cannot extend explicitly-defined table via dotted keys", range = dt:range_of_id(id) })
            return
        end
        if type(target_tbl) == "table" and type(incoming_val) == "table" and kind_by_id[id] == "Table" then
            for k, v in pairs(incoming_val) do
                local sub_id = dt:get_child_id(id, k)
                if target_tbl[k] ~= nil and sub_id then
                    merge_values(target_tbl[k], v, sub_id)
                else
                    target_tbl[k] = v
                end
            end
        else
            add_err({ message = "Duplicate key definition structure conflict", range = dt:range_of_id(id) })
        end
    end

    local function full_section_range(ast_id, header_node)
        local r = header_node.range or { 0, 0, 0, 0 }
        local er, ec = r[3], r[4]
        for _, child in ast:iter_children(ast_id) do
            if child.range and (child.range[3] > er or (child.range[3] == er and child.range[4] > ec)) then
                er, ec = child.range[3], child.range[4]
            end
        end
        return { r[1], r[2], er, ec }
    end

    local function process_kvp(node)
        if not current_id then return end
        if not node.key or not node.value then return end
        local key           = node.key.value
        local existing_id   = dt:get_child_id(current_id, key)
        local existing_kind = existing_id and kind_by_id[existing_id]

        if existing_id and existing_kind then
            if existing_kind == "Table" and node.value.kind == NodeKind.InlineTable then
                if inline_table_ids[existing_id] then
                    add_err({ message = "Cannot extend inline table: " .. key, range = node.key.range or node.range })
                elseif node.value.explicit then
                    add_err({
                        message = "Cannot redefine implicit table as inline table: " .. key,
                        range = node.key
                            .range or node.range
                    })
                else
                    local fresh_val = eval_value(node.value, existing_id)
                    merge_values(current_table[key], fresh_val, existing_id)
                    dt:add_range_by_id(existing_id, node.range)
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
            local child_id = dt:add_child(current_id, key, node.range)
            current_table[key] = eval_value(node.value, child_id)
        end
    end

    for _, root_item in ipairs(ast:get_roots()) do
        local id   = root_item.id
        local node = root_item.data

        if node.kind == NodeKind.TableSection then
            current_table = root
            current_id    = dt:root_id()
            local invalid = false

            local nkeys        = #node.keys
            local section_range = full_section_range(id, node)
            for i, key_token in ipairs(node.keys) do
                if not current_id then
                    invalid = true; break
                end
                local key      = key_token.value
                local next_id  = dt:get_child_id(current_id, key)
                local kind     = next_id and kind_by_id[next_id]
                local key_range = (i == nkeys) and section_range or (key_token.range or node.range)

                if kind == "ArrayOfTables" then
                    if i == nkeys then
                        add_err({
                            message = "Cannot use table header for array-of-tables key: " .. key,
                            range   = key_token.range or node.range,
                        })
                        invalid = true
                        break
                    end
                    assert(next_id)
                    local arr         = current_table[key]
                    local idx         = #arr
                    local arr_elem_id = dt:get_child_id(next_id, tostring(idx))
                    if not arr_elem_id then
                        invalid = true; break
                    end
                    current_table = arr[idx]
                    current_id    = arr_elem_id
                    dt:add_range_by_id(next_id, key_token.range or node.range)
                elseif kind and kind ~= "Table" then
                    add_err({
                        message = "Cannot redefine non-table target: " .. key,
                        range   = key_token.range or node.range,
                    })
                    invalid = true
                    break
                else
                    if next_id and inline_table_ids[next_id] then
                        add_err({
                            message = "Cannot extend inline table with table header: " .. key,
                            range   = key_token.range or node.range,
                        })
                        invalid = true
                        break
                    end
                    if not next_id then
                        current_table[key] = vim.empty_dict()
                        next_id = dt:add_child(current_id, key, key_range)
                        kind_by_id[next_id] = "Table"
                    else
                        dt:add_range_by_id(next_id, key_range)
                    end
                    set_type(next_id, "table")
                    current_table = current_table[key]
                    current_id    = next_id
                end
            end

            if not invalid and current_id then
                if explicit_table_ids[current_id] then
                    add_err({ message = "Duplicate table header", range = node.range })
                    invalid = true
                elseif dotted_key_ids[current_id] then
                    add_err({ message = "Cannot redefine table created by dotted key", range = node.range })
                    invalid = true
                else
                    explicit_table_ids[current_id] = true
                end
            end

            if invalid then
                current_table = dead_end_table
                current_id    = nil
            end

            for _, data in ast:iter_children(id) do
                if data.kind == NodeKind.KeyValuePair then
                    process_kvp(data)
                end
            end
        elseif node.kind == NodeKind.ArrayOfTablesSection then
            current_table  = root
            current_id     = dt:root_id()
            local invalid  = false
            local num_keys = #node.keys
            local section_range = full_section_range(id, node)

            for i, key_token in ipairs(node.keys) do
                if not current_id then
                    invalid = true; break
                end
                local key     = key_token.value
                local is_last = (i == num_keys)
                local next_id = dt:get_child_id(current_id, key)
                local kind    = next_id and kind_by_id[next_id]

                if is_last then
                    if kind and kind ~= "ArrayOfTables" then
                        add_err({
                            message = "Cannot redefine non-array target as array of tables: " .. key,
                            range   = key_token.range or node.range,
                        })
                        invalid = true
                        break
                    end

                    if not next_id then
                        current_table[key] = {}
                        next_id = dt:add_child(current_id, key, section_range)
                        kind_by_id[next_id] = "ArrayOfTables"
                    else
                        dt:add_range_by_id(next_id, section_range)
                    end
                    set_type(next_id, "array")

                    local tbl_arr  = current_table[key]
                    local next_tbl = vim.empty_dict()
                    table.insert(tbl_arr, next_tbl)

                    local arr_elem_id = dt:add_child(next_id, tostring(#tbl_arr), section_range)
                    kind_by_id[arr_elem_id] = "Table"
                    set_type(arr_elem_id, "table")

                    current_table = next_tbl
                    current_id    = arr_elem_id
                else
                    if kind == "ArrayOfTables" then
                        assert(next_id)
                        local arr         = current_table[key]
                        local idx         = #arr
                        local arr_elem_id = dt:get_child_id(next_id, tostring(idx))
                        if not arr_elem_id then
                            invalid = true; break
                        end
                        current_table = arr[idx]
                        current_id    = arr_elem_id
                    elseif kind and kind ~= "Table" then
                        add_err({
                            message = "Cannot redefine non-table structural ancestor: " .. key,
                            range   = key_token.range or node.range,
                        })
                        invalid = true
                        break
                    else
                        if next_id and inline_table_ids[next_id] then
                            add_err({
                                message = "Cannot extend inline table with array-of-tables header: " .. key,
                                range   = key_token.range or node.range,
                            })
                            invalid = true
                            break
                        end
                        if not next_id then
                            current_table[key] = vim.empty_dict()
                            next_id = dt:add_child(current_id, key, key_token.range or node.range)
                            kind_by_id[next_id] = "Table"
                        end
                        set_type(next_id, "table")
                        current_table = current_table[key]
                        current_id    = next_id
                    end
                    if next_id then dt:add_range_by_id(next_id, key_token.range or node.range) end
                end
            end

            if invalid then
                current_table = dead_end_table
                current_id    = nil
            end

            for _, data in ast:iter_children(id) do
                if data.kind == NodeKind.KeyValuePair then
                    process_kvp(data)
                end
            end
        elseif node.kind == NodeKind.KeyValuePair then
            process_kvp(node)
        end
    end

    local value_types
    if with_type_map and type_by_id then
        value_types = {}
        for tid, t in pairs(type_by_id) do
            value_types[tid] = t
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
