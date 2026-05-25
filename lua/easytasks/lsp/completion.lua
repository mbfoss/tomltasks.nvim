local M          = {}

local s_util     = require("easytasks.toml.schema_util")
local schema_nav = require("easytasks.toml.schema_nav")
local Ast        = require("easytasks.toml.Ast")

local CK         = vim.lsp.protocol.CompletionItemKind
local NodeKind   = Ast.NodeKind

local empty_result = { isIncomplete = false, items = {} }

---@param schema table?
---@return lsp.CompletionItem[]
local function key_items(schema)
    local items = {}
    for _, entry in ipairs(s_util.get_ordered_properties(schema)) do
        items[#items + 1] = {
            label         = entry.key,
            kind          = CK.Field,
            detail        = s_util.get_type_label(entry.schema),
            documentation = s_util.get_description(entry.schema),
            insertText    = entry.key,
        }
    end
    return items
end

---@param schema table?
---@return lsp.CompletionItem[]
local function value_items(schema)
    if not schema then return {} end
    if schema.enum then
        local items = {}
        for _, v in ipairs(schema.enum) do
            local insert = type(v) == "string" and ('"' .. v .. '"') or tostring(v)
            items[#items + 1] = {
                label      = tostring(v),
                kind       = CK.Value,
                detail     = s_util.get_type_label(schema),
                insertText = insert,
            }
        end
        return items
    end
    local t = schema.type
    if t == "boolean" or (type(t) == "table" and vim.tbl_contains(t, "boolean")) then
        return {
            { label = "true",  kind = CK.Value, insertText = "true" },
            { label = "false", kind = CK.Value, insertText = "false" },
        }
    end
    return {}
end

-- Gather all navigable [table] paths from the schema and filter by the prefix
-- of the keys already typed in the header.
---@param root_schema table
---@param root_data   any
---@param typed_keys  string[]
---@return lsp.CompletionItem[]
local function table_header_items(root_schema, root_data, typed_keys)
    local flat  = schema_nav.flatten(root_schema, root_data)
    local paths = {}
    s_util.gather_table_paths(flat, "", paths)
    local prefix = table.concat(typed_keys, ".")
    local items  = {}
    for _, entry in ipairs(paths) do
        if entry.path:sub(1, #prefix) == prefix and entry.path ~= prefix then
            items[#items + 1] = { label = entry.path, kind = CK.Module, insertText = entry.path }
        end
    end
    return items
end

-- Same for [[array-of-tables]] headers.
---@param root_schema table
---@param root_data   any
---@param typed_keys  string[]
---@return lsp.CompletionItem[]
local function aot_header_items(root_schema, root_data, typed_keys)
    local flat  = schema_nav.flatten(root_schema, root_data)
    local paths = {}
    s_util.gather_array_table_paths(flat, "", paths)
    local prefix = table.concat(typed_keys, ".")
    local items  = {}
    for _, entry in ipairs(paths) do
        if entry.path:sub(1, #prefix) == prefix and entry.path ~= prefix then
            items[#items + 1] = { label = entry.path, kind = CK.Module, insertText = entry.path }
        end
    end
    return items
end

---@param context easytasks.LspBufferContext
---@param params lsp.CompletionParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.CompletionList)
function M.handler(context, params, callback)
    callback = vim.schedule_wrap(callback)
    if not context.schema then callback(nil, empty_result); return end
    local schema = context.schema --[[@as table]]

    local row  = params.position.line
    local col  = params.position.character
    local dt   = context.decode_tree
    local data = context.data

    -- Step 1: classify context via the AST node at cursor (Taplo: context-first)
    local ast_node = context.ast:node_at(row, col)

    if ast_node then
        local kind = ast_node.node.kind

        -- TABLE HEADER [foo.bar] — offer navigable object paths filtered by prefix
        if kind == NodeKind.TableSection or kind == NodeKind.PartialTableSection then
            local keys = {}
            for _, kt in ipairs(ast_node.node.keys) do keys[#keys + 1] = kt.value end
            callback(nil, { isIncomplete = false, items = table_header_items(schema, data, keys) })
            return
        end

        -- ARRAY-OF-TABLES HEADER [[foo.bar]] — offer array-of-object paths
        if kind == NodeKind.ArrayOfTablesSection or kind == NodeKind.PartialArrayOfTablesSection then
            local keys = {}
            for _, kt in ipairs(ast_node.node.keys) do keys[#keys + 1] = kt.value end
            callback(nil, { isIncomplete = false, items = aot_header_items(schema, data, keys) })
            return
        end

        -- VALUE side: syntactic value node
        if kind == NodeKind.Literal or kind == NodeKind.Array or kind == NodeKind.MissingValue then
            local dt_id = dt:pos_to_id(row, col)
            local sch
            if dt_id then sch = schema_nav.schema_at(schema, data, dt, dt_id) end
            callback(nil, { isIncomplete = false, items = value_items(sch) })
            return
        end

        -- KVP: cursor somewhere inside a key-value pair — use value_range to decide side
        if kind == NodeKind.KeyValuePair then
            local vr = ast_node.node.value_range
            local on_value = vr and (row > vr[1] or (row == vr[1] and col >= vr[2]))
            if on_value then
                local dt_id = dt:pos_to_id(row, col)
                local sch
                if dt_id then sch = schema_nav.schema_at(schema, data, dt, dt_id) end
                callback(nil, { isIncomplete = false, items = value_items(sch) })
            else
                local dt_id = dt:pos_to_id(row, col)
                local parent_id = dt_id and dt:get_parent_id(dt_id)
                local sch
                if parent_id then
                    sch = schema_nav.schema_at(schema, data, dt, parent_id)
                else
                    sch = schema_nav.flatten(schema, data)
                end
                callback(nil, { isIncomplete = false, items = key_items(sch) })
            end
            return
        end
        if kind == NodeKind.InlineTable then
            return
        end
    end

    callback(nil, { isIncomplete = false, items = {}--[[  ]] })
end

return M
