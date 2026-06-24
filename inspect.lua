-- Inspect a TOML document to find the structural context at a cursor position.

local Cst     = require("tomltools.Cst")
local parser  = require("tomltools.parser")
local decoder = require("tomltools.decoder")
local std     = require("tomltools.std")
local _K      = Cst.Kind

local M = {}

---@class tomltools.PathNode
---@field name   string        TOML key segment
---@field type   "array"|"aot"
---@field indent string?       indentation of existing items; present for "array" nodes

---@param lines  string[]
---@param cst    tomltools.Cst
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

--- Find the TOML structural path at the cursor.
--- Returns a list of PathNodes from outermost to innermost relevant container,
--- an empty list when the cursor is at document root (valid AoT insertion point),
--- or nil when parsing fails or the cursor is not at any insertable position.
---@param text string
---@param row  integer  0-indexed
---@param col  integer  0-indexed
---@return tomltools.PathNode[]?
function M.find_path(text, row, col)
    local parsed = parser.parse(text)
    if not parsed.cst then return nil end
    local decoded = decoder.decode(parsed.cst)
    local cst, dt = parsed.cst, decoded.decode_tree
    local lines   = std.split(text, "\n", { plain = true })

    local tok_id = cst:token_at(row, col)

    -- Cursor inside an Array (not inside an InlineTable within it).
    local anc = cst:ancestor_of_kind(tok_id, _K.Array, _K.InlineTable)
    if anc and cst:kind(anc) == _K.Array then
        local name
        local tag = cst:get_tag(anc)
        if tag and dt then
            local parts = dt:key_parts_of(tag)
            name = parts[#parts]
        else
            local kvp_id = cst:ancestor_of_kind(anc, _K.KeyValuePair)
            if kvp_id then
                local keys = cst:get_keys(kvp_id)
                name = keys[#keys] and keys[#keys].value
            end
        end
        if name then
            return { { name = name, type = "array", indent = _array_item_indent(lines, cst, anc) } }
        end
    end

    -- Cursor inside a [[key]] AoT section with no KVP following the cursor.
    if not cst:ancestor_of_kind(tok_id, _K.KeyValuePair) then
        local aot_id = cst:ancestor_of_kind(tok_id, _K.AotSection)
        if aot_id then
            local hdr_id = cst:first_child_of_kind(aot_id, _K.AotHeader)
            if hdr_id then
                local keys = cst:get_keys(hdr_id)
                if #keys >= 1 then
                    local anchor = tok_id ---@type integer?
                    while anchor and cst:parent_id(anchor) ~= aot_id do
                        anchor = cst:parent_id(anchor)
                    end
                    local kvp_after = false
                    local sib = anchor and cst:next_sibling_id(anchor)
                    while sib do
                        if cst:kind(sib) == _K.KeyValuePair then kvp_after = true; break end
                        sib = cst:next_sibling_id(sib)
                    end
                    if not kvp_after then
                        return { { name = keys[1].value, type = "aot" } }
                    end
                end
            end
        end
    end

    -- Cursor inside a [key.sub] table section — treat as between AoT entries.
    if not cst:ancestor_of_kind(tok_id, _K.KeyValuePair) then
        local tbl_id = cst:ancestor_of_kind(tok_id, _K.TableSection)
        if tbl_id then
            local hdr_id = cst:first_child_of_kind(tbl_id, _K.TableHeader)
            if hdr_id then
                local keys = cst:get_keys(hdr_id)
                if #keys >= 2 then
                    return { { name = keys[1].value, type = "aot" } }
                end
            end
        end
    end

    -- Cursor at document root (only trivia).
    local _trivial = {
        [_K.Whitespace] = true, [_K.Newline] = true,
        [_K.Comment]    = true, [_K.Document] = true,
    }

    ---@type integer?,boolean
    local cur, at_root = tok_id, true
    while cur do
        if not _trivial[cst:kind(cur)] then at_root = false; break end
        cur = cst:parent_id(cur)
    end
    if at_root then return {} end

    return nil
end

return M
