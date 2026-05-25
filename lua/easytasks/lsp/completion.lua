local M          = {}

local s_util     = require("easytasks.toml.schema_util")
local schema_nav = require("easytasks.toml.schema_nav")
local Cst        = require("easytasks.toml.Cst")

local CK = vim.lsp.protocol.CompletionItemKind
local K  = Cst.Kind

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

---@param schema     table?
---@param open_quote string?  the opening quote char already in the buffer ("'" or '"'), or nil
---@return lsp.CompletionItem[]
local function value_items(schema, open_quote)
    if not schema then return {} end
    if schema.enum then
        local items = {}
        for _, v in ipairs(schema.enum) do
            local q      = open_quote or '"'
            -- When cursor is already inside an open string, the opening quote is in the
            -- buffer; only insert the rest to avoid doubling it.
            local insert = type(v) == "string"
                and (open_quote and (v .. q) or (q .. v .. q))
                or tostring(v)
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

---@param cst easytasks.toml.Cst
---@param id  integer
---@param ... easytasks.toml.CstKind
---@return integer?
local function ancestor_of_kind(cst, id, ...)
    return cst:ancestor_of_kind(id, ...)
end

---@param cst    easytasks.toml.Cst
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

---@param context easytasks.LspBufferContext
---@param params lsp.CompletionParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.CompletionList)
function M.handler(context, params, callback)
    callback = vim.schedule_wrap(callback)
    if not context.schema then callback(nil, empty_result); return end
    local schema = context.schema --[[@as table]]

    local row = params.position.line
    local col = params.position.character
    local dt  = context.decode_tree
    local cst = context.cst

    if not cst then callback(nil, empty_result); return end

    local data = context.data

    -- token_at always returns a valid id (falls back to root)
    local tok_id = cst:token_at(row, col)
    local tok_d  = cst:data(tok_id)  --[[@as easytasks.toml.CstData?]]
    local tok_k  = tok_d and tok_d.kind  --[[@as easytasks.toml.CstKind?]]

    -- ── Header contexts ──────────────────────────────────────────────────────

    local hdr_id = ancestor_of_kind(cst, tok_id, K.TableHeader)
    if hdr_id then
        local keys = cst:get_keys(hdr_id)
        local typed = {}
        for _, kd in ipairs(keys) do typed[#typed + 1] = kd.value end
        callback(nil, { isIncomplete = false, items = table_header_items(schema, data, typed) })
        return
    end

    local aot_id = ancestor_of_kind(cst, tok_id, K.AotHeader)
    if aot_id then
        local keys = cst:get_keys(aot_id)
        local typed = {}
        for _, kd in ipairs(keys) do typed[#typed + 1] = kd.value end
        callback(nil, { isIncomplete = false, items = aot_header_items(schema, data, typed) })
        return
    end

    -- ── Inside a KVP ─────────────────────────────────────────────────────────

    -- Stop at InlineTable: if InlineTable is found before KeyValuePair, the cursor
    -- is between KVPs in a multiline inline table, not inside one.
    local kvp_id
    do
        local anc = ancestor_of_kind(cst, tok_id, K.KeyValuePair, K.InlineTable)
        if anc and cst:kind(anc) == K.KeyValuePair then kvp_id = anc end
    end
    if not kvp_id and tok_k == K.KeyValuePair then kvp_id = tok_id end

    if kvp_id then
        if cursor_after_equals(cst, kvp_id, row, col) then
            -- value side
            local dt_id = cst:get_tag(kvp_id)
            local sch
            if dt_id then
                sch = schema_nav.schema_at(schema, data, dt, dt_id)
            else
                -- KVP not yet decoded (value absent/incomplete): navigate via parent scope + key name
                local enc_id      = ancestor_of_kind(cst, kvp_id, K.TableSection, K.AotSection, K.InlineTable)
                local parent_dt_id = enc_id and cst:get_tag(enc_id) or dt:root_id()
                local parent_sch  = schema_nav.schema_at(schema, data, dt, parent_dt_id)
                                 or schema_nav.flatten(schema, data)
                local keys = cst:get_keys(kvp_id)
                if parent_sch and #keys > 0 then
                    sch = parent_sch
                    for _, kd in ipairs(keys) do
                        if sch and sch.properties and sch.properties[kd.value] then
                            sch = schema_nav.flatten(sch.properties[kd.value], nil)
                        else
                            sch = nil; break
                        end
                    end
                end
            end
            local open_quote = tok_k == K.String and tok_d and tok_d.text:sub(1, 1) or nil
            callback(nil, { isIncomplete = false, items = value_items(sch, open_quote) })
        else
            -- key side — offer sibling keys from enclosing scope
            local dt_id     = cst:get_tag(kvp_id)
            local parent_id = dt_id and dt:get_parent_id(dt_id)
            if not parent_id then
                -- incomplete/errored KVP has no tag: fall back to enclosing scope
                local enc_id = ancestor_of_kind(cst, kvp_id, K.TableSection, K.AotSection, K.InlineTable)
                parent_id = enc_id and cst:get_tag(enc_id) or dt:root_id()
            end
            local sch = schema_nav.schema_at(schema, data, dt, parent_id)
                     or schema_nav.flatten(schema, data)
            callback(nil, { isIncomplete = false, items = key_items(sch) })
        end
        return
    end

    -- ── Inside an inline table (whitespace/trivia, not in a KVP child) ───────

    local itbl_id = ancestor_of_kind(cst, tok_id, K.InlineTable)
    if itbl_id then
        local dt_id = cst:get_tag(itbl_id)
        local sch
        if dt_id then
            sch = schema_nav.schema_at(schema, data, dt, dt_id)
        else
            sch = schema_nav.flatten(schema, data)
        end
        callback(nil, { isIncomplete = false, items = key_items(sch) })
        return
    end

    -- ── Inside a table/aot section body (trivia between KVPs) ────────────────

    local sec_id = ancestor_of_kind(cst, tok_id, K.TableSection, K.AotSection)
    if sec_id then
        local dt_id = cst:get_tag(sec_id)
        local sch
        if dt_id then
            sch = schema_nav.schema_at(schema, data, dt, dt_id)
        else
            sch = schema_nav.flatten(schema, data)
        end
        callback(nil, { isIncomplete = false, items = key_items(sch) })
        return
    end

    -- ── Document root (before any section) ───────────────────────────────────

    if tok_k == K.Document or ancestor_of_kind(cst, tok_id, K.Document) then
        local sch = schema_nav.schema_at(schema, data, dt, dt:root_id())
                 or schema_nav.flatten(schema, data)
        callback(nil, { isIncomplete = false, items = key_items(sch) })
        return
    end

    callback(nil, empty_result)
end

return M
