local M          = {}

local s_util     = require("easytasks.toml.schema_util")
local utils      = require("easytasks.toml.validator_util")
local schema_nav = require("easytasks.toml.schema_nav")
local Ast        = require("easytasks.toml.Ast")

local NodeKind   = Ast.NodeKind
local CK         = vim.lsp.protocol.CompletionItemKind

-- Walk up the AST from the node at (row, col) and build the JSON Pointer
-- for the container object.  Each KVP ancestor contributes its key; each
-- section header contributes its dotted key list.
-- Returns nil when no node covers the cursor (blank line, etc.).
---@param context easytasks.LspBufferContext
---@param row integer
---@param col integer
---@return string?
local function path_at(context, row, col)
  local hit = context.ast:node_at(row, col)
  if not hit then return nil end

  local parts      = {}
  local current_id = context.ast:get_parent_id(hit.id)

  while current_id do
    local node = context.ast:get_data(current_id)
    if not node then break end

    if node.kind == NodeKind.ArrayOfTablesSection
        or node.kind == NodeKind.TableSection then
      ---@cast node easytasks.toml.TableSectionNode|easytasks.toml.ArrayOfTablesSectionNode
      for i = #node.keys, 1, -1 do
        table.insert(parts, 1, node.keys[i].value)
      end
      break
    elseif node.kind == NodeKind.KeyValuePair then
      ---@cast node easytasks.toml.KeyValuePairNode
      table.insert(parts, 1, node.key.value)
    end
    -- InlineTable, Array, Comment: no path contribution, keep climbing.
    current_id = context.ast:get_parent_id(current_id)
  end

  if #parts == 0 then return "" end
  return utils.join_path_parts(parts)
end

-- Resolve the flattened object schema that owns keys at (row, col).
---@param context easytasks.LspBufferContext
---@param row integer
---@param col integer
---@return table?
local function container_schema(context, row, col)
  local path = path_at(context, row, col)
  if not path then return nil end

  local s = schema_nav.schema_at(context.schema, context.data, path)
  if s and s.items then
    return schema_nav.flatten(s.items, nil)
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

  -- ── No node under cursor (blank line, etc.) ───────────────────────────────
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
  if kind == NodeKind.InlineTable then
    local flat = container_schema(context, row, col)
    if not flat then
      callback(nil, empty); return
    end
    callback(nil, { isIncomplete = false, items = key_items(flat) }); return
  end

  callback(nil, empty)
end

return M
