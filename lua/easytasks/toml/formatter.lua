-- easytasks/toml/formatter.lua
local parser = require("easytasks.toml.parser")
local M = {}

local function fmt_key(k)
  if k:match("^[A-Za-z0-9_%-]+$") then return k end
  return '"' .. k:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function fmt_keys(keys)
  local parts = {}
  for _, kt in ipairs(keys) do table.insert(parts, fmt_key(kt.value)) end
  return table.concat(parts, ".")
end

local function fmt_str(s)
  return '"' .. s
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\b", "\\b")
    :gsub("\t", "\\t")
    :gsub("\f", "\\f")
    :gsub("\r", "\\r")
    :gsub("\n", "\\n")
    .. '"'
end

local function fmt_num(n)
  if n ~= n then return "nan"
  elseif n == math.huge then return "inf"
  elseif n == -math.huge then return "-inf"
  else return tostring(n) end
end

local fmt_value

fmt_value = function(node)
  if not node then return "" end
  if node.kind == "Literal" then
    local v = node.token.value
    if type(v) == "string" then return fmt_str(v)
    elseif type(v) == "boolean" then return tostring(v)
    elseif type(v) == "number" then return fmt_num(v)
    elseif parser.is_date(v) then return tostring(v)
    else return tostring(v or "null") end
  elseif node.kind == "Array" then
    if #node.items == 0 then return "[]" end
    local parts = {}
    for _, item in ipairs(node.items) do table.insert(parts, fmt_value(item)) end
    return "[" .. table.concat(parts, ", ") .. "]"
  elseif node.kind == "InlineTable" then
    if #node.pairs == 0 then return "{}" end
    local parts = {}
    for _, pair in ipairs(node.pairs) do
      table.insert(parts, fmt_key(pair.key.value) .. " = " .. fmt_value(pair.value))
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end
  return ""
end

local section_kinds = {
  TableSection = true, ArrayOfTablesSection = true,
  PartialTableSection = true, PartialArrayOfTablesSection = true,
}

function M.format(ast)
  local out = {}
  local prev_kind = nil

  ast:walk_tree(function(_, node, _)
    local k = node.kind

    if section_kinds[k] then
      if prev_kind ~= nil then table.insert(out, "") end
      local bracket = (k == "ArrayOfTablesSection" or k == "PartialArrayOfTablesSection")
        and "[[%s]]" or "[%s]"
      table.insert(out, bracket:format(fmt_keys(node.keys)))

    elseif k == "KeyValuePair" then
      if node.key and node.value then
        table.insert(out, fmt_key(node.key.value) .. " = " .. fmt_value(node.value))
      end
    end

    prev_kind = k
    return true
  end)

  return table.concat(out, "\n")
end

return M
