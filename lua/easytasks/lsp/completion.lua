local M          = {}

local s_util     = require("easytasks.toml.schema_util")
local schema_nav = require("easytasks.toml.schema_nav")

local CK         = vim.lsp.protocol.CompletionItemKind

---@param context easytasks.LspBufferContext
---@param row integer
---@param col integer
---@return integer? id
---@return table?   schema
local function resolve(context, row, col)
  local dt = context.decode_tree
  if not dt or not context.schema then return nil, nil end
  local id = dt:pos_to_id(row, col)
  if not id then return nil, nil end
  return id, schema_nav.schema_at(context.schema, context.data, dt, id)
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

-- Build value completion items from a schema's enum or boolean type.
-- Returns nil when the schema offers no enumerable values.
---@param schema table
---@return lsp.CompletionItem[]?
local function value_items(schema)
  if not schema then return nil end
  if schema.enum then
    local items = {}
    for _, v in ipairs(schema.enum) do
      local insert = type(v) == "string" and ('"' .. v .. '"') or tostring(v)
      items[#items + 1] = {
        label      = tostring(v),
        kind       = CK.Value,
        detail     = s_util.get_type_label(schema),
        insertText = insert,
      }
    end
    return #items > 0 and items or nil
  end
  local t = schema.type
  if t == "boolean" or (type(t) == "table" and vim.tbl_contains(t, "boolean")) then
    return {
      { label = "true",  kind = CK.Value, insertText = "true" },
      { label = "false", kind = CK.Value, insertText = "false" },
    }
  end
  return nil
end

---@param context easytasks.LspBufferContext
---@param params lsp.CompletionParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.CompletionList)
function M.handler(context, params, callback)
  callback = vim.schedule_wrap(callback)
  local empty = { isIncomplete = false, items = {} }
  if not context.schema then callback(nil, empty); return end

  local row = params.position.line
  local col = params.position.character
  local dt  = context.decode_tree

  local id, schema = resolve(context, row, col)

  -- Value completion: cursor is past the key token of a KVP
  if id and dt:cursor_on_value(id, row, col) then
    local items = schema and value_items(schema) or nil
    if items then callback(nil, { isIncomplete = false, items = items }); return end
  end

  -- Key completion: cursor is on a key position; walk up from key-only nodes
  if id then
    local lookup_id = (dt:is_key_node(id) and dt:get_parent_id(id)) or id
    if lookup_id then
      local flat = schema_nav.schema_at(context.schema, context.data, dt, lookup_id)
      if flat then callback(nil, { isIncomplete = false, items = key_items(flat) }); return end
    end
  end

  callback(nil, empty)
end

return M
