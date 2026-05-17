local schema_nav = require("easytasks.parse.schema_nav")
local toml_context = require("easytasks.parse.toml_context")

local M = {}

---@param prefix string
---@param label string
---@return boolean
local function matches_prefix(prefix, label)
  if prefix == "" then
    return true
  end
  return vim.startswith(label, prefix)
end

---@param bufnr integer
---@param row integer
---@return string
local function partial_header(bufnr, row)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  return line:match("%[([^%]]*)$") or ""
end

---@param ctx easytasks.TomlContext
---@param bufnr integer
---@param row integer
---@return lsp.CompletionItem[]
local function complete_table_headers(ctx, bufnr, row)
  local items = {}
  local prefix = partial_header(bufnr, row)
  if prefix == "" then
    prefix = ctx.prefix
  end
  local paths = schema_nav.table_paths(ctx.schema, {})
  for _, path in ipairs(paths) do
    local label = schema_nav.path_label(path)
    if matches_prefix(prefix, label) then
      local node = schema_nav.at_path(ctx.schema, path)
      items[#items + 1] = {
        label = label,
        kind = vim.lsp.protocol.CompletionItemKind.Module,
        detail = schema_nav.header_label(path),
        documentation = schema_nav.description(node),
        insertText = label,
      }
    end
  end
  return items
end

---@param ctx easytasks.TomlContext
---@param schema_node easytasks.JsonSchema
---@return lsp.CompletionItem[]
local function complete_keys(ctx, schema_node)
  local items = {}
  local existing = {}
  for _, key in ipairs(ctx.existing_keys) do
    existing[key] = true
  end

  for _, entry in ipairs(schema_nav.ordered_properties(schema_node)) do
    if not existing[entry.key] and matches_prefix(ctx.prefix, entry.key) then
      local ty = entry.schema.type
      if type(ty) == "table" then
        ty = table.concat(ty, " | ")
      end
      items[#items + 1] = {
        label = entry.key,
        kind = vim.lsp.protocol.CompletionItemKind.Property,
        detail = tostring(ty),
        documentation = schema_nav.description(entry.schema),
        insertText = entry.key,
      }
    end
  end
  return items
end

---@param ctx easytasks.TomlContext
---@return lsp.CompletionItem[]
local function complete_values(ctx)
  local items = {}
  local node = ctx.key_schema
  if not node then
    return items
  end

  for _, value in ipairs(schema_nav.value_candidates(node)) do
    if matches_prefix(ctx.prefix, value) then
      items[#items + 1] = {
        label = value,
        kind = schema_nav.completion_kind(node),
        insertText = value,
      }
    end
  end

  local default = schema_nav.default_toml(node)
  if matches_prefix(ctx.prefix, default) and #items == 0 then
    items[#items + 1] = {
      label = default,
      kind = schema_nav.completion_kind(node),
      detail = "default",
      insertText = default,
    }
  end
  return items
end

---@param params lsp.CompletionParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.CompletionList)
function M.handler(params, callback)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local row = params.position.line
  local col = params.position.character
  local ctx = toml_context.get(bufnr, row, col)

  local items = {}
  if ctx.kind == "table_header" then
    items = complete_table_headers(ctx, bufnr, row)
  elseif ctx.kind == "root_key" then
    items = complete_keys(ctx, ctx.schema)
  elseif ctx.kind == "table_key" then
    if ctx.schema_node then
      items = complete_keys(ctx, ctx.schema_node)
    end
  elseif ctx.kind == "table_value" then
    items = complete_values(ctx)
  end

  callback(nil, {
    isIncomplete = false,
    items = items,
  })
end

return M
