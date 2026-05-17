local schema_nav = require("easytasks.parse.schema_nav")

local M = {}

---@param prop easytasks.JsonSchema
---@return boolean
local function emit_as_section(prop)
  return schema_nav.is_object(prop)
end

---@param prop easytasks.JsonSchema
---@param value any
---@return boolean
local function use_table_section(prop, value)
  if type(value) ~= "table" or vim.islist(value) then
    return false
  end
  return emit_as_section(prop)
end

---@param data table
---@param key string
---@param prop easytasks.JsonSchema
---@param parent easytasks.JsonSchema
---@return any
local function field_value(data, key, prop, parent)
  local value = data[key]
  if value ~= nil then
    return value
  end
  if schema_nav.is_required(parent, key) then
    if prop.default ~= nil then
      return prop.default
    end
    if emit_as_section(prop) then
      return {}
    end
  end
  return nil
end

---@param lines string[]
---@param data table
---@param schema easytasks.JsonSchema
---@param path string[]
---@param seen table<string, boolean>
local function emit_scalars(lines, data, schema, path, seen)
  for _, entry in ipairs(schema_nav.ordered_properties(schema)) do
    local key = entry.key
    if seen[key] then
      goto continue
    end
    local value = field_value(data, key, entry.schema, schema)
    if value == nil then
      goto continue
    end
    if use_table_section(entry.schema, value) then
      goto continue
    end
    seen[key] = true
    lines[#lines + 1] = ("%s = %s"):format(key, schema_nav.value_to_toml(value, entry.schema))
    ::continue::
  end
end

---@param lines string[]
---@param data table
---@param schema easytasks.JsonSchema
---@param path string[]
local function emit_sections(lines, data, schema, path)
  for _, entry in ipairs(schema_nav.ordered_properties(schema)) do
    local value = field_value(data, entry.key, entry.schema, schema)
    if not use_table_section(entry.schema, value) then
      goto continue
    end
    if #lines > 0 and lines[#lines] ~= "" then
      lines[#lines + 1] = ""
    end
    local section_path = vim.list_extend(vim.deepcopy(path), { entry.key })
    lines[#lines + 1] = schema_nav.header_label(section_path)
    local seen = {}
    emit_scalars(lines, value, entry.schema, section_path, seen)
    emit_sections(lines, value, entry.schema, section_path)
    ::continue::
  end
end

---@param data table
---@param schema easytasks.JsonSchema
---@return string
function M.format_data(data, schema)
  local lines = {}
  local seen = {}
  emit_scalars(lines, data, schema, {}, seen)
  emit_sections(lines, data, schema, {})
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

return M
