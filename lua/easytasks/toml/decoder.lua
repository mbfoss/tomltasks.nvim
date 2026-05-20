-- easytasks/toml/decoder.lua
local parser = require("easytasks.toml.parser")

local M = {}

local function escape_for_path(token)
    return (tostring(token)
        :gsub("~", "~0")
        :gsub("/", "~1"))
end

---@param base string
---@param key string
---@return string -- JSON Pointer (defined in RFC 6901)
local function join(base, key)
    local escaped = escape_for_path(key)
    if base == "" or base == "/" then
        return "/" .. escaped
    end
    return base .. "/" .. escaped
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
                local item_path = join(path, tostring(index - 1))
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
                local pair_path = join(path, key)

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
                local next_path = join(current_path, key)
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

            -- key = value
        elseif node.kind == "KeyValuePair" then
            -- Fallback protection for incomplete key value structural segments
            if not node.value or not node.key then
                return true -- Keep walking
            end

            local key = node.key.value
            local path = join(current_path, key)
            local existing_kind = path_kinds[path]

            if existing_kind then
                local msg = "Duplicate key: " .. key
                if existing_kind == "Table" then
                    msg = "Cannot overwrite table structure with key: " .. key
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
        elseif node.kind == "PartialTableSection" or node.kind == "PartialKeyValuePair" then
            -- Intentional no-op: Ignore non-evaluated intermediate fragments safely
        end

        return true -- Continue walking to subsequent nodes
    end)

    return root, pointer_map, errors
end

---@param input string|table
function M.decode(input)
    local ast

    if type(input) == "string" then
        local parsed = parser.parse(input)

        if not parsed.ok then
            return {
                ok = false,
                data = nil,
                errors = parsed.errors,
                pointer_map = {},
            }
        end

        ast = parsed.ast
    else
        ast = input
    end

    local data, pointer_map, errors = evaluate(ast)

    if #errors > 0 then
        return {
            ok = false,
            data = nil,
            errors = errors,
            pointer_map = pointer_map,
        }
    end

    return {
        ok = true,
        data = data,
        errors = {},
        pointer_map = pointer_map,
    }
end

return M
