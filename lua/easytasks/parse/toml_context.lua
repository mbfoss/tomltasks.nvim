local schema_nav = require("easytasks.parse.schema_nav")

local M = {}

---@class easytasks.TomlContext
---@field kind "root_key"|"table_key"|"table_value"|"table_header"|"unknown"
---@field path string[] dotted table path for current scope
---@field key string|nil key on current pair, if any
---@field prefix string partial token being typed
---@field existing_keys string[] keys already present in current table scope
---@field schema easytasks.JsonSchema
---@field schema_node easytasks.JsonSchema|nil schema at current path
---@field key_schema easytasks.JsonSchema|nil schema for current key when known

---@param bufnr integer
---@param node TSNode
---@return string
local function node_text(bufnr, node)
  return vim.treesitter.get_node_text(node, bufnr)
end

---@param bufnr integer
---@param node TSNode
---@return string[]
local function dotted_key_parts(bufnr, node)
  local keys = {}
  if node:type() == "bare_key" or node:type() == "quoted_key" then
    return { node_text(bufnr, node) }
  end
  for child in node:iter_children() do
    local ty = child:type()
    if ty == "bare_key" or ty == "quoted_key" then
      keys[#keys + 1] = node_text(bufnr, child)
    elseif ty == "dotted_key" then
      vim.list_extend(keys, dotted_key_parts(bufnr, child))
    end
  end
  return keys
end

---@param bufnr integer
---@param key_node TSNode
---@return string
local function key_name(bufnr, key_node)
  if key_node:type() == "bare_key" or key_node:type() == "quoted_key" then
    return node_text(bufnr, key_node)
  end
  local parts = dotted_key_parts(bufnr, key_node)
  return table.concat(parts, ".")
end

---@param bufnr integer
---@param table_node TSNode
---@return string[]
local function table_header_path(bufnr, table_node)
  for child in table_node:iter_children() do
    local ty = child:type()
    if ty == "dotted_key" then
      return dotted_key_parts(bufnr, child)
    end
    if ty == "bare_key" or ty == "quoted_key" then
      return { node_text(bufnr, child) }
    end
    if ty == "table_header" then
      for header_child in child:iter_children() do
        local header_ty = header_child:type()
        if header_ty == "dotted_key" then
          return dotted_key_parts(bufnr, header_child)
        end
        if header_ty == "bare_key" or header_ty == "quoted_key" then
          return { node_text(bufnr, header_child) }
        end
      end
    end
  end
  return {}
end

---@param table_node TSNode
---@return TSNode?
local function table_header_key_node(table_node)
  for child in table_node:iter_children() do
    local ty = child:type()
    if ty == "bare_key" or ty == "quoted_key" or ty == "dotted_key" then
      return child
    end
  end
  return nil
end

---@param ancestor TSNode
---@param node TSNode
---@return boolean
local function node_under(ancestor, node)
  local cur = node
  while cur do
    if cur:id() == ancestor:id() then
      return true
    end
    cur = cur:parent()
  end
  return false
end

---@param bufnr integer
---@param table_node TSNode
---@return string[]
local function table_existing_keys(bufnr, table_node)
  local keys = {}
  for child in table_node:iter_children() do
    if child:type() == "pair" then
      for pair_child in child:iter_children() do
        if pair_child:type() == "bare_key"
            or pair_child:type() == "quoted_key"
            or pair_child:type() == "dotted_key"
        then
          keys[#keys + 1] = key_name(bufnr, pair_child)
          break
        end
      end
    end
  end
  return keys
end

---@param pair_node TSNode
---@param col integer
---@return "key"|"value"
local function pair_side(pair_node, col)
  for child in pair_node:iter_children() do
    if child:type() == "=" then
      local _, eq_col = child:range()
      if col <= eq_col then
        return "key"
      end
      return "value"
    end
  end
  return "key"
end

---@param line string
---@param col integer
---@return string
local function prefix_before_cursor(line, col)
  local head = line:sub(1, col + 1)
  local bare = head:match("([%w_%.%$%-]*)$")
  if bare then
    return bare
  end
  local quoted = head:match('"([^"]*)$')
  if quoted then
    return quoted
  end
  return ""
end

---@param bufnr integer
---@return string[]
local function root_existing_keys(bufnr)
  local keys = {}
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "toml")
  if not ok or not parser then
    return keys
  end
  local tree = parser:parse()[1]
  local root = tree and tree:root()
  if not root then
    return keys
  end
  for child in root:iter_children() do
    if child:type() == "pair" then
      for pair_child in child:iter_children() do
        if pair_child:type() == "bare_key"
            or pair_child:type() == "quoted_key"
            or pair_child:type() == "dotted_key"
        then
          keys[#keys + 1] = key_name(bufnr, pair_child)
          break
        end
      end
    end
  end
  return keys
end

---@param bufnr integer
---@param row integer
---@param col integer
---@return string[], string[], string[], "key"|"value"|"header"
local function fallback_context(bufnr, row, col)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, row, false)
  local path = {}
  for _, line in ipairs(lines) do
    local header = line:match("^%s*%[([^%]]+)%]%s*$")
    if header then
      path = vim.split(header, ".", { plain = true })
    end
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local prefix = prefix_before_cursor(line, col)

  if line:match("^%s*%[") and not line:match("%]") then
    return path, {}, prefix, "header"
  end

  local key = line:match("^%s*([%w_%.%$%-]+)%s*=")
  if key and col > (line:find("=") or 0) - 1 then
    return path, { key }, prefix, "value"
  end
  if key then
    return path, { key }, prefix, "key"
  end

  return path, {}, prefix, "key"
end

---@param bufnr integer
---@param row integer
---@param col integer
---@return easytasks.TomlContext
function M.get(bufnr, row, col)
  ---@type easytasks.JsonSchema
  local schema = M.schema

  local path = {}
  local key = nil
  local prefix = ""
  local existing_keys = {}
  local kind = "unknown"
  local key_schema = nil

  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  prefix = prefix_before_cursor(line, col)

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "toml")
  if not ok or not parser then
    local fb_path, fb_keys, fb_prefix, side = fallback_context(bufnr, row, col)
    path = fb_path
    key = fb_keys[1]
    prefix = fb_prefix
    if side == "header" then
      kind = "table_header"
    elseif #path == 0 and not key then
      kind = "root_key"
    elseif side == "value" then
      kind = "table_value"
    else
      kind = "table_key"
    end
  else
    local tree = parser:parse()[1]
    local root = tree and tree:root()
    local node = root and root:named_descendant_for_range(row, col, row, col)

    if node then
      local pair = nil
      local table_node = nil
      local cursor = node

      while cursor do
        local ty = cursor:type()
        if ty == "pair" and not pair then
          pair = cursor
        elseif ty == "table" and not table_node then
          table_node = cursor
        end
        cursor = cursor:parent()
      end

      local header_key = table_node and table_header_key_node(table_node)
      local in_table_header = header_key and node_under(header_key, node) and not pair

      if in_table_header then
        kind = "table_header"
        path = table_header_path(bufnr, table_node)
        if node:type() == "bare_key" or node:type() == "quoted_key" then
          prefix = node_text(bufnr, node)
        end
      elseif pair then
        for child in pair:iter_children() do
          if child:type() == "bare_key"
              or child:type() == "quoted_key"
              or child:type() == "dotted_key"
          then
            key = key_name(bufnr, child)
            break
          end
        end
        if table_node then
          path = table_header_path(bufnr, table_node)
          existing_keys = table_existing_keys(bufnr, table_node)
        end
        kind = pair_side(pair, col) == "value" and "table_value" or "table_key"
      elseif table_node then
        path = table_header_path(bufnr, table_node)
        existing_keys = table_existing_keys(bufnr, table_node)
        kind = "table_key"
      else
        kind = "root_key"
        existing_keys = root_existing_keys(bufnr)
      end
    else
      kind = #path == 0 and "root_key" or "table_key"
      if kind == "root_key" then
        existing_keys = root_existing_keys(bufnr)
      end
    end
  end

  local schema_node = schema_nav.at_path(schema, path)
  if key then
    key_schema = schema_nav.property(schema_node, key)
  end

  return {
    kind = kind,
    path = path,
    key = key,
    prefix = prefix,
    existing_keys = existing_keys,
    schema = schema,
    schema_node = schema_node,
    key_schema = key_schema,
  }
end

---@param schema easytasks.JsonSchema
function M.set_schema(schema)
  M.schema = schema
end

return M
