local utils = require("easytasks.validate.validatorutils")

local M = {}

---@class easytasks.TomlParseResult
---@field ok boolean
---@field data table|nil
---@field pointer_map table<string, easytasks.Range4>
---@field syntax_errors easytasks.TomlSyntaxError[]
---@field err string|nil

---@class easytasks.TomlSyntaxError
---@field message string
---@field range easytasks.Range4

---@alias easytasks.Range4 { [1]: integer, [2]: integer, [3]: integer, [4]: integer }

---@param node TSNode
---@return easytasks.Range4
local function node_range(node)
  local sr, sc, er, ec = node:range()
  return { sr, sc, er, ec }
end

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
  if node:type() == "bare_key" or node:type() == "quoted_key" then
    return { node_text(bufnr, node) }
  end
  local keys = {}
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
  return table.concat(dotted_key_parts(bufnr, key_node), ".")
end

---@param ty string
---@return boolean
local function is_inline_value_type(ty)
  return ty == "string"
    or ty == "boolean"
    or ty == "integer"
    or ty == "float"
    or ty == "array"
    or ty == "inline_table"
    or ty == "offset_date_time"
    or ty == "local_date_time"
    or ty == "local_date"
    or ty == "local_time"
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

---@param bufnr integer
---@param node TSNode
---@return string|nil
local function parse_string(bufnr, node)
  local text = node_text(bufnr, node)
  local triple = text:match("^%[%[(.-)%]%]$")
  if triple then
    return triple
  end
  if text:sub(1, 1) == '"' then
    local ok, decoded = pcall(vim.json.decode, text)
    if ok and type(decoded) == "string" then
      return decoded
    end
    return text:match('^"(.*)"$') or text
  end
  if text:sub(1, 1) == "'" then
    return text:match("^'(.-)'$") or text
  end
  return text
end

---@param bufnr integer
---@param value_node TSNode
---@param pointer_map table<string, easytasks.Range4>
---@param path string[]
---@return any
local function parse_value(bufnr, value_node, pointer_map, path)
  pointer_map[utils.join_path_parts(path)] = node_range(value_node)

  local ty = value_node:type()
  if ty == "string" then
    return parse_string(bufnr, value_node)
  end
  if ty == "boolean" then
    return node_text(bufnr, value_node) == "true"
  end
  if ty == "integer" or ty == "float" then
    return tonumber(node_text(bufnr, value_node))
  end
  if ty == "array" then
    local items = {}
    for child in value_node:iter_children() do
      if child:type() == "value" then
        for value_child in child:iter_children() do
          items[#items + 1] = parse_value(bufnr, value_child, pointer_map, path)
        end
      elseif child:named() and child:type() ~= "comment" then
        items[#items + 1] = parse_value(bufnr, child, pointer_map, path)
      end
    end
    return items
  end
  if ty == "inline_table" then
    local tbl = {}
    for child in value_node:iter_children() do
      if child:type() == "pair" then
        M.apply_pair(bufnr, child, tbl, path, pointer_map)
      end
    end
    return tbl
  end
  for child in value_node:iter_children() do
    if child:named() then
      return parse_value(bufnr, child, pointer_map, path)
    end
  end
  return nil
end

---@param bufnr integer
---@param pair_node TSNode
---@return string?, TSNode?
local function pair_key_value_nodes(bufnr, pair_node)
  local key_node, value_node
  for child in pair_node:iter_children() do
    local ty = child:type()
    if ty == "bare_key" or ty == "quoted_key" or ty == "dotted_key" then
      key_node = child
    elseif ty == "value" or is_inline_value_type(ty) then
      value_node = child
    end
  end
  if not key_node or not value_node then
    return nil, nil
  end
  return key_name(bufnr, key_node), value_node
end

---@param root table
---@param path string[]
---@return table
local function table_at_path(root, path)
  local current = root
  for _, segment in ipairs(path) do
    current[segment] = current[segment] or {}
    current = current[segment]
  end
  return current
end

---@param bufnr integer
---@param pair_node TSNode
---@param target table
---@param base_path string[]
---@param pointer_map table<string, easytasks.Range4>
function M.apply_pair(bufnr, pair_node, target, base_path, pointer_map)
  local key, value_node = pair_key_value_nodes(bufnr, pair_node)
  if not key or not value_node then
    return
  end

  local path = vim.list_extend(vim.deepcopy(base_path), { key })
  local ptr = utils.join_path_parts(path)
  pointer_map[ptr] = node_range(pair_node)

  if value_node:type() == "value" then
    for value_child in value_node:iter_children() do
      target[key] = parse_value(bufnr, value_child, pointer_map, path)
      return
    end
  else
    target[key] = parse_value(bufnr, value_node, pointer_map, path)
  end
end

---@param bufnr integer
---@param table_node TSNode
---@param target table
---@param base_path string[]
---@param pointer_map table<string, easytasks.Range4>
local function apply_table(bufnr, table_node, target, base_path, pointer_map)
  local header_path = table_header_path(bufnr, table_node)
  local scope = target
  local scope_path = base_path

  if #header_path > 0 then
    scope = table_at_path(target, header_path)
    scope_path = header_path
    pointer_map[utils.join_path_parts(header_path)] = node_range(table_node)
  end

  for child in table_node:iter_children() do
    if child:type() == "pair" then
      M.apply_pair(bufnr, child, scope, scope_path, pointer_map)
    end
  end
end

---@param node TSNode
---@param out easytasks.TomlSyntaxError[]
local function collect_syntax_errors(node, out)
  if node:type() == "ERROR" then
    out[#out + 1] = {
      message = "Syntax error",
      range = node_range(node),
    }
  end
  for child in node:iter_children() do
    collect_syntax_errors(child, out)
  end
end

---@param bufnr integer
---@param root TSNode
---@param table_path string[]
---@return easytasks.Range4?
local function find_table_range(bufnr, root, table_path)
  for child in root:iter_children() do
    if child:type() == "table" and vim.deep_equal(table_header_path(bufnr, child), table_path) then
      return node_range(child)
    end
  end
  return nil
end

---@param bufnr integer
---@param root TSNode
---@param table_path string[]
---@param key string
---@return easytasks.Range4?
local function find_pair_range(bufnr, root, table_path, key)
  for child in root:iter_children() do
    if child:type() == "table" and vim.deep_equal(table_header_path(bufnr, child), table_path) then
      for pair in child:iter_children() do
        if pair:type() == "pair" then
          local pair_key = pair_key_value_nodes(bufnr, pair)
          if pair_key == key then
            return node_range(pair)
          end
        end
      end
    elseif child:type() == "pair" and #table_path == 0 then
      local pair_key = pair_key_value_nodes(bufnr, pair)
      if pair_key == key then
        return node_range(child)
      end
    end
  end
  return nil
end

---@param bufnr integer
---@param pointer string
---@param pointer_map table<string, easytasks.Range4>
---@return easytasks.Range4?
function M.range_for_pointer(bufnr, pointer, pointer_map)
  if pointer_map[pointer] then
    return pointer_map[pointer]
  end

  local parts = utils.split_path(pointer)
  if #parts == 0 then
    return pointer_map["/"]
  end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "toml")
  if not ok or not parser then
    return nil
  end

  local tree = parser:parse()[1]
  local root = tree and tree:root()
  if not root then
    return nil
  end

  if #parts >= 2 then
    local key = parts[#parts]
    local table_path = vim.list_slice(parts, 1, #parts - 1)
    local pair_range = find_pair_range(bufnr, root, table_path, key)
    if pair_range then
      return pair_range
    end
  end

  local table_range = find_table_range(bufnr, root, parts)
  if table_range then
    return table_range
  end

  if #parts >= 1 then
    local key = parts[#parts]
    local table_path = vim.list_slice(parts, 1, #parts - 1)
    return find_pair_range(bufnr, root, table_path, key)
      or find_table_range(bufnr, root, table_path)
      or pointer_map[utils.join_path_parts(table_path)]
  end

  return nil
end

---@param bufnr integer
---@return easytasks.TomlParseResult
function M.parse(bufnr)
  local pointer_map = {}
  local syntax_errors = {}

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "toml")
  if not ok or not parser then
    return {
      ok = false,
      data = nil,
      pointer_map = pointer_map,
      syntax_errors = syntax_errors,
      err = "tree-sitter toml parser not available",
    }
  end

  local tree = parser:parse()[1]
  local root = tree and tree:root()
  if not root then
    return {
      ok = false,
      data = nil,
      pointer_map = pointer_map,
      syntax_errors = syntax_errors,
      err = "failed to parse buffer",
    }
  end

  collect_syntax_errors(root, syntax_errors)

  local data = {}
  for child in root:iter_children() do
    if child:type() == "table" then
      apply_table(bufnr, child, data, {}, pointer_map)
    elseif child:type() == "pair" then
      M.apply_pair(bufnr, child, data, {}, pointer_map)
    end
  end

  pointer_map["/"] = { 0, 0, math.max(0, vim.api.nvim_buf_line_count(bufnr) - 1), 0 }

  return {
    ok = #syntax_errors == 0,
    data = data,
    pointer_map = pointer_map,
    syntax_errors = syntax_errors,
  }
end

return M
