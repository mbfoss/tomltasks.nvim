local M          = {}

local s_util     = require("easytasks.toml.schema_util")
local utils      = require("easytasks.toml.validator_util")
local schema_nav = require("easytasks.toml.schema_nav")
local Ast        = require("easytasks.toml.Ast")

local NodeKind   = Ast.NodeKind
local CK         = vim.lsp.protocol.CompletionItemKind

-- Return the JSON Pointer for the enclosing object at (row, col).
-- Uses the decode_tree to locate the deepest node, then walks up if needed
-- until we find a schema node that has `properties` (i.e. is an object).
---@param context easytasks.LspBufferContext
---@param row     integer
---@param col     integer
---@return string
local function resolve_container(context, row, col)
  if not context.decode_tree then return "" end
  local path = context.decode_tree:pos_to_path(row, col)
  if not path then return "" end

  local s = schema_nav.schema_at(context.schema, context.data, path)
  if s and s.properties then return path end

  -- Cursor is on/near a leaf; use the parent object instead.
  local parts = utils.split_path(path)
  if #parts == 0 then return "" end
  table.remove(parts)
  if #parts == 0 then return "" end
  return utils.join_path_parts(parts)
end

-- Completion items for object keys in `flat`, filtered by `prefix`.
---@param flat   table
---@param prefix string
---@return lsp.CompletionItem[]
local function key_items(flat, prefix)
  local items = {}
  for _, entry in ipairs(s_util.get_ordered_properties(flat)) do
    local key, prop = entry.key, entry.schema
    if s_util.matches_filter(prefix, key) then
      items[#items + 1] = {
        label         = key,
        kind          = CK.Field,
        detail        = s_util.get_type_label(prop),
        documentation = s_util.get_description(prop),
        insertText    = key,
      }
    end
  end
  return items
end

-- Completion items for a value assignment: enums and booleans only.
---@param prop_schema table?
---@param prefix      string  text typed after `=`
---@return lsp.CompletionItem[]
local function value_items(prop_schema, prefix)
  if not prop_schema then return {} end
  local flat  = schema_nav.flatten(prop_schema, nil)
  local items = {}

  if flat.enum then
    for _, v in ipairs(flat.enum) do
      local text   = type(v) == "string" and v or tostring(v)
      local insert = type(v) == "string" and ('"' .. v .. '"') or text
      if s_util.matches_filter(prefix, text) then
        items[#items + 1] = { label = text, kind = CK.EnumMember, insertText = insert }
      end
    end
  elseif flat.type == "boolean" then
    for _, v in ipairs({ "true", "false" }) do
      if s_util.matches_filter(prefix, v) then
        items[#items + 1] = { label = v, kind = CK.Value, insertText = v }
      end
    end
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

  local row       = params.position.line
  local col       = params.position.character
  -- ── Key context (section / root level) ───────────────────────────────────
  local container = resolve_container(context, row, col)
  local flat      = schema_nav.schema_at(context.schema, context.data, container)
  if not flat then callback(nil, empty); return end

  -- Inspect the line up to the cursor to choose key vs value completion.
  local line   = vim.api.nvim_buf_get_lines(context.bufnr, row, row + 1, false)[1] or ""
  local prefix = line:sub(1, col)
  local eq_pos = prefix:find("=", 1, true)

  local items
  if eq_pos then
    -- Value context: suggest enum/bool values for the key being assigned.
    local key        = vim.trim(prefix:sub(1, eq_pos - 1))
    local val_prefix = vim.trim(prefix:sub(eq_pos + 1))
    local prop       = flat.properties and flat.properties[key]
    items = value_items(prop, val_prefix)
  else
    -- Key context: suggest property names for the current container object.
    items = key_items(flat, vim.trim(prefix))
  end

  callback(nil, { isIncomplete = false, items = items })
end

return M
