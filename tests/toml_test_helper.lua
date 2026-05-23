-- tests/toml_test_helper.lua
-- Converts a parsed TOML AST into the tagged-JSON format expected by toml-test.
--
-- Types are inferred from the Lua values stored in the AST:
--   string  → "string"
--   boolean → "bool"
--   number, v%1==0 and finite → "integer"  (NB: TOML floats that are whole
--              numbers, e.g. 3.0, will be mis-tagged as "integer" because the
--              parser converts them to an indistinguishable Lua number.)
--   number, otherwise → "float"
--   date table with year+hour+zone → "datetime"
--   date table with year+hour, no zone → "datetime-local"
--   date table with year, no hour → "date-local"
--   date table with only hour → "time-local"

local parser   = require("easytasks.toml.parser")
local NodeKind = require("easytasks.toml.NodeKind")

local M = {}

-- ── date helpers ─────────────────────────────────────────────────────────────

local function date_toml_type(d)
    if d.year and d.hour ~= nil then
        return d.zone ~= nil and "datetime" or "datetime-local"
    elseif d.year then
        return "date-local"
    else
        return "time-local"
    end
end

-- ── value-node tagger ────────────────────────────────────────────────────────

local tag_node
tag_node = function(node)
    if not node then return vim.NIL end

    if node.kind == NodeKind.Literal then
        local v = node.token.value
        local t = type(v)

        if t == "string" then
            return { type = "string", value = v }

        elseif t == "boolean" then
            return { type = "bool", value = tostring(v) }

        elseif t == "number" then
            if v ~= v then                        -- nan
                return { type = "float", value = "nan" }
            elseif v == math.huge then            -- +inf
                return { type = "float", value = "inf" }
            elseif v == -math.huge then           -- -inf
                return { type = "float", value = "-inf" }
            elseif v % 1 == 0 then                -- whole → integer
                return { type = "integer", value = tostring(math.floor(v)) }
            else
                return { type = "float", value = string.format("%.17g", v) }
            end

        elseif t == "table" and parser.is_date(v) then
            return { type = date_toml_type(v), value = tostring(v) }
        end

        return vim.NIL

    elseif node.kind == NodeKind.Array then
        local arr = {}
        for _, item in ipairs(node.items) do
            table.insert(arr, tag_node(item))
        end
        return arr

    elseif node.kind == NodeKind.InlineTable then
        local tbl = vim.empty_dict()
        for _, pair in ipairs(node.pairs) do
            tbl[pair.key.value] = tag_node(pair.value)
        end
        return tbl
    end

    return vim.NIL
end

-- ── top-level AST traversal ───────────────────────────────────────────────────
-- Mirrors the decoder's evaluate() but emits tagged values instead of raw ones.

local function ast_to_tagged(ast)
    local root         = vim.empty_dict()
    local path_kinds   = {}
    local dead_end     = vim.empty_dict()
    local current_tbl  = root
    local current_path = ""

    local function kvp_key_path(key)
        return current_path == "" and key or (current_path .. "/" .. key)
    end

    local function process_kvp(node)
        if not node.key or not node.value then return end
        local key = node.key.value
        if current_tbl[key] ~= nil then return end  -- decoder would flag this; we skip
        current_tbl[key] = tag_node(node.value)
    end

    for _, root_item in ipairs(ast:get_roots()) do
        local id   = root_item.id
        local node = root_item.data

        if node.kind == NodeKind.TableSection then
            current_tbl  = root
            current_path = ""
            local invalid = false

            for _, key_tok in ipairs(node.keys) do
                local key = key_tok.value
                local next_path = current_path == "" and key or (current_path .. "/" .. key)
                local kind = path_kinds[next_path]

                if kind and kind ~= "Table" then
                    invalid = true; break
                end

                if current_tbl[key] == nil then
                    current_tbl[key] = vim.empty_dict()
                    path_kinds[next_path] = "Table"
                end

                current_tbl  = current_tbl[key]
                current_path = next_path
            end

            if invalid then
                current_tbl  = dead_end
                current_path = "/_error_sink"
            end

            for _, child in ipairs(ast:get_children(id)) do
                if child.data.kind == NodeKind.KeyValuePair then
                    process_kvp(child.data)
                end
            end

        elseif node.kind == NodeKind.ArrayOfTablesSection then
            current_tbl  = root
            current_path = ""
            local invalid  = false
            local num_keys = #node.keys

            for i, key_tok in ipairs(node.keys) do
                local key       = key_tok.value
                local next_path = current_path == "" and key or (current_path .. "/" .. key)
                local is_last   = (i == num_keys)

                if is_last then
                    local kind = path_kinds[next_path]
                    if kind and kind ~= "ArrayOfTables" then
                        invalid = true; break
                    end
                    if current_tbl[key] == nil then
                        current_tbl[key] = {}
                        path_kinds[next_path] = "ArrayOfTables"
                    end
                    local new_entry = vim.empty_dict()
                    table.insert(current_tbl[key], new_entry)

                    local idx_path = next_path .. "/" .. tostring(#current_tbl[key])
                    path_kinds[idx_path] = "Table"
                    current_tbl  = new_entry
                    current_path = idx_path
                else
                    local kind = path_kinds[next_path]
                    if kind and kind ~= "Table" then
                        invalid = true; break
                    end
                    if current_tbl[key] == nil then
                        current_tbl[key] = vim.empty_dict()
                        path_kinds[next_path] = "Table"
                    end
                    current_tbl  = current_tbl[key]
                    current_path = next_path
                end
            end

            if invalid then
                current_tbl  = dead_end
                current_path = "/_error_sink"
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

    return root
end

-- ── public API ────────────────────────────────────────────────────────────────

-- Parse a TOML string and return a toml-test compatible tagged JSON string.
-- Returns: json_string on success.
-- Returns: nil, error_message on failure.
function M.parse_to_tagged_json(toml_str)
    local result = parser.parse(toml_str)

    if not result.ok then
        local msgs = {}
        for _, e in ipairs(result.errors) do
            table.insert(msgs, e.message)
        end
        return nil, table.concat(msgs, "; ")
    end

    return vim.json.encode(ast_to_tagged(result.ast)), nil
end

return M
