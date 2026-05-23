-- easytasks/toml/formatter.lua
local parser   = require("easytasks.toml.parser")
local NodeKind = require("easytasks.toml.NodeKind")
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
  if node.kind == NodeKind.Literal then
    local v = node.token.value
    if type(v) == "string" then return fmt_str(v)
    elseif type(v) == "boolean" then return tostring(v)
    elseif type(v) == "number" then return fmt_num(v)
    elseif parser.is_date(v) then return tostring(v)
    else return tostring(v or "null") end
  elseif node.kind == NodeKind.Array then
    if #node.items == 0 then return "[]" end
    local parts = {}
    for _, item in ipairs(node.items) do table.insert(parts, fmt_value(item)) end
    return "[" .. table.concat(parts, ", ") .. "]"
  elseif node.kind == NodeKind.InlineTable then
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
  [NodeKind.TableSection] = true, [NodeKind.ArrayOfTablesSection] = true,
  [NodeKind.PartialTableSection] = true, [NodeKind.PartialArrayOfTablesSection] = true,
}

function M.format(ast)
  local out = {}
  local prev_kind = nil

  ast:walk_tree(function(_, node, _)
    local k = node.kind

    if section_kinds[k] then
      if prev_kind ~= nil then
        -- Insert blank line before the section, pushing back past any
        -- comment block immediately preceding it so comments stay attached.
        local pos = #out + 1
        while pos > 1 and out[pos - 1]:match("^%s*#") do pos = pos - 1 end
        if pos > 1 and out[pos - 1] ~= "" then table.insert(out, pos, "") end
      end
      local bracket = (k == NodeKind.ArrayOfTablesSection or k == NodeKind.PartialArrayOfTablesSection)
        and "[[%s]]" or "[%s]"
      local line = bracket:format(fmt_keys(node.keys))
      if node.trailing_comment then line = line .. " " .. node.trailing_comment end
      table.insert(out, line)

    elseif k == NodeKind.Comment then
      table.insert(out, node.text)

    elseif k == NodeKind.KeyValuePair then
      if node.key and node.value then
        local line = fmt_key(node.key.value) .. " = " .. fmt_value(node.value)
        if node.trailing_comment then line = line .. " " .. node.trailing_comment end
        table.insert(out, line)
      end
    end

    prev_kind = k
    return true
  end)

  return table.concat(out, "\n")
end

return M
