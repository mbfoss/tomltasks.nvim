local M = {}

---@alias easytasks.JsonSchema table

---@param t string|string[]|nil
---@return string?
local function normalize_type(t)
  if t == nil then
    return nil
  end
  if type(t) == "table" then
    for _, v in ipairs(t) do
      if v ~= "null" then
        return v
      end
    end
    return t[1]
  end
  return t
end

---@param schema easytasks.JsonSchema
---@param path string[]
---@return easytasks.JsonSchema?
function M.at_path(schema, path)
  local node = schema
  for _, segment in ipairs(path) do
    if not node then
      return nil
    end
    if normalize_type(node.type) ~= "object" or not node.properties then
      return nil
    end
    node = node.properties[segment]
  end
  return node
end

---@param schema easytasks.JsonSchema
---@param path string[]
---@return easytasks.JsonSchema?
function M.parent_at_path(schema, path)
  if #path == 0 then
    return nil
  end
  local parent_path = vim.list_slice(path, 1, #path - 1)
  return M.at_path(schema, parent_path)
end

---@param node easytasks.JsonSchema
---@return { key: string, schema: easytasks.JsonSchema }[]
function M.ordered_properties(node)
  if not node or not node.properties then
    return {}
  end
  local props = node.properties
  local order = node["x-order"] or vim.tbl_keys(props)
  local seen = {}
  local result = {}

  local function add(key)
    if seen[key] or not props[key] then
      return
    end
    seen[key] = true
    result[#result + 1] = { key = key, schema = props[key] }
  end

  for _, key in ipairs(order) do
    add(key)
  end
  for key in vim.spairs(props) do
    add(key)
  end
  return result
end

---@param node easytasks.JsonSchema
---@param key string
---@return easytasks.JsonSchema?
function M.property(node, key)
  if not node or not node.properties then
    return nil
  end
  return node.properties[key]
end

---@param node easytasks.JsonSchema?
---@return boolean
function M.is_object(node)
  return node ~= nil and normalize_type(node.type) == "object"
end

---@param node easytasks.JsonSchema?
---@return boolean
function M.allows_additional(node)
  if not node then
    return true
  end
  return node.additionalProperties ~= false
end

---@param schema easytasks.JsonSchema
---@param path string[]
---@return string[][]
function M.table_paths(schema, path)
  local node = M.at_path(schema, path)
  if not M.is_object(node) then
    return {}
  end

  local paths = {}
  for _, entry in ipairs(M.ordered_properties(node)) do
    if M.is_object(entry.schema) then
      local child_path = vim.list_extend(vim.deepcopy(path), { entry.key })
      paths[#paths + 1] = child_path
      vim.list_extend(paths, M.table_paths(schema, child_path))
    end
  end
  return paths
end

---@param path string[]
---@return string
function M.path_label(path)
  if #path == 0 then
    return "(root)"
  end
  return table.concat(path, ".")
end

---@param path string[]
---@return string
function M.header_label(path)
  return "[" .. M.path_label(path) .. "]"
end

---@param prop easytasks.JsonSchema
---@return string
function M.default_toml(prop)
  if prop.default ~= nil then
    return M.lua_to_toml(prop.default)
  end

  local t = normalize_type(prop.type)
  if t == "string" then
    return '""'
  end
  if t == "boolean" then
    return "false"
  end
  if t == "array" then
    return "[]"
  end
  if t == "object" then
    return "{}"
  end
  if t == "integer" or t == "number" then
    return "0"
  end
  return '""'
end

---@param value any
---@return string
function M.lua_to_toml(value)
  local ty = type(value)
  if ty == "string" then
    return string.format("%q", value)
  end
  if ty == "boolean" then
    return value and "true" or "false"
  end
  if ty == "number" then
    return tostring(value)
  end
  if ty == "table" then
    if vim.islist(value) then
      if #value == 0 then
        return "[]"
      end
      local items = {}
      for _, item in ipairs(value) do
        items[#items + 1] = M.lua_to_toml(item)
      end
      return "{ " .. table.concat(items, ", ") .. " }"
    end
    local items = {}
    for k, v in pairs(value) do
      items[#items + 1] = string.format("%s = %s", k, M.lua_to_toml(v))
    end
    table.sort(items)
    return "{ " .. table.concat(items, ", ") .. " }"
  end
  return '""'
end

---@param node easytasks.JsonSchema?
---@return string[]
function M.required_keys(node)
  if not node or not node.required then
    return {}
  end
  return node.required
end

---@param node easytasks.JsonSchema?
---@return string?
function M.description(node)
  if not node then
    return nil
  end
  return node.description or node.title
end

---@param node easytasks.JsonSchema?
---@return string[]
function M.value_candidates(node)
  if not node then
    return {}
  end
  if node.enum then
    local out = {}
    for _, v in ipairs(node.enum) do
      out[#out + 1] = M.lua_to_toml(v)
    end
    return out
  end

  local t = normalize_type(node.type)
  if t == "boolean" then
    return { "true", "false" }
  end
  return {}
end

---@param prefix string
---@param label string
---@return boolean
function M.matches_filter(prefix, label)
  if prefix == "" then
    return true
  end
  return vim.startswith(label:lower(), prefix:lower())
end

---@param node easytasks.JsonSchema?
---@param key string
---@return boolean
function M.is_required(node, key)
  if not node or not node.required then
    return false
  end
  return vim.tbl_contains(node.required, key)
end

---@param schema easytasks.JsonSchema
---@return string?
function M.type_label(schema)
  local ty = schema.type
  if ty == nil then
    return nil
  end
  if type(ty) == "table" then
    return table.concat(ty, " | ")
  end
  return tostring(ty)
end

---@param node easytasks.JsonSchema?
---@return integer
function M.completion_kind(node)
  local t = normalize_type(node and node.type)
  if t == "boolean" then
    return vim.lsp.protocol.CompletionItemKind.Value
  end
  if t == "string" then
    return vim.lsp.protocol.CompletionItemKind.Text
  end
  if t == "array" then
    return vim.lsp.protocol.CompletionItemKind.Struct
  end
  if t == "object" then
    return vim.lsp.protocol.CompletionItemKind.Module
  end
  return vim.lsp.protocol.CompletionItemKind.Property
end

return M
