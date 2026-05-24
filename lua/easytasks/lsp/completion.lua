local M          = {}

local s_util     = require("easytasks.toml.schema_util")
local schema_nav = require("easytasks.toml.schema_nav")

local CK         = vim.lsp.protocol.CompletionItemKind

-- Resolve the flattened object schema that owns keys at (row, col).
-- When the cursor is on an incomplete key node, walks up to its parent.
---@param context easytasks.LspBufferContext
---@param row integer
---@param col integer
---@return table?
local function container_schema(context, row, col)
  local dt = context.decode_tree
  if not dt or not context.schema then return nil end

  local id = dt:pos_to_id(row, col)
  if not id then return nil end

  if dt:is_key_node(id) then
    id = dt:get_parent_id(id)
    if not id then return nil end
  end

  local path = dt:path_of(id)
  return schema_nav.schema_at(context.schema, context.data, path)
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

  local schema = container_schema(context, row, col)
  if not schema then
    callback(nil, empty); return
  end
  callback(nil, { isIncomplete = false, items = key_items(schema) }); return
end

return M
