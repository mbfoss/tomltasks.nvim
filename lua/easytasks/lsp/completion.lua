local M = {}

local s_util     = require("easytasks.toml.schema_util")
local schema_nav = require("easytasks.toml.schema_nav")
local Cst        = require("easytasks.toml.Cst")

local CK = vim.lsp.protocol.CompletionItemKind
local K  = Cst.Kind
local IF = vim.lsp.protocol.InsertTextFormat

local empty_result = { isIncomplete = false, items = {} }
local function result(items) return { isIncomplete = false, items = items } end

-- ── Item builders ─────────────────────────────────────────────────────────────

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

---@param schema     table?
---@param open_quote string?
---@param ctx        table
---@return lsp.CompletionItem[]
local function value_items(schema, open_quote, ctx)
    if not schema then return {} end
    if schema.oneOf then
        local items, seen = {}, {}
        for _, sub in ipairs(schema.oneOf) do
            for _, item in ipairs(value_items(schema_nav.flatten(sub, nil), open_quote, ctx)) do
                if not seen[item.label] then
                    seen[item.label] = true
                    items[#items + 1] = item
                end
            end
        end
        return items
    end
    if schema.enum then
        local descs = schema["x-enumDescriptions"]
        local q     = open_quote or '"'
        local items = {}
        for i, v in ipairs(schema.enum) do
            local insert = type(v) == "string"
                and (open_quote and (v .. q) or (q .. v .. q))
                or tostring(v)
            items[#items + 1] = {
                label         = tostring(v),
                kind          = CK.Text,
                detail        = s_util.get_type_label(schema),
                documentation = descs and descs[i] or nil,
                insertText    = insert,
            }
        end
        return items
    end
    local t    = schema.type
    local desc = schema.description
    local function has(n) return t == n or (type(t) == "table" and vim.tbl_contains(t, n)) end
    if has("boolean") then
        return {
            { label = "true",  kind = CK.Value, insertText = "true" },
            { label = "false", kind = CK.Value, insertText = "false" },
        }
    end
    local items = {}
    if has("array")                     then items[#items+1] = { label = "[]", documentation = desc, kind = CK.Value, insertTextFormat = IF.Snippet, insertText = "[$1]" } end
    if has("object")                    then items[#items+1] = { label = "{}", documentation = desc, kind = CK.Value, insertTextFormat = IF.Snippet, insertText = "{$1}" } end
    if not open_quote and has("string") then items[#items+1] = { label = '"',  documentation = desc, kind = CK.Text,  insertText = '"' } end
    return items
end

---@param gather_fn  fun(schema: table, prefix: string, out: table[])
---@param root_schema table
---@param root_data   any
---@param typed_keys  string[]
---@return lsp.CompletionItem[]
local function header_items(gather_fn, root_schema, root_data, typed_keys)
    local flat   = schema_nav.flatten(root_schema, root_data)
    local paths  = {}
    gather_fn(flat, "", paths)
    local prefix = table.concat(typed_keys, ".")
    local items  = {}
    for _, entry in ipairs(paths) do
        if entry.path:sub(1, #prefix) == prefix and entry.path ~= prefix then
            items[#items + 1] = { label = entry.path, kind = CK.Module, insertText = entry.path }
        end
    end
    return items
end

-- ── Schema helpers ────────────────────────────────────────────────────────────

-- Returns the schema at a decoded node, falling back to the flattened root.
local function schema_for_node(schema, data, dt, dt_id)
    return (dt_id and schema_nav.schema_at(schema, data, dt, dt_id))
        or schema_nav.flatten(schema, data)
end

-- Walks schema properties along a key path (raw, preserving oneOf).
local function schema_for_keys(parent_sch, keys)
    if #keys == 0 then return nil end
    local sch = parent_sch
    for _, kd in ipairs(keys) do
        if sch and sch.properties and sch.properties[kd.value] then
            sch = sch.properties[kd.value]
        else
            return nil
        end
    end
    return sch
end

-- ── Cursor helpers ────────────────────────────────────────────────────────────

local function cursor_after_equals(cst, kvp_id, row, col)
    for _, d in cst:iter_semantic(kvp_id) do
        if d.kind == K.Equals then
            local r = d.range
            return row > r[3] or (row == r[3] and col >= r[4])
        end
    end
    return false
end

-- True when the nearest Array/InlineTable ancestor is an Array.
-- Prevents treating an InlineTable-inside-an-Array as "directly in array".
local function directly_in_array(cst, tok_id)
    local anc = cst:ancestor_of_kind(tok_id, K.Array, K.InlineTable)
    return anc ~= nil and cst:kind(anc) == K.Array
end

-- ── Handler ───────────────────────────────────────────────────────────────────

---@param context  easytasks.LspBufferContext
---@param params   lsp.CompletionParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.CompletionList)
function M.handler(context, params, callback)
    if not (context.schema and context.cst) then
        callback(nil, empty_result); return
    end

    local schema = context.schema --[[@as table]]
    local cst    = context.cst
    local dt     = context.decode_tree
    local data   = context.data
    local row    = params.position.line
    local col    = params.position.character

    -- Reject out-of-bounds positions (can happen when the buffer is being edited
    -- and the client sends a stale or ahead-of-parse cursor position).
    local lines = context.lines
    if not lines or row >= #lines or col > #(lines[row + 1] or "") then
        callback(nil, empty_result); return
    end

    local tok_id    = cst:token_at(row, col)
    local tok_d     = cst:data(tok_id) --[[@as easytasks.toml.CstData?]]
    local tok_k     = tok_d and tok_d.kind --[[@as easytasks.toml.CstKind?]]
    local is_trivia = tok_k == K.Whitespace or tok_k == K.Newline or tok_k == K.Comment

    -- ── Headers ──────────────────────────────────────────────────────────────

    local hdr_id = cst:ancestor_of_kind(tok_id, K.TableHeader)
    if hdr_id then
        local typed = vim.tbl_map(function(kd) return kd.value end, cst:get_keys(hdr_id))
        callback(nil, result(header_items(s_util.gather_table_paths, schema, data, typed)))
        return
    end

    local aot_id = cst:ancestor_of_kind(tok_id, K.AotHeader)
    if aot_id then
        local typed = vim.tbl_map(function(kd) return kd.value end, cst:get_keys(aot_id))
        callback(nil, result(header_items(s_util.gather_array_table_paths, schema, data, typed)))
        return
    end

    -- ── KVP ──────────────────────────────────────────────────────────────────

    -- Stop at InlineTable: if InlineTable is closer than KeyValuePair, the cursor
    -- is between KVPs inside an inline table, not inside one.
    local anc    = cst:ancestor_of_kind(tok_id, K.KeyValuePair, K.InlineTable)
    local kvp_id = (anc and cst:kind(anc) == K.KeyValuePair and anc)
        or (tok_k == K.KeyValuePair and tok_id)
        or nil

    if kvp_id then
        if cursor_after_equals(cst, kvp_id, row, col) then
            -- Suppress when cursor is on trivia over a complete value, unless directly in an array.
            local val_id   = cst:get_value(kvp_id)
            local in_array = directly_in_array(cst, tok_id)
            if (is_trivia and val_id and not in_array) or tok_k == K.RBracket then
                callback(nil, empty_result); return
            end

            local dt_id = cst:get_tag(kvp_id)
            local sch
            if dt_id then
                if in_array then
                    -- Flatten to pick the correct oneOf branch, then step into items.
                    sch = schema_nav.schema_at(schema, data, dt, dt_id)
                    sch = sch and sch.items
                else
                    -- Preserve oneOf so value_items can offer all branches.
                    sch = schema_nav.raw_schema_at(schema, data, dt, dt_id)
                end
            else
                -- Incomplete KVP (no value yet): navigate via enclosing scope + key name.
                local enc_id  = cst:ancestor_of_kind(kvp_id, K.TableSection, K.AotSection, K.InlineTable)
                local enc_tag = enc_id and cst:get_tag(enc_id)
                -- Untagged enclosing InlineTable means the node is outside the decoded tree
                -- (e.g. duplicate key). Don't fall back to root — schema is unknown.
                if enc_id and cst:kind(enc_id) == K.InlineTable and not enc_tag then
                    callback(nil, empty_result); return
                end
                local enc_dt     = enc_tag or dt:root_id()
                local parent_sch = schema_nav.schema_at(schema, data, dt, enc_dt)
                    or schema_nav.flatten(schema, data)
                sch = schema_for_keys(parent_sch, cst:get_keys(kvp_id))
                if in_array then sch = sch and schema_nav.flatten(sch, data).items end
            end

            local open_quote = tok_k == K.String and tok_d and tok_d.text:sub(1, 1) or nil
            local path       = dt_id and dt:key_parts_of(dt_id) or {}
            callback(nil, result(value_items(sch, open_quote, { data = data, path = path })))
        else
            -- Key side: suppress when cursor is on trivia over a complete key.
            local keys = cst:get_keys(kvp_id)
            if is_trivia and #keys > 0 then callback(nil, empty_result); return end

            local dt_id     = cst:get_tag(kvp_id)
            local parent_id = dt_id and dt:get_parent_id(dt_id)
            if not parent_id then
                local enc_id  = cst:ancestor_of_kind(kvp_id, K.TableSection, K.AotSection, K.InlineTable)
                local enc_tag = enc_id and cst:get_tag(enc_id)
                -- Untagged enclosing InlineTable: outside the decoded tree, schema unknown.
                if enc_id and cst:kind(enc_id) == K.InlineTable and not enc_tag then
                    callback(nil, empty_result); return
                end
                parent_id = enc_tag or dt:root_id()
            end
            callback(nil, result(key_items(schema_for_node(schema, data, dt, parent_id))))
        end
        return
    end

    -- ── Inline table / section / document: key completions ───────────────────

    local scope_id = cst:ancestor_of_kind(tok_id, K.InlineTable, K.TableSection, K.AotSection)
    if scope_id then
        local scope_tag = cst:get_tag(scope_id)
        -- Untagged InlineTable: outside the decoded tree (e.g. duplicate key). Schema unknown.
        if not scope_tag and cst:kind(scope_id) == K.InlineTable then
            callback(nil, empty_result); return
        end
        callback(nil, result(key_items(schema_for_node(schema, data, dt, scope_tag))))
        return
    end

    if tok_k == K.Document or cst:ancestor_of_kind(tok_id, K.Document) then
        callback(nil, result(key_items(schema_for_node(schema, data, dt, dt:root_id()))))
        return
    end

    callback(nil, empty_result)
end

return M
