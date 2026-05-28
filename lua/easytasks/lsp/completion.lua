local M            = {}

local s_util       = require("easytasks.toml.schema_util")
local schema_nav   = require("easytasks.toml.schema_nav")
local Cst          = require("easytasks.toml.Cst")

local CK           = vim.lsp.protocol.CompletionItemKind
local K            = Cst.Kind
local IF           = vim.lsp.protocol.InsertTextFormat

local empty_result = { isIncomplete = false, items = {} }

-- ── Enum function registry ────────────────────────────────────────────────────

---@type table<string, fun(data: any): (string|{label:string, description:string?})[]>
local _enumfuncs = {
    -- Returns all task names defined in the file; used for depends_on items.
    ["easytasks.tasks.names"] = function(data)
        local names = {}
        if type(data) == "table" and type(data.tasks) == "table" then
            for _, task in ipairs(data.tasks) do
                if type(task) == "table" and type(task.name) == "string" then
                    names[#names + 1] = task.name
                end
            end
        end
        return names
    end,
}

--- Register a custom enum generator.
---@param key string           the x-enumfunc value used in schema fields
---@param fn  fun(data: any): (string|{label:string,description:string?})[]
function M.register_enumfunc(key, fn)
    _enumfuncs[key] = fn
end

---@param key string
---@return (fun(data: any): any[])?
local function resolve_enumfunc(key)
    if _enumfuncs[key] then return _enumfuncs[key] end
    -- fallback: dotted Lua global path for external integrations
    local obj = _G
    for part in key:gmatch("[^.]+") do
        if type(obj) ~= "table" then return nil end
        obj = obj[part]
    end
    return type(obj) == "function" and obj or nil
end

-- ── Completion item builders ──────────────────────────────────────────────────

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
---@param data       any      decoded root data passed to x-enumfunc generators
---@return lsp.CompletionItem[]
local function value_items(schema, open_quote, data)
    if not schema then return {} end
    if schema.enum then
        local descs = schema["x-enumDescriptions"]
        local items = {}
        for i, v in ipairs(schema.enum) do
            local q      = open_quote or '"'
            local insert = type(v) == "string"
                and (open_quote and (v .. q) or (q .. v .. q))
                or tostring(v)
            items[#items + 1] = {
                label         = tostring(v),
                kind          = CK.Value,
                detail        = s_util.get_type_label(schema),
                documentation = descs and descs[i] or nil,
                insertText    = insert,
            }
        end
        return items
    end
    local enumfunc_key = schema["x-enumfunc"]
    if enumfunc_key then
        local fn = resolve_enumfunc(enumfunc_key)
        if fn then
            local ok, result = pcall(fn, data)
            if ok and type(result) == "table" then
                local q     = open_quote or '"'
                local items = {}
                for _, v in ipairs(result) do
                    local label  = type(v) == "table" and tostring(v.label) or tostring(v)
                    local desc   = type(v) == "table" and v.description or nil
                    local insert = open_quote and (label .. q) or (q .. label .. q)
                    items[#items + 1] = {
                        label         = label,
                        kind          = CK.Value,
                        documentation = desc,
                        insertText    = insert,
                    }
                end
                return items
            end
        end
    end
    local t = schema.type
    if t == "boolean" or (type(t) == "table" and vim.tbl_contains(t, "boolean")) then
        return {
            { label = "true",  kind = CK.Value, insertText = "true" },
            { label = "false", kind = CK.Value, insertText = "false" },
        }
    end
    local items = {}
    if t == "array" or (type(t) == "table" and vim.tbl_contains(t, "array")) then
        items[#items + 1] = { label = "[]", kind = CK.Value, insertTextFormat = IF.Snippet, insertText = "[$1]" }
    end
    if t == "object" or (type(t) == "table" and vim.tbl_contains(t, "object")) then
        items[#items + 1] = { label = "{}", kind = CK.Value, insertTextFormat = IF.Snippet, insertText = "{$1}" }
    end
    if not open_quote and (t == "string" or (type(t) == "table" and vim.tbl_contains(t, "string"))) then
        items[#items + 1] = { label = '""', kind = CK.Value, insertText = '"' }
    end
    return items
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

-- ── Handler ───────────────────────────────────────────────────────────────────

---@param context easytasks.LspBufferContext
---@param params lsp.CompletionParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.CompletionList)
function M.handler(context, params, callback)
    callback = vim.schedule_wrap(callback)
    if not context.schema then
        callback(nil, empty_result); return
    end
    local schema = context.schema --[[@as table]]

    local row    = params.position.line
    local col    = params.position.character
    local dt     = context.decode_tree
    local cst    = context.cst

    if not cst then
        callback(nil, empty_result); return
    end

    local data   = context.data

    -- token_at always returns a valid id (falls back to root)
    local tok_id = cst:token_at(row, col)
    local tok_d  = cst:data(tok_id) --[[@as easytasks.toml.CstData?]]
    local tok_k  = tok_d and tok_d.kind --[[@as easytasks.toml.CstKind?]]

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
        local is_trivia = tok_k == K.Whitespace or tok_k == K.Newline or tok_k == K.Comment
        if cursor_after_equals(cst, kvp_id, row, col) then
            -- value side: suppress when cursor is on trivia and a complete value already exists,
            -- but not when cursor is inside an inline array (want item completions there)
            local val_id   = cst:get_value(kvp_id)
            local in_array = ancestor_of_kind(cst, tok_id, K.Array) ~= nil
            if is_trivia and val_id and not in_array then
                callback(nil, empty_result); return
            end
            if tok_k == K.RBracket then
                callback(nil, empty_result); return
            end

            local dt_id = cst:get_tag(kvp_id)
            local sch
            if dt_id then
                sch = schema_nav.schema_at(schema, data, dt, dt_id)
            else
                -- KVP not yet decoded (value absent/incomplete): navigate via parent scope + key name
                local enc_id       = ancestor_of_kind(cst, kvp_id, K.TableSection, K.AotSection, K.InlineTable)
                local parent_dt_id = enc_id and cst:get_tag(enc_id) or dt:root_id()
                local parent_sch   = schema_nav.schema_at(schema, data, dt, parent_dt_id)
                    or schema_nav.flatten(schema, data)
                local keys         = cst:get_keys(kvp_id)
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
            if in_array then sch = sch and sch.items end
            callback(nil, { isIncomplete = false, items = value_items(sch, open_quote, data) })
        else
            -- key side: suppress when cursor is on trivia and a complete key already exists
            local keys = cst:get_keys(kvp_id)
            if is_trivia and #keys > 0 then
                callback(nil, empty_result); return
            end

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
