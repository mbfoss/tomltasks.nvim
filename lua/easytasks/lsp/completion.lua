local schema_nav = require("easytasks.parse.schema_nav")
local toml_context = require("easytasks.parse.toml_context")

local M = {}

---@param line string
---@param col integer
---@param prefix string
---@param kind easytasks.TomlContext["kind"]
---@return integer start_col, integer end_col
local function replace_range(line, col, prefix, kind)
  if kind == "table_header" then
    local open = line:find("%[")
    if open and not line:find("%]", open) then
      return open, col + 1
    end
  end
  if prefix ~= "" then
    return col + 1 - #prefix, col + 1
  end
  return col + 1, col + 1
end

---@param row integer
---@param start_col integer
---@param end_col integer
---@param new_text string
---@return lsp.TextEdit
local function text_edit(row, start_col, end_col, new_text)
  return {
    range = {
      start = { line = row, character = start_col },
      ["end"] = { line = row, character = end_col },
    },
    newText = new_text,
  }
end

---@param row integer
---@param start_col integer
---@param end_col integer
---@param new_text string
---@param label string
---@param kind integer
---@param detail? string
---@param documentation? string
---@return lsp.CompletionItem
local function make_item(row, start_col, end_col, new_text, label, kind, detail, documentation)
  return {
    label = label,
    kind = kind,
    detail = detail,
    documentation = documentation,
    insertText = new_text,
    textEdit = text_edit(row, start_col, end_col, new_text),
  }
end

---@param a lsp.CompletionItem
---@param b lsp.CompletionItem
---@return boolean
local function sort_items(a, b)
  local ar = a.sortText == "0"
  local br = b.sortText == "0"
  if ar ~= br then
    return ar
  end
  return (a.label or "") < (b.label or "")
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
---@param col integer
---@param line string
---@return lsp.CompletionItem[]
local function complete_table_headers(ctx, bufnr, row, col, line)
  local items = {}
  local prefix = partial_header(bufnr, row)
  if prefix == "" then
    prefix = ctx.prefix
  end
  local start_col, end_col = replace_range(line, col, prefix, "table_header")

  local paths = schema_nav.table_paths(ctx.schema, {})
  for _, path in ipairs(paths) do
    local label = schema_nav.path_label(path)
    if schema_nav.matches_filter(prefix, label) then
      local node = schema_nav.at_path(ctx.schema, path)
      items[#items + 1] = make_item(
        row,
        start_col,
        end_col,
        label,
        label,
        vim.lsp.protocol.CompletionItemKind.Module,
        schema_nav.header_label(path),
        schema_nav.description(node)
      )
    end
  end
  return items
end

---@param ctx easytasks.TomlContext
---@param schema_node easytasks.JsonSchema
---@param row integer
---@param col integer
---@param line string
---@return lsp.CompletionItem[]
local function complete_keys(ctx, schema_node, row, col, line)
  local items = {}
  local existing = {}
  for _, key in ipairs(ctx.existing_keys) do
    existing[key] = true
  end

  local start_col, end_col = replace_range(line, col, ctx.prefix, ctx.kind)

  for _, entry in ipairs(schema_nav.ordered_properties(schema_node)) do
    if not existing[entry.key] and schema_nav.matches_filter(ctx.prefix, entry.key) then
      local detail = schema_nav.type_label(entry.schema)
      local default = schema_nav.default_toml(entry.schema)
      if schema_nav.is_required(schema_node, entry.key) then
        detail = detail and ("required · " .. detail) or "required"
      end
      if default ~= "" and default ~= '""' then
        detail = detail and (detail .. " · default " .. default) or ("default " .. default)
      end
      items[#items + 1] = make_item(
        row,
        start_col,
        end_col,
        entry.key,
        entry.key,
        vim.lsp.protocol.CompletionItemKind.Property,
        detail,
        schema_nav.description(entry.schema)
      )
      if schema_nav.is_required(schema_node, entry.key) then
        items[#items].sortText = "0"
      end
    end
  end
  return items
end

---@param ctx easytasks.TomlContext
---@param row integer
---@param col integer
---@param line string
---@return lsp.CompletionItem[]
local function complete_values(ctx, row, col, line)
  local items = {}
  local node = ctx.key_schema
  if not node then
    return items
  end

  local start_col, end_col = replace_range(line, col, ctx.prefix, ctx.kind)
  local kind = schema_nav.completion_kind(node)

  for _, value in ipairs(schema_nav.value_candidates(node)) do
    if schema_nav.matches_filter(ctx.prefix, value) then
      items[#items + 1] = make_item(row, start_col, end_col, value, value, kind)
    end
  end

  local default = schema_nav.default_toml(node)
  if schema_nav.matches_filter(ctx.prefix, default) then
    local seen = {}
    for _, item in ipairs(items) do
      seen[item.label] = true
    end
    if not seen[default] then
      items[#items + 1] = make_item(
        row,
        start_col,
        end_col,
        default,
        default,
        kind,
        "default",
        schema_nav.description(node)
      )
    end
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
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""

  local items = {}
  if ctx.kind == "table_header" then
    items = complete_table_headers(ctx, bufnr, row, col, line)
  elseif ctx.kind == "root_key" then
    items = complete_keys(ctx, ctx.schema, row, col, line)
  elseif ctx.kind == "table_key" and ctx.schema_node then
    items = complete_keys(ctx, ctx.schema_node, row, col, line)
  elseif ctx.kind == "table_value" then
    items = complete_values(ctx, row, col, line)
  elseif ctx.kind == "unknown" then
    items = complete_keys(ctx, ctx.schema, row, col, line)
  end

  table.sort(items, sort_items)

  callback(nil, {
    isIncomplete = ctx.prefix ~= "",
    items = items,
  })
end

return M
