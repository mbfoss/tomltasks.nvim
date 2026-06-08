-- Code action provider for task template insertion.
-- Returns lsp.CodeAction items when the cursor is in a position where a new
-- task entry can be inserted (inside the tasks array or between AoT entries).

local Cst = require("tomltools.toml.Cst")
local K   = Cst.Kind

-- Returns the indentation of the first inline-table item inside an Array node,
-- falling back to two spaces if none exist yet.
---@param lines  string[]
---@param cst    tomltools.toml.Cst
---@param arr_id integer
---@return string
local function array_item_indent(lines, cst, arr_id)
    for _, vd in cst:iter_values(arr_id) do
        if vd.kind == K.InlineTable then
            local line = lines[vd.range[1] + 1] or ""
            return line:match("^(%s*)") or "  "
        end
    end
    return "  "
end

-- Determine whether the cursor is in a position where a task template can be
-- inserted. Returns insertion kind and relevant CST node id, or nil.
---@param cst tomltools.toml.Cst
---@param dt  tomltools.toml.DecodeTree
---@param row integer
---@param col integer
---@return "array"|"aot"|nil
---@return integer?
local function tasks_insertion_ctx(cst, dt, row, col)
    local tok_id = cst:token_at(row, col)

    local anc = cst:ancestor_of_kind(tok_id, K.Array, K.InlineTable)
    if anc and cst:kind(anc) == K.Array then
        local is_tasks = false
        local tag = cst:get_tag(anc)
        if tag then
            local parts = dt:key_parts_of(tag)
            is_tasks = #parts == 1 and parts[1] == "tasks"
        else
            local kvp_id = cst:ancestor_of_kind(anc, K.KeyValuePair)
            if kvp_id then
                local keys = cst:get_keys(kvp_id)
                is_tasks = #keys == 1 and keys[1].value == "tasks"
            end
        end
        if is_tasks then return "array", anc end
    end

    if not cst:ancestor_of_kind(tok_id, K.KeyValuePair) then
        local aot_id = cst:ancestor_of_kind(tok_id, K.AotSection)
        if aot_id then
            local hdr_id = cst:first_child_of_kind(aot_id, K.AotHeader)
            if hdr_id then
                local keys = cst:get_keys(hdr_id)
                if #keys == 1 and keys[1].value == "tasks" then
                    ---@type integer?
                    local anchor = tok_id
                    while anchor and cst:parent_id(anchor) ~= aot_id do
                        anchor = cst:parent_id(anchor)
                    end
                    local kvp_after = false
                    local sib = anchor and cst:next_sibling_id(anchor)
                    while sib do
                        if cst:kind(sib) == K.KeyValuePair then kvp_after = true; break end
                        sib = cst:next_sibling_id(sib)
                    end
                    if not kvp_after then return "aot", aot_id end
                end
            end
        end
    end

    local trivial = {
        [K.Whitespace] = true, [K.Newline] = true,
        [K.Comment]    = true, [K.Document] = true,
    }
    ---@type integer?
    local cur, at_root = tok_id, true
    while cur do
        if not trivial[cst:kind(cur)] then at_root = false; break end
        cur = cst:parent_id(cur)
    end
    if at_root then return "aot", nil end

    return nil
end

local M = {}

-- Returns code actions for inserting task templates at the cursor.
-- `type_names` is the list of task type names that have templates defined.
---@param context    tomltools.LspBufferContext
---@param params     lsp.CodeActionParams
---@param type_names string[]
---@return lsp.CodeAction[]
function M.get_actions(context, params, type_names)
    if not context.cst or not context.decode_tree or #type_names == 0 then
        return {}
    end

    local row = params.range.start.line
    local col = params.range.start.character
    local ins_kind, node_id = tasks_insertion_ctx(context.cst, context.decode_tree, row, col)
    if not ins_kind then return {} end

    local buf_lines = context.lines
        or (context.bufnr and vim.api.nvim_buf_get_lines(context.bufnr, 0, -1, false))
        or {}

    local names = vim.deepcopy(type_names)
    table.sort(names)

    local actions = {}
    for _, type_name in ipairs(names) do
        local indent = ""
        if ins_kind == "array" and node_id then
            indent = array_item_indent(buf_lines, context.cst, node_id)
        end
        actions[#actions + 1] = {
            title   = "Add `" .. type_name .. "` task template",
            kind    = vim.lsp.protocol.CodeActionKind.RefactorExtract,
            command = {
                title     = "Add `" .. type_name .. "` task template",
                command   = "easytasks/insertTemplate",
                arguments = { {
                    uri       = params.textDocument.uri,
                    row       = row,
                    col       = col,
                    kind      = ins_kind,
                    type_name = type_name,
                    indent    = indent,
                } },
            },
        }
    end
    return actions
end

return M
