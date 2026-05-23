-- easytasks/toml/decoder.lua
local parser = require("easytasks.toml.parser")
local Tree = require("easytasks.util.Tree")
local vu = require("easytasks.toml.validatorutils")

local M = {}

local function build_location(pointer_map)
    local location_tree = Tree.new()
    local id_counter = 0
    local path_to_id = {}
    local id_to_range = {}

    local paths = {}
    for path in pairs(pointer_map) do
        table.insert(paths, path)
    end
    table.sort(paths, function(a, b)
        return select(2, a:gsub("/", "")) < select(2, b:gsub("/", ""))
    end)

    for _, path in ipairs(paths) do
        id_counter = id_counter + 1
        local id = id_counter
        path_to_id[path] = id
        id_to_range[id] = pointer_map[path]

        local parent_id, key
        if path == "/" then
            key = "/"
        else
            local parts = vu.split_path(path)
            key = parts[#parts]
            local parent_path = #parts > 1 and vu.join_path_parts(vim.list_slice(parts, 1, #parts - 1)) or "/"
            parent_id = path_to_id[parent_path]
        end

        location_tree:add_item(parent_id, id, key)
    end

    local function pos_to_location(row, col)
        local best_path, best_depth = nil, -1
        for path, id in pairs(path_to_id) do
            local r = id_to_range[id]
            if r then
                local after_start = row > r[1] or (row == r[1] and col >= r[2])
                local before_end  = row < r[3] or (row == r[3] and col <= r[4])
                if after_start and before_end then
                    local depth = location_tree:get_depth(id)
                    if depth > best_depth then
                        best_depth = depth
                        best_path  = path
                    end
                end
            end
        end
        return best_path
    end

    local function location_to_pos(path)
        local id = path_to_id[path]
        return id and id_to_range[id] or nil
    end

    return location_tree, pos_to_location, location_to_pos
end

local function evaluate(ast)
    -- Initialize the root table context as an empty dict right away
    local root = vim.empty_dict()
    local pointer_map = {}
    local errors = {}
    local path_kinds = {}

    -- Fallback dummy context to catch orphaned properties during invalid sections
    local dead_end_table = vim.empty_dict()
    local current_table = root
    local current_path = ""

    pointer_map["/"] = { 0, 0, 0, 0 }
    path_kinds["/"] = "Table"

    -- Forward declaration to allow mutually recursive evaluation of arrays and inline tables
    local eval_value

    eval_value = function(node, path)
        if not node then return nil end

        if node.kind == "Literal" then
            path_kinds[path] = "Literal"
            return node.token.value
        elseif node.kind == "Array" then
            path_kinds[path] = "Array"
            local result = {}
            for index, item_node in ipairs(node.items) do
                local item_path = vu.join_path(path, tostring(index))
                local val = eval_value(item_node, item_path)
                table.insert(result, val)
                pointer_map[item_path] = item_node.range
            end
            return result
        elseif node.kind == "InlineTable" then
            path_kinds[path] = "Table"

            -- Instantiate empty inline tables instantly
            local result = vim.empty_dict()
            for _, pair in ipairs(node.pairs) do
                local key = pair.key.value
                local pair_path = vu.join_path(path, key)

                if result[key] ~= nil then
                    table.insert(errors, {
                        message = "Duplicate key in inline table: " .. key,
                        range = pair.key.range or pair.value.range,
                    })
                else
                    local val = eval_value(pair.value, pair_path)
                    result[key] = val
                    pointer_map[pair_path] = {
                        pair.key.range[1],
                        pair.key.range[2],
                        pair.value.range[3],
                        pair.value.range[4],
                    }
                end
            end
            return result
        end

        return nil
    end

    -- Traverse the tree nodes using the Tree walker API instead of a flat list array
    ast:walk_tree(function(_, node, _)
        -- [table]
        if node.kind == "TableSection" then
            current_table = root
            current_path = ""

            local invalid = false

            for _, key_token in ipairs(node.keys) do
                local key = key_token.value
                local next_path = vu.join_path(current_path, key)
                local kind = path_kinds[next_path]

                if kind and kind ~= "Table" then
                    table.insert(errors, {
                        message = "Cannot redefine non-table target: " .. key,
                        range = key_token.range or node.range,
                    })
                    invalid = true
                    break
                end

                if current_table[key] == nil then
                    -- Instantiate missing block paths as vim.empty_dict() eagerly
                    current_table[key] = vim.empty_dict()
                    path_kinds[next_path] = "Table"
                end

                current_table = current_table[key]
                current_path = next_path

                pointer_map[next_path] = key_token.range or node.range
            end

            if invalid then
                current_table = dead_end_table
                current_path = "/_error_sink"
            end

            -- [[array_of_tables]]
        elseif node.kind == "ArrayOfTablesSection" then
            current_table = root
            current_path = ""

            local invalid = false
            local num_keys = #node.keys

            for i, key_token in ipairs(node.keys) do
                local key = key_token.value
                local next_path = vu.join_path(current_path, key)
                local is_last = (i == num_keys)

                if is_last then
                    -- The last key maps to an array containing tables
                    local kind = path_kinds[next_path]
                    if kind and kind ~= "ArrayOfTables" then
                        table.insert(errors, {
                            message = "Cannot redefine non-array target as array of tables: " .. key,
                            range = key_token.range or node.range,
                        })
                        invalid = true
                        break
                    end

                    if current_table[key] == nil then
                        current_table[key] = {}
                        path_kinds[next_path] = "ArrayOfTables"
                    end

                    -- Append a brand new table dictionary onto this array stack
                    local tbl_arr = current_table[key]
                    local next_tbl = vim.empty_dict()
                    table.insert(tbl_arr, next_tbl)

                    -- Update pointer mapping targeting this specific array element index
                    local arr_idx_path = vu.join_path(next_path, tostring(#tbl_arr))
                    path_kinds[arr_idx_path] = "Table"
                    pointer_map[arr_idx_path] = key_token.range or node.range

                    current_table = next_tbl
                    current_path = arr_idx_path
                else
                    -- Intermediate parent traversal paths must be dict tables
                    local kind = path_kinds[next_path]
                    if kind and kind ~= "Table" then
                        table.insert(errors, {
                            message = "Cannot redefine non-table structural ancestor: " .. key,
                            range = key_token.range or node.range,
                        })
                        invalid = true
                        break
                    end

                    if current_table[key] == nil then
                        current_table[key] = vim.empty_dict()
                        path_kinds[next_path] = "Table"
                    end

                    current_table = current_table[key]
                    current_path = next_path
                end

                pointer_map[next_path] = key_token.range or node.range
            end

            if invalid then
                current_table = dead_end_table
                current_path = "/_error_sink"
            end

            -- key = value
        elseif node.kind == "KeyValuePair" then
            -- Fallback protection for incomplete key value structural segments
            if not node.value or not node.key then
                return true -- Keep walking
            end

            local key = node.key.value
            local path = vu.join_path(current_path, key)
            local existing_kind = path_kinds[path]

            if existing_kind then
                local msg = "Duplicate key: " .. key
                if existing_kind == "Table" then
                    msg = "Cannot overwrite table structure with key: " .. key
                elseif existing_kind == "ArrayOfTables" then
                    msg = "Cannot overwrite array of tables structure with key: " .. key
                end

                table.insert(errors, {
                    message = msg,
                    range = node.key.range or node.range,
                })
            else
                local value = eval_value(node.value, path)
                current_table[key] = value
                pointer_map[path] = node.range
            end

            -- Skip any partial structures safely during evaluator analysis loops
        elseif node.kind == "PartialTableSection" or
            node.kind == "PartialArrayOfTablesSection" or
            node.kind == "PartialKeyValuePair" then
            -- Intentional no-op: Ignore non-evaluated intermediate fragments safely
        end

        return true -- Continue walking to subsequent nodes
    end)

    return root, pointer_map, errors
end

local function empty_location()
    return Tree.new(), function() return nil end, function() return nil end
end

---@param input string|table
function M.decode(input)
    local ast

    if type(input) == "string" then
        local parsed = parser.parse(input)

        if not parsed.ok then
            local location_tree, pos_to_location, location_to_pos = empty_location()
            return {
                ok = false,
                data = nil,
                errors = parsed.errors,
                location_tree = location_tree,
                pos_to_location = pos_to_location,
                location_to_pos = location_to_pos,
            }
        end

        ast = parsed.ast
    else
        ast = input
    end

    local data, pointer_map, errors = evaluate(ast)
    local location_tree, pos_to_location, location_to_pos = build_location(pointer_map)

    if #errors > 0 then
        return {
            ok = false,
            data = nil,
            errors = errors,
            location_tree = location_tree,
            pos_to_location = pos_to_location,
            location_to_pos = location_to_pos,
        }
    end

    return {
        ok = true,
        data = data,
        errors = {},
        location_tree = location_tree,
        pos_to_location = pos_to_location,
        location_to_pos = location_to_pos,
    }
end

return M
