-- easytasks/lsp/completion.lua
local M = {}

local s_util = require("easytasks.toml.schema_util")

--------------------------------------------------------------------------------
-- LSP Range & Item Mapping Formatter Helpers
--------------------------------------------------------------------------------

local function replace_range(line, col, prefix, kind)
  if kind == "table_header" then
    local open = line:find("%[")
    if open and not line:find("%]", open) then
      return open, col + 1
    end
  end
  if prefix ~= "" then
    return col - #prefix, col
  end
  return col, col
end

local function text_edit(row, start_col, end_col, new_text)
  return {
    range = {
      start = { line = row, character = start_col },
      ["end"] = { line = row, character = end_col },
    },
    newText = new_text,
  }
end

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

local function sort_items(a, b)
  local ar = a.sortText == "0"
  local br = b.sortText == "0"
  if ar ~= br then
    return ar
  end
  return (a.label or "") < (b.label or "")
end

--------------------------------------------------------------------------------
-- AST Structural Context Extraction Helpers
--------------------------------------------------------------------------------

--- Inspects the bidirectional Tree AST structure to determine what structural element is under the cursor
---@param ast table The Tree AST instance
---@param target_row integer
---@param target_col integer
---@return string kind, string prefix, string|nil active_key, string[] active_segments,boolean row_node_found
local function inspect_context_from_ast(ast, target_row, target_col)
  local kind = "root_key"
  local prefix = ""
  local active_key = nil
  local active_segments = {}

  if not ast or type(ast.walk_tree) ~= "function" then
    return kind, prefix, active_key, active_segments, false
  end

  local row_node_found = false

  ast:walk_tree(function(_, node, _)
    -- 1. Track the current containing table context up to or on the current cursor row
    if (node.kind == "TableSection" or node.kind == "PartialTableSection") and node.range and node.range[1] <= target_row then
      active_segments = {}
      if node.keys then
        for _, key_tok in ipairs(node.keys) do
          table.insert(active_segments, key_tok.value)
        end
      end
    end

    -- 2. Process node logic matching the exact active editing line
    if node.range and node.range[1] == target_row then
      if node.kind == "PartialTableSection" then
        kind = "table_header"
        local last_key = node.keys and node.keys[#node.keys]
        prefix = last_key and last_key.value or ""
        row_node_found = true
      elseif node.kind == "PartialKeyValuePair" then
        kind = (#active_segments > 0) and "table_key" or "root_key"
        prefix = node.key and node.key.value or ""
        row_node_found = true
      elseif node.kind == "KeyValuePair" then
        -- Check if the cursor is past the '=' sign to decide if we are editing values
        if node.equals and node.equals.range and target_col >= node.equals.range[4] then
          kind = "table_value"
          active_key = node.key and node.key.value or nil
          if node.value and node.value.token then
            prefix = tostring(node.value.token.value)
          else
            prefix = ""
          end
        else
          kind = (#active_segments > 0) and "table_key" or "root_key"
          prefix = node.key and node.key.value or ""
        end
        row_node_found = true
      end
    end

    return true -- Continue walking
  end)

  -- Flag check context identifier context validation
  if kind == "root_key" and #active_segments > 0 then
    kind = "table_key"
  end

  return kind, prefix, active_key, active_segments, row_node_found
end

--- Collects properties declared in the current table section up to the cursor line to avoid duplicates
---@param ast table The Tree AST instance
---@param target_row integer
---@return table<string, boolean> existing_keys
local function get_sibling_keys_from_ast(ast, target_row)
  local existing_keys = {}
  if not ast or type(ast.walk_tree) ~= "function" then return existing_keys end

  local active_table_start_row = -1

  -- Locate the line index of the containing section block
  ast:walk_tree(function(_, node, _)
    if (node.kind == "TableSection" or node.kind == "PartialTableSection") and node.range then
      if node.range[1] <= target_row and node.range[1] > active_table_start_row then
        active_table_start_row = node.range[1]
      end
    end
    return true
  end)

  -- Gather keys matching that same parent block container scope boundaries
  local within_active_block = (active_table_start_row == -1)
  ast:walk_tree(function(_, node, _)
    if (node.kind == "TableSection" or node.kind == "PartialTableSection") and node.range then
      within_active_block = (node.range[1] == active_table_start_row)
    elseif node.kind == "KeyValuePair" or node.kind == "PartialKeyValuePair" then
      if within_active_block and node.range and node.range[1] <= target_row then
        if node.key and node.key.value and node.range[1] ~= target_row then
          existing_keys[node.key.value] = true
        end
      end
    end
    return true
  end)

  return existing_keys
end

--------------------------------------------------------------------------------
-- Completion Request Dispatcher
--------------------------------------------------------------------------------

---@param context easytasks.LspBufferContext buffer context
---@param params lsp.CompletionParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.CompletionList)
function M.handler(context, params, callback)
  local bufnr = context.bufnr or vim.uri_to_bufnr(params.textDocument.uri)
  local row = params.position.line
  local col = params.position.character

  if not context.schema or not context.ast then
    callback(nil, { isIncomplete = false, items = {} })
    return
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local line_before_cursor = line:sub(1, col)

  -- Determine state classifications explicitly using AST values first
  local kind, prefix, active_key, active_segments, ast_matched = inspect_context_from_ast(context.ast, row, col)

  -- Fallback logic parsing lines via string pattern evaluation if AST doesn't hold tracking data yet
  if not ast_matched then
    if line_before_cursor:match("%[[^%]]*$") then
      kind = "table_header"
      prefix = line_before_cursor:match("([^%.%[%s]+)$") or ""
    else
      local has_equals = line_before_cursor:find("=")
      if not has_equals then
        prefix = line_before_cursor:match("([%w%-_]+)$") or ""
        kind = (#active_segments > 0) and "table_key" or "root_key"
      else
        kind = "table_value"
        prefix = line_before_cursor:match("([^%s=]+)$") or ""
        active_key = line_before_cursor:match("^%s*([%w%-_]+)%s*=")
      end
    end
  end

  -- Track nested structural tree maps inside schema rules
  local schema_node = context.schema
  if #active_segments > 0 then
    for _, segment in ipairs(active_segments) do
      if schema_node and schema_node.properties and schema_node.properties[segment] then
        schema_node = schema_node.properties[segment]
      end
    end
  end

  -- Pull duplicate sibling blocks using structural node keys instead of regex captures
  local existing_keys = {}
  if kind == "table_key" or kind == "root_key" then
    existing_keys = get_sibling_keys_from_ast(context.ast, row)
  end

  -- Fetch current editor line metadata for textual insertion tracking points
  local items = {}
  local start_col, end_col = replace_range(line, col, prefix, kind)

  local function matches(pfx, target)
    if pfx == "" then return true end
    return s_util.matches_filter(pfx, target)
  end

  if kind == "table_header" then
    local paths = {}
    s_util.gather_table_paths(context.schema, "", paths)
    for _, entry in ipairs(paths) do
      if matches(prefix, entry.path) then
        items[#items + 1] = make_item(
          row, start_col, end_col,
          entry.path, entry.path,
          vim.lsp.protocol.CompletionItemKind.Module,
          "table block", s_util.get_description(entry.node)
        )
      end
    end
  elseif kind == "root_key" or kind == "table_key" then
    for _, entry in ipairs(s_util.get_ordered_properties(schema_node)) do
      if not existing_keys[entry.key] and matches(prefix, entry.key) then
        local detail = s_util.get_type_label(entry.schema)
        local default = s_util.get_default_toml(entry.schema)
        if s_util.is_required(schema_node, entry.key) then
          detail = detail and ("required · " .. detail) or "required"
        end
        if default ~= "" and default ~= '""' then
          detail = detail and (detail .. " · default " .. default) or ("default " .. default)
        end

        items[#items + 1] = make_item(
          row, start_col, end_col,
          entry.key, entry.key,
          vim.lsp.protocol.CompletionItemKind.Property,
          detail, s_util.get_description(entry.schema)
        )
        if s_util.is_required(schema_node, entry.key) then
          items[#items].sortText = "0"
        end
      end
    end
  elseif kind == "table_value" and active_key then
    local key_schema = schema_node and schema_node.properties and schema_node.properties[active_key]
    if key_schema then
      local t = s_util.get_type_label(key_schema)
      local item_kind = (t == "boolean") and vim.lsp.protocol.CompletionItemKind.Keyword or
          vim.lsp.protocol.CompletionItemKind.Value

      local candidates = {}
      if t == "boolean" then candidates = { "true", "false" } end
      if key_schema.enum then
        for _, v in ipairs(key_schema.enum) do
          table.insert(candidates, type(v) == "string" and string.format("%q", v) or tostring(v))
        end
      end

      for _, val in ipairs(candidates) do
        if matches(prefix, val) then
          items[#items + 1] = make_item(row, start_col, end_col, val, val, item_kind)
        end
      end

      local default = s_util.get_default_toml(key_schema)
      if default ~= "" and matches(prefix, default) then
        local seen = false
        for _, item in ipairs(items) do
          if item.label == default then
            seen = true
            break
          end
        end
        if not seen then
          items[#items + 1] = make_item(
            row, start_col, end_col,
            default, default, item_kind,
            "default", s_util.get_description(key_schema)
          )
        end
      end
    end
  end

  table.sort(items, sort_items)

  callback(nil, {
    isIncomplete = prefix ~= "",
    items = items,
  })
end

return M