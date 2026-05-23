-- easytasks/toml/formatter.lua
local parser   = require("easytasks.toml.parser")
local NodeKind = require("easytasks.toml.NodeKind")
local M = {}

local function needs_quotes(key)
  return not key:match("^[A-Za-z0-9_%-]+$")
end

local function quote_key(key)
  if needs_quotes(key) then
    return '"' .. key:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
  end
  return key
end

local function format_keys(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    table.insert(parts, quote_key(k.value))
  end
  return table.concat(parts, ".")
end

local function format_string(s)
  if not s:find("'") and not s:find("[\n\r\t\\]") then
    return "'" .. s .. "'"
  end
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\b", "\\b")
  s = s:gsub("\t", "\\t")
  s = s:gsub("\n", "\\n")
  s = s:gsub("\f", "\\f")
  s = s:gsub("\r", "\\r")
  return '"' .. s .. '"'
end

local format_value

local function format_array(node, indent)
  if #node.items == 0 then return "[]" end

  if not node.multiline then
    local parts = {}
    for _, item in ipairs(node.items) do
      table.insert(parts, format_value(item, indent))
    end
    return "[ " .. table.concat(parts, ", ") .. " ]"
  end

  local inner_pad = string.rep("  ", indent + 1)
  local close_pad = string.rep("  ", indent)
  local lines = { "[" }
  for _, item in ipairs(node.items) do
    table.insert(lines, inner_pad .. format_value(item, indent + 1) .. ",")
  end
  table.insert(lines, close_pad .. "]")
  return table.concat(lines, "\n")
end

local function format_inline_table(node, indent)
  if #node.pairs == 0 then return "{}" end

  if not node.multiline then
    local parts = {}
    for _, pair in ipairs(node.pairs) do
      table.insert(parts, quote_key(pair.key.value) .. " = " .. format_value(pair.value, indent))
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end

  local inner_pad = string.rep("  ", indent + 1)
  local close_pad = string.rep("  ", indent)
  local lines = { "{" }
  for _, pair in ipairs(node.pairs) do
    local v = format_value(pair.value, indent + 1)
    table.insert(lines, inner_pad .. quote_key(pair.key.value) .. " = " .. v .. ",")
  end
  table.insert(lines, close_pad .. "}")
  return table.concat(lines, "\n")
end

format_value = function(node, indent)
  indent = indent or 0
  if not node then return '""' end
  if node.kind == NodeKind.Literal then
    local v = node.token.value
    if type(v) == "string" then
      return format_string(v)
    elseif type(v) == "boolean" then
      return tostring(v)
    elseif type(v) == "number" then
      if v ~= v then return "nan"
      elseif v == math.huge then return "inf"
      elseif v == -math.huge then return "-inf"
      end
      return tostring(v)
    elseif parser.is_date(v) then
      return tostring(v)
    else
      return tostring(v)
    end
  elseif node.kind == NodeKind.Array then
    return format_array(node, indent)
  elseif node.kind == NodeKind.InlineTable then
    return format_inline_table(node, indent)
  end
  return ""
end

local function format_kvp(node, indent)
  local line = quote_key(node.key.value) .. " = " .. format_value(node.value, indent or 0)
  if node.trailing_comment then
    line = line .. " " .. node.trailing_comment
  end
  return line
end

---@param ast easytasks.toml.Ast
function M.format(ast)
  local out = {}
  local roots = ast:get_roots()

  for i, root in ipairs(roots) do
    local node = root.data
    local id   = root.id

    if node.kind == NodeKind.TableSection or node.kind == NodeKind.PartialTableSection then
      if i > 1 then table.insert(out, "") end
      local header = "[" .. format_keys(node.keys) .. "]"
      if node.trailing_comment then header = header .. " " .. node.trailing_comment end
      table.insert(out, header)

      for _, child in ipairs(ast:get_children(id)) do
        local cn = child.data
        if cn.kind == NodeKind.KeyValuePair then
          table.insert(out, format_kvp(cn))
        elseif cn.kind == NodeKind.Comment then
          table.insert(out, cn.text)
        end
      end

    elseif node.kind == NodeKind.ArrayOfTablesSection or node.kind == NodeKind.PartialArrayOfTablesSection then
      if i > 1 then table.insert(out, "") end
      local header = "[[" .. format_keys(node.keys) .. "]]"
      if node.trailing_comment then header = header .. " " .. node.trailing_comment end
      table.insert(out, header)

      for _, child in ipairs(ast:get_children(id)) do
        local cn = child.data
        if cn.kind == NodeKind.KeyValuePair then
          table.insert(out, format_kvp(cn))
        elseif cn.kind == NodeKind.Comment then
          table.insert(out, cn.text)
        end
      end

    elseif node.kind == NodeKind.KeyValuePair then
      table.insert(out, format_kvp(node))

    elseif node.kind == NodeKind.Comment then
      table.insert(out, node.text)
    end
  end

  return table.concat(out, "\n")
end

return M
