local M          = {}

local s_util     = require("easytasks.toml.schema_util")
local utils      = require("easytasks.toml.validator_util")
local schema_nav = require("easytasks.toml.schema_nav")
local Ast        = require("easytasks.toml.Ast")

local NodeKind   = Ast.NodeKind
local CK         = vim.lsp.protocol.CompletionItemKind

-- Binary-search the AST root list for the last section node whose start is
-- <= (row, col).  Section ranges typically cover only the header line, so
-- containment is the wrong test; "the last header that opened before the cursor"
-- is what determines which section the cursor is in.
-- Returns nil when the cursor is before any section (root level).
---@param context easytasks.LspBufferContext
---@param row integer
---@param col integer
---@return easytasks.toml.TableSectionNode|easytasks.toml.ArrayOfTablesSectionNode|nil
local function section_at(context, row, col)
  local roots         = context.ast:get_roots()
  local lo, hi, found = 1, #roots, 0

  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local r   = roots[mid].data and roots[mid].data.range
    if r and (r[1] < row or (r[1] == row and r[2] <= col)) then
      found = mid; lo = mid + 1
    else
      hi = mid - 1
    end
  end

  -- Walk backward to the nearest section header that precedes the cursor.
  for i = found, 1, -1 do
    local node = roots[i].data
    if node and (node.kind == NodeKind.TableSection or node.kind == NodeKind.ArrayOfTablesSection) then
      ---@cast node easytasks.toml.TableSectionNode|easytasks.toml.ArrayOfTablesSectionNode
      return node
    end
  end

  return nil
end

-- Build the JSON Pointer path for a section node from its key list.
---@param sec easytasks.toml.TableSectionNode|easytasks.toml.ArrayOfTablesSectionNode
---@return string
local function section_path(sec)
  local parts = {}
  for _, kref in ipairs(sec.keys) do
    parts[#parts + 1] = kref.value
  end
  return #parts > 0 and utils.join_path_parts(parts) or ""
end

-- Resolve the flattened object schema that owns keys at (row, col).
---@param context easytasks.LspBufferContext
---@param row integer
---@param col integer
---@return table?
local function container_schema(context, row, col)
  local sec = section_at(context, row, col)

  if not sec then return nil end

  local s = schema_nav.schema_at(context.schema, context.data, section_path(sec))
  if sec.kind == NodeKind.ArrayOfTablesSection then
    return s and s.items and schema_nav.flatten(s.items, nil)
  end
  return s
end

---@param flat table
---@return lsp.CompletionItem[]
local function key_items(flat)
  local items = {}
  for _, entry in ipairs(s_util.get_ordered_properties(flat)) do
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

---@param prop_schema table?
---@return lsp.CompletionItem[]
local function value_items(prop_schema)
  if not prop_schema then return {} end
  local flat  = schema_nav.flatten(prop_schema, nil)
  local items = {}
  if flat.enum then
    for _, v in ipairs(flat.enum) do
      local text        = type(v) == "string" and v or tostring(v)
      local insert      = type(v) == "string" and ('"' .. v .. '"') or text
      items[#items + 1] = { label = text, kind = CK.EnumMember, insertText = insert }
    end
  elseif flat.type == "boolean" then
    items[#items + 1] = { label = "true", kind = CK.Value, insertText = "true" }
    items[#items + 1] = { label = "false", kind = CK.Value, insertText = "false" }
  end
  return items
end

---@param context easytasks.LspBufferContext
---@param params lsp.CompletionParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.CompletionList)
function M.handler(context, params, callback)
  callback = vim.schedule_wrap(callback)
  local empty = { isIncomplete = false, items = {} }
  if not context.schema then
    callback(nil, empty); return
  end

  local row = params.position.line
  local col = params.position.character

  local hit = context.ast:node_at(row, col)

  -- ── No node under cursor ──────────────────────────────────────────────────
  if not hit then
    local flat = container_schema(context, row, col)
    if not flat then
      callback(nil, empty); return
    end
    callback(nil, { isIncomplete = false, items = key_items(flat) }); return
  end

  local node = hit.node
  local kind = node.kind

  -- ── Section header line ───────────────────────────────────────────────────
  if kind == NodeKind.TableSection or kind == NodeKind.ArrayOfTablesSection
      or kind == NodeKind.PartialTableSection or kind == NodeKind.PartialArrayOfTablesSection then
    callback(nil, empty); return
  end

  -- ── Comment ───────────────────────────────────────────────────────────────
  if kind == NodeKind.Comment then
    callback(nil, empty); return
  end

  -- ── KeyValuePair ──────────────────────────────────────────────────────────
  if kind == NodeKind.KeyValuePair then
    local flat = container_schema(context, row, col)
    if not flat then
      callback(nil, empty); return
    end

    -- Value context: cursor is past the end column of the key token.
    if node.key and node.key.range and col > node.key.range[4] then
      local prop = flat.properties and flat.properties[node.key.value]
      callback(nil, { isIncomplete = false, items = value_items(prop) }); return
    end

    callback(nil, { isIncomplete = false, items = key_items(flat) }); return
  end

  -- ── InlineTable ───────────────────────────────────────────────────────────
  -- Cursor is inside `{ }` — find the parent KVP to resolve the table's schema.
  if kind == NodeKind.InlineTable then
    local parent_id  = context.ast:get_parent_id(hit.id)
    local parent_kvp = parent_id and context.ast:get_data(parent_id)
    if not parent_kvp or parent_kvp.kind ~= NodeKind.KeyValuePair then
      callback(nil, empty); return
    end
    local outer = container_schema(context, row, col)
    local prop   = outer and outer.properties and outer.properties[parent_kvp.key.value]
    if not prop then callback(nil, empty); return end
    local tbl_flat = schema_nav.flatten(prop, nil)
    callback(nil, { isIncomplete = false, items = key_items(tbl_flat) }); return
  end

  callback(nil, empty)
end

return M
