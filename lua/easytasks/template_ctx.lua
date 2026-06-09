-- Helpers for detecting valid template insertion positions in the tasks CST.

local Cst = require("tomltools.toml.Cst")
local _K   = Cst.Kind

-- Returns the indentation of the first inline-table item inside an Array node,
-- falling back to two spaces if none exist yet.
---@param lines  string[]
---@param cst    tomltools.toml.Cst
---@param arr_id integer
---@return string
local function _array_item_indent(lines, cst, arr_id)
    for _, vd in cst:iter_values(arr_id) do
        if vd.kind == _K.InlineTable then
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
local function _tasks_insertion_ctx(cst, dt, row, col)
    local tok_id = cst:token_at(row, col)

    local anc = cst:ancestor_of_kind(tok_id, _K.Array, _K.InlineTable)
    if anc and cst:kind(anc) == _K.Array then
        local is_tasks = false
        local tag = cst:get_tag(anc)
        if tag then
            local parts = dt:key_parts_of(tag)
            is_tasks = #parts == 1 and parts[1] == "tasks"
        else
            local kvp_id = cst:ancestor_of_kind(anc, _K.KeyValuePair)
            if kvp_id then
                local keys = cst:get_keys(kvp_id)
                is_tasks = #keys == 1 and keys[1].value == "tasks"
            end
        end
        if is_tasks then return "array", anc end
    end

    if not cst:ancestor_of_kind(tok_id, _K.KeyValuePair) then
        local aot_id = cst:ancestor_of_kind(tok_id, _K.AotSection)
        if aot_id then
            local hdr_id = cst:first_child_of_kind(aot_id, _K.AotHeader)
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
                        if cst:kind(sib) == _K.KeyValuePair then kvp_after = true; break end
                        sib = cst:next_sibling_id(sib)
                    end
                    if not kvp_after then return "aot", aot_id end
                end
            end
        end
    end

    local trivial = {
        [_K.Whitespace] = true, [_K.Newline] = true,
        [_K.Comment]    = true, [_K.Document] = true,
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

M.tasks_insertion_ctx = _tasks_insertion_ctx
M.array_item_indent   = _array_item_indent

return M
