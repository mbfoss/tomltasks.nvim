local M          = {}

local s_util     = require("easytasks.toml.schema_util")
local schema_nav = require("easytasks.toml.schema_nav")

local CK         = vim.lsp.protocol.CompletionItemKind

-- Resolve the flattened object schema that owns keys at (row, col).
---@param context easytasks.LspBufferContext
---@param row integer
---@param col integer
---@return table?
local function container_schema(context, row, col)
  return schema_nav.resolve_at(context.data, context.decode_tree, row, col, context.schema)
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

  local schema = container_schema(context, row, col)
  if not schema then
    callback(nil, empty); return
  end
  callback(nil, { isIncomplete = false, items = key_items(schema) }); return
end

return M
