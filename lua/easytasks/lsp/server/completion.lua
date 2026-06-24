local M            = {}

local s_util       = require("easytasks.tomltools.schema_util")
local schema_nav   = require("easytasks.tomltools.schema_nav")
local Cst          = require("easytasks.tomltools.Cst")

local CK           = vim.lsp.protocol.CompletionItemKind
local K            = Cst.Kind
local IF           = vim.lsp.protocol.InsertTextFormat

local empty_result = { isIncomplete = false, items = {} }
---@param items lsp.CompletionItem[]
---@return lsp.CompletionList
local function result(items) return { isIncomplete = false, items = items } end

---@param schema   table?
---@param existing table<string, boolean>?
---@return lsp.CompletionItem[]
local function key_items(schema, existing)
    local items = {}
    for _, entry in ipairs(s_util.get_ordered_properties(schema)) do
        if not (existing and existing[entry.key]) then
            items[#items + 1] = {
                label         = entry.key,
                kind          = CK.Field,
                detail        = s_util.get_type_label(entry.schema),
                documentation = s_util.get_description(entry.schema),
                insertText    = entry.key,
            }
        end
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
    if has("array") then items[#items + 1] = { label = "[]", documentation = desc, kind = CK.Value, insertTextFormat = IF
        .Snippet, insertText = "[$1]" } end
    if has("object") then items[#items + 1] = { label = "{}", documentation = desc, kind = CK.Value, insertTextFormat =
        IF.Snippet, insertText = "{$1}" } end
    if not open_quote and has("string") then items[#items + 1] = { label = '"', documentation = desc, kind = CK.Text, insertText =
        '"' } end
    return items
end

---@param gather_fn     fun(schema: table, data: any, prefix: string, out: table[], pos: table?, dt_node: integer?)
---@param root_schema   table
---@param root_data     any
---@param typed_keys    string[]
---@param replace_range lsp.Range   range covering the already-typed dotted path
---@param pos           tomltools.HeaderPos?  cursor context for array-element binding
---@param root_dt_id    integer?    decode-tree root id (anchors position-aware descent)
---@return lsp.CompletionItem[]
local function header_items(gather_fn, root_schema, root_data, typed_keys, replace_range, pos, root_dt_id)
    local paths = {}
    gather_fn(root_schema, root_data, "", paths, pos, root_dt_id)
    local prefix = table.concat(typed_keys, ".")
    local items  = {}
    for _, entry in ipairs(paths) do
        if entry.path:sub(1, #prefix) == prefix and entry.path ~= prefix then
            -- Composite paths contain dots, which most clients treat as word
            -- boundaries; a bare insertText would only replace the segment after
            -- the last dot and duplicate the rest. An explicit textEdit spanning
            -- the whole typed path replaces it cleanly.
            items[#items + 1] = {
                label    = entry.path,
                kind     = CK.Module,
                textEdit = { range = replace_range, newText = entry.path },
            }
        end
    end
    return items
end

-- Position where the dotted key path begins inside a [header] / [[header]],
-- i.e. immediately after the opening bracket(s). Used as the start of the
-- completion replacement range. Falls back to the header start if no bracket
-- token is present.
---@param cst    tomltools.Cst
---@param hdr_id integer
---@return integer row
---@return integer col
local function header_keys_start(cst, hdr_id)
    local last_bracket
    for _, d in cst:iter_semantic(hdr_id) do
        if d.kind == K.LBracket then
            last_bracket = d
        else
            break
        end
    end
    if last_bracket then return last_bracket.range[3], last_bracket.range[4] end
    local hr = cst:range(hdr_id)
    if hr then return hr[1], hr[2] end
    return 0, 0
end

---@param schema table
---@param data   any
---@param dt     tomltools.DecodeTree
---@param dt_id  integer?
---@return table?
local function schema_for_node(schema, data, dt, dt_id)
    if dt_id then
        return schema_nav.schema_at(schema, data, dt, dt_id)
    end
    return schema_nav.flatten(schema, data)
end

---@param parent_sch table?
---@param keys       tomltools.CstData[]
---@return table?
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

---@param schema table?
---@param name   string
---@return boolean
local function is_type(schema, name)
    local t = schema and schema.type
    return t == name or (type(t) == "table" and vim.tbl_contains(t, name))
end

-- Resolve a section's schema from its [header] key path when the section has no
-- decode tag (e.g. a duplicate/invalid header the decoder rejected). Intermediate
-- array-of-tables levels descend into `items`, mirroring how [a.b] binds to an
-- [[a]] element. Returns the flattened object schema, or nil when not navigable.
---@param root_schema table?
---@param keys        tomltools.CstData[]   header key parts
---@return table?
local function schema_for_header_keys(root_schema, keys)
    if #keys == 0 then return nil end
    local sch = root_schema
    for _, kd in ipairs(keys) do
        local flat = sch and schema_nav.flatten(sch, nil)
        if not (flat and flat.properties and flat.properties[kd.value]) then return nil end
        sch = schema_nav.flatten(flat.properties[kd.value], nil)
        if is_type(sch, "array") and sch.items then sch = schema_nav.flatten(sch.items, nil) end
    end
    return sch
end

---@param cst    tomltools.Cst
---@param kvp_id integer
---@param row    integer
---@param col    integer
---@return boolean
local function cursor_after_equals(cst, kvp_id, row, col)
    for _, d in cst:iter_semantic(kvp_id) do
        if d.kind == K.Equals then
            local r = d.range
            return row > r[3] or (row == r[3] and col >= r[4])
        end
    end
    return false
end

---@param cst    tomltools.Cst
---@param tok_id integer
---@return boolean
local function directly_in_array(cst, tok_id)
    local anc = cst:ancestor_of_kind(tok_id, K.Array, K.InlineTable)
    return anc ~= nil and cst:kind(anc) == K.Array
end

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

    local lines  = context.lines
    if not dt or not lines or row >= #lines or col > #(lines[row + 1] or "") then
        callback(nil, empty_result); return
    end

    local tok_id    = cst:token_at(row, col)
    local tok_d     = cst:data(tok_id) --[[@as tomltools.CstData?]]
    local tok_k     = tok_d and tok_d.kind --[[@as tomltools.CstKind?]]
    local is_trivia = tok_k == K.Whitespace or tok_k == K.Newline or tok_k == K.Comment

    -- Cursor context so the gather binds [a.b] headers to the most recent
    -- [[a]] element before the cursor (not merely the array's last element).
    local pos     = { dt = dt, row = row, col = col }
    local root_dt = dt:root_id()

    -- [table.header] → suggest valid table paths from schema
    local hdr_id    = cst:ancestor_of_kind(tok_id, K.TableHeader)
    if hdr_id then
        local typed  = vim.tbl_map(function(kd) return kd.value end, cst:get_keys(hdr_id))
        local sr, sc = header_keys_start(cst, hdr_id)
        local rng    = { start = { line = sr, character = sc }, ["end"] = { line = row, character = col } }
        callback(nil, result(header_items(schema_nav.gather_table_paths, schema, data, typed, rng, pos, root_dt)))
        return
    end

    -- [[array.of.tables]] header → suggest valid AoT paths from schema
    local aot_id = cst:ancestor_of_kind(tok_id, K.AotHeader)
    if aot_id then
        local typed  = vim.tbl_map(function(kd) return kd.value end, cst:get_keys(aot_id))
        local sr, sc = header_keys_start(cst, aot_id)
        local rng    = { start = { line = sr, character = sc }, ["end"] = { line = row, character = col } }
        callback(nil, result(header_items(schema_nav.gather_array_table_paths, schema, data, typed, rng, pos, root_dt)))
        return
    end

    -- Cursor is inside a key-value pair (key = value).
    -- Ancestor search stops at InlineTable boundaries so we don't escape inline scope.
    local anc    = cst:ancestor_of_kind(tok_id, K.KeyValuePair, K.InlineTable)
    local kvp_id = (anc and cst:kind(anc) == K.KeyValuePair and anc)
        or (tok_k == K.KeyValuePair and tok_id)
        or nil

    if kvp_id then
        if cursor_after_equals(cst, kvp_id, row, col) then
            -- Value side: suggest enum members, booleans, [] / {} starters.
            local val_id   = cst:get_value(kvp_id)
            local in_array = directly_in_array(cst, tok_id)
            -- Suppress if the value is already complete (trivia after a non-array value,
            -- or cursor on ] closing an inline array).
            if (is_trivia and val_id and not in_array) or tok_k == K.RBracket then
                callback(nil, empty_result); return
            end

            local dt_id = cst:get_tag(kvp_id)
            local sch
            if dt_id then
                -- KVP is already decoded: look up its schema directly.
                if in_array then
                    -- Cursor inside an inline array literal → offer the array item schema.
                    sch = schema_nav.schema_at(schema, data, dt, dt_id)
                    sch = sch and sch.items
                else
                    -- Use raw (non-flattened) schema so value_items can enumerate all oneOf branches.
                    sch = schema_nav.raw_schema_at(schema, data, dt, dt_id)
                end
            else
                -- KVP not yet in the decode tree (incomplete / new key): resolve schema
                -- by navigating from the enclosing section's schema using the typed key path.
                local enc_id  = cst:ancestor_of_kind(kvp_id, K.TableSection, K.AotSection, K.InlineTable)
                local enc_tag = enc_id and cst:get_tag(enc_id)
                -- Inline table not yet decoded → no schema context available.
                if enc_id and cst:kind(enc_id) == K.InlineTable and not enc_tag then
                    callback(nil, empty_result); return
                end
                local enc_dt     = enc_tag or dt:root_id()
                local parent_sch = schema_nav.schema_at(schema, data, dt, enc_dt)
                sch              = schema_for_keys(parent_sch, cst:get_keys(kvp_id))
                if in_array then sch = sch and schema_nav.flatten(sch, data).items end
            end

            local open_quote = tok_k == K.String and tok_d and tok_d.text:sub(1, 1) or nil
            local path       = dt_id and dt:key_parts_of(dt_id) or {}
            callback(nil, result(value_items(sch, open_quote, { data = data, path = path })))
        else
            -- Key side: suggest sibling keys allowed by the parent schema.
            local keys = cst:get_keys(kvp_id)
            -- Trivia after a complete key (e.g. "key<space><cursor>") → nothing to complete.
            if is_trivia and #keys > 0 then
                callback(nil, empty_result); return
            end

            local dt_id     = cst:get_tag(kvp_id)
            local parent_id = dt_id and dt:get_parent_id(dt_id)
            if not parent_id then
                -- KVP not yet decoded: find the enclosing section to get the parent scope.
                local enc_id  = cst:ancestor_of_kind(kvp_id, K.TableSection, K.AotSection, K.InlineTable)
                local enc_tag = enc_id and cst:get_tag(enc_id)
                if enc_id and cst:kind(enc_id) == K.InlineTable and not enc_tag then
                    callback(nil, empty_result); return
                end
                parent_id = enc_tag or dt:root_id()
            end
            callback(nil, result(key_items(schema_for_node(schema, data, dt, parent_id), dt:child_keys(parent_id))))
        end
        return
    end

    -- Cursor is in whitespace between KVPs inside a section or inline table.
    -- token_at may land directly on the section composite when the cursor sits in
    -- its trailing gap (e.g. an empty line after [a.b]); treat that node as the
    -- scope itself rather than searching only its ancestors.
    local scope_id = ((tok_k == K.InlineTable or tok_k == K.TableSection or tok_k == K.AotSection) and tok_id)
        or cst:ancestor_of_kind(tok_id, K.InlineTable, K.TableSection, K.AotSection)
    if scope_id then
        local scope_tag = cst:get_tag(scope_id)
        if not scope_tag then
            local scope_kind = cst:kind(scope_id)
            -- Inline table not yet decoded → no schema context available.
            if scope_kind == K.InlineTable then
                callback(nil, empty_result); return
            end
            -- Section not bound to a decode node (e.g. a duplicate/invalid header
            -- the decoder rejected): resolve its schema from the header key path
            -- rather than falling through to top-level keys.
            local hdr = cst:first_child_of_kind(scope_id, K.TableHeader, K.AotHeader)
            local sch = hdr and schema_for_header_keys(schema, cst:get_keys(hdr))
            callback(nil, result(key_items(sch, nil)))
            return
        end
        callback(nil, result(key_items(schema_for_node(schema, data, dt, scope_tag), dt:child_keys(scope_tag))))
        return
    end

    -- Cursor at document root (no enclosing section) → top-level keys.
    if tok_k == K.Document or cst:ancestor_of_kind(tok_id, K.Document) then
        local root_id = dt:root_id()
        callback(nil, result(key_items(schema_for_node(schema, data, dt, root_id), dt:child_keys(root_id))))
        return
    end

    callback(nil, empty_result)
end

return M
