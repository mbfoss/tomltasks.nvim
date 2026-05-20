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
-- Pure AST Public API Navigation Context Engine
--------------------------------------------------------------------------------

--- Navigates the tree strictly to find the node occupying the target line
---@param ast easytasks.util.Tree The Tree AST instance
---@param target_row integer
---@return table|nil active_node, string[] active_segments
local function get_context_node(ast, target_row)
  local active_segments = {}
  local active_node = nil

  -- Walk root nodes via sequential chain iteration API
  local current_id = ast._root_first
  while current_id do
    local ndata = ast:get_data(current_id)

    if ndata and (ndata.kind == "TableSection" or ndata.kind == "PartialTableSection") then
      if ndata.range and ndata.range[1] <= target_row then
        active_segments = {}
        if ndata.keys then
          for _, key_tok in ipairs(ndata.keys) do
            table.insert(active_segments, key_tok.value)
          end
        end
      end
    end

    if ndata and ndata.range and ndata.range[1] == target_row then
      active_node = ndata
    end

    -- Drill directly into block children nodes
    if ast:have_children(current_id) then
      local children = ast:get_children(current_id)
      for _, child in ipairs(children) do
        local cdata = child.data
        if cdata and cdata.range and cdata.range[1] == target_row then
          active_node = cdata
        end
      end
    end

    local current_node = ast._nodes[current_id]
    current_id = current_node and current_node.next_sibling or nil
  end

  return active_node, active_segments
end

--- Collects properties declared in the current table section up to the cursor line to avoid duplicates
---@param ast easytasks.util.Tree The Tree AST instance
---@param target_row integer
---@return table<string, boolean> existing_keys
local function get_sibling_keys_from_ast(ast, target_row)
  local existing_keys = {}
  if not ast or not ast._nodes then return existing_keys end

  local active_table_id = nil
  local current_id = ast._root_first

  while current_id do
    local ndata = ast:get_data(current_id)
    if ndata and (ndata.kind == "TableSection" or ndata.kind == "PartialTableSection") and ndata.range then
      if ndata.range[1] <= target_row then
        active_table_id = current_id
      end
    end
    local current_node = ast._nodes[current_id]
    current_id = current_node and current_node.next_sibling or nil
  end

  if active_table_id and ast:have_children(active_table_id) then
    local children = ast:get_children(active_table_id)
    for _, child in ipairs(children) do
      local cdata = child.data
      if cdata and (cdata.kind == "KeyValuePair" or cdata.kind == "PartialKeyValuePair") then
        if cdata.range and cdata.range[1] < target_row and cdata.key and cdata.key.value then
          existing_keys[cdata.key.value] = true
        end
      end
    end
  else
    -- Collect keys sitting directly on root level nodes
    local root_id = ast._root_first
    while root_id do
      local rdata = ast:get_data(root_id)
      if rdata and (rdata.kind == "KeyValuePair" or rdata.kind == "PartialKeyValuePair") then
        if rdata.range and rdata.range[1] < target_row and rdata.key and rdata.key.value then
          existing_keys[rdata.key.value] = true
        end
      end
      local root_node = ast._nodes[root_id]
      root_id = root_node and root_node.next_sibling or nil
    end
  end

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

  -- Extract line node and context track lists cleanly via API
  local node, active_segments = get_context_node(context.ast, row)

  local kind = (#active_segments > 0) and "table_key" or "root_key"
  local prefix = ""
  local active_key = nil

  -- Evaluate structural boundary token positions purely from graph data
  if node then
    if node.kind == "TableSection" or node.kind == "PartialTableSection" then
      kind = "table_header"
      local last_key = node.keys and node.keys[#node.keys]
      if last_key and col >= last_key.range[2] then
        prefix = last_key.value or ""
      end
    elseif node.kind == "PartialKeyValuePair" then
      if node.key and col >= node.key.range[2] then
        prefix = node.key.value or ""
      end
    elseif node.kind == "KeyValuePair" then
      -- Verify if cursor position sits past the right side of the assignment equals sign token
      if node.equals and node.equals.range and col >= node.equals.range[4] then
        kind = "table_value"
        active_key = node.key and node.key.value or nil

        -- Isolate value prefix targets if literal values are partially populated
        if node.value and node.value.range and col >= node.value.range[2] then
          if node.value.token and node.value.token.value then
            prefix = tostring(node.value.token.value)
          elseif node.value.kind == "Literal" and node.value.token then
            prefix = tostring(node.value.token.value)
          end
        else
          prefix = ""
        end
      else
        -- Cursor is to the left of the assignment operator, editing the key names
        if node.key and col >= node.key.range[2] then
          prefix = node.key.value or ""
        end
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

  -- Pull duplicate sibling blocks using structural node keys
  local existing_keys = get_sibling_keys_from_ast(context.ast, row)

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
