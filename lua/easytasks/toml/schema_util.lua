-- easytasks/toml/schema_util.lua
local M = {}

function M.matches_filter(prefix, target)
  if not prefix or prefix == "" then return true end
  return target:lower():sub(1, #prefix) == prefix:lower()
end

function M.get_description(node)
  return node and node.description or ""
end

function M.get_type_label(node)
  if not node or not node.type then return "any" end
  if type(node.type) == "table" then
    local clean = {}
    for _, t in ipairs(node.type) do
      if t ~= "null" then table.insert(clean, t) end
    end
    return table.concat(clean, "|")
  end
  return tostring(node.type)
end

function M.get_default_toml(node)
  if not node or node.default == nil then return "" end
  if type(node.default) == "string" then
    return string.format("%q", node.default)
  elseif type(node.default) == "table" then
    return vim.inspect(node.default):gsub("%s+", "")
  end
  return tostring(node.default)
end

function M.is_required(parent_node, key)
  if not parent_node or not parent_node.required then return false end
  for _, req in ipairs(parent_node.required) do
    if req == key then return true end
  end
  return false
end

function M.get_ordered_properties(node)
  if not node or not node.properties then return {} end
  local result = {}

  if node["x-order"] then
    for _, key in ipairs(node["x-order"]) do
      if node.properties[key] then
        table.insert(result, { key = key, schema = node.properties[key] })
      end
    end
  else
    for key, prop in pairs(node.properties) do
      table.insert(result, { key = key, schema = prop })
    end
    table.sort(result, function(a, b) return a.key < b.key end)
  end
  return result
end

function M.gather_table_paths(node, current_path, results)
  if not node or node.type ~= "object" or not node.properties then return end

  for key, prop in pairs(node.properties) do
    if prop.type == "object" or (type(prop.type) == "table" and vim.tbl_contains(prop.type, "object")) then
      local next_path = current_path == "" and key or (current_path .. "." .. key)
      table.insert(results, { path = next_path, node = prop })
      M.gather_table_paths(prop, next_path, results)
    end
  end
end

-- Collect paths suitable for [[array-of-tables]] headers.
function M.gather_array_table_paths(node, current_path, results)
  if not node or not node.properties then return end

  for key, prop in pairs(node.properties) do
    local is_array = prop.type == "array"
        or (type(prop.type) == "table" and vim.tbl_contains(prop.type, "array"))
    if is_array and prop.items then
      local items = prop.items
      local items_is_obj = items.type == "object"
          or (type(items.type) == "table" and vim.tbl_contains(items.type, "object"))
      if items_is_obj then
        local next_path = current_path == "" and key or (current_path .. "." .. key)
        table.insert(results, { path = next_path, node = items })
        M.gather_array_table_paths(items, next_path, results)
      end
    end
  end
end

return M
