-- easytasks/lsp/builtin_actions.lua
-- Built-in code action providers. Assigned to every buffer context in server.lua.
-- Each provider matches the signature: fun(ctx, params) -> lsp.CodeAction[]

local M          = {}

local schema_nav = require("easytasks.tomltools.schema_nav")
local s_util     = require("easytasks.tomltools.schema_util")
local Cst        = require("easytasks.tomltools.Cst")

local K          = Cst.Kind

-- ── Helpers ───────────────────────────────────────────────────────────────────

---@param sl   integer  0-indexed start line
---@param sc   integer  0-indexed start char (inclusive)
---@param el   integer  0-indexed end line
---@param ec   integer  0-indexed end char (exclusive)
---@param text string
---@return lsp.TextEdit
local function text_edit(sl, sc, el, ec, text)
    return {
        range   = { start = { line = sl, character = sc }, ["end"] = { line = el, character = ec } },
        newText = text,
    }
end

---@param title string
---@param kind  string
---@param uri   string
---@param edits lsp.TextEdit[]
---@return lsp.CodeAction
local function make_action(title, kind, uri, edits)
    return { title = title, kind = kind, edit = { changes = { [uri] = edits } } }
end

-- Returns the CST scope node and DecodeTree id for the section containing (row,col),
-- falling back to document root when the cursor is not inside any section.
---@param cst easytasks.toml.Cst
---@param dt  easytasks.toml.DecodeTree
---@param row integer
---@param col integer
---@return integer?  scope_id   nil at document root
---@return integer   dt_id
local function enclosing_scope(cst, dt, row, col)
    local tok_id   = cst:token_at(row, col)
    local scope_id = cst:ancestor_of_kind(tok_id, K.TableSection, K.AotSection)
    local dt_id    = (scope_id and cst:get_tag(scope_id)) or dt:root_id()
    return scope_id, dt_id
end

-- ── Action: fill missing required keys ─────────────────────────────────────

--- Offers to insert all required keys that are absent from the enclosing section.
--- Uses schema defaults as placeholder values; falls back to `""` for untyped keys.
---@param ctx    easytasks.LspBufferContext
---@param params lsp.CodeActionParams
---@return lsp.CodeAction[]
function M.fill_required_keys(ctx, params)
    if not (ctx.cst and ctx.decode_tree and ctx.schema and ctx.lines) then return {} end

    local cst             = ctx.cst
    local dt              = ctx.decode_tree --[[@as easytasks.toml.DecodeTree]]
    local schema          = ctx.schema --[[@as table]]
    local data            = ctx.data
    local row             = params.range.start.line
    local col             = params.range.start.character

    local scope_id, dt_id = enclosing_scope(cst, dt, row, col)

    local sch             = schema_nav.schema_at(schema, data, dt, dt_id)
    if not sch or not sch.required or #sch.required == 0 then return {} end

    -- Collect required keys absent from the decode tree for this scope.
    local missing = {}
    for _, req_key in ipairs(sch.required) do
        if not dt:get_child_id(dt_id, req_key) then
            missing[#missing + 1] = req_key
        end
    end
    if #missing == 0 then return {} end

    -- Build `key = value` lines, using schema defaults where available.
    local new_lines = {}
    for _, key in ipairs(missing) do
        local prop_sch            = sch.properties and sch.properties[key]
        local default             = prop_sch and s_util.get_default_toml(prop_sch)
        local value               = (default and default ~= "") and default or '""'
        new_lines[#new_lines + 1] = key .. " = " .. value
    end

    -- Insert after the last KVP in scope (or end of section/document as fallback).
    local parent_id = scope_id or cst:root_id()
    local last_kvp_id
    for child_id, child_d in cst:iter_semantic(parent_id) do
        if child_d.kind == K.KeyValuePair then
            last_kvp_id = child_id
        end
    end

    local ins_row, ins_col, prefix
    if last_kvp_id then
        local r = cst:range(last_kvp_id)
        if not r then return {} end
        ins_row, ins_col, prefix = r[3], r[4], "\n"
    elseif scope_id then
        local header_id = cst:first_child_of_kind(scope_id, K.TableHeader, K.AotHeader)
        local r         = header_id and cst:range(header_id) or cst:range(scope_id)
        if not r then return {} end
        ins_row, ins_col, prefix = r[3], r[4], "\n"
    else
        ins_row, ins_col, prefix = #ctx.lines - 1, #(ctx.lines[#ctx.lines] or ""), ""
    end

    local n     = #missing
    local label = "Fill " .. n .. " missing required key" .. (n > 1 and "s" or "")
    return {
        make_action(label, "quickfix", params.textDocument.uri, {
            text_edit(ins_row, ins_col, ins_row, ins_col, prefix .. table.concat(new_lines, "\n")),
        })
    }
end

-- ── Provider list ─────────────────────────────────────────────────────────────

--- All built-in providers as a ready-to-assign list for context.code_action_providers.
---@type (fun(ctx: easytasks.LspBufferContext, params: table): lsp.CodeAction[]?)[]
M.providers = {
    M.fill_required_keys,
}

return M
