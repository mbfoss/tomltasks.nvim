-- easytasks/lsp/hover.lua
local M = {}

local s_util   = require("easytasks.toml.schema_util")
local utils    = require("easytasks.toml.validatorutils")
local NodeKind = require("lua.easytasks.toml.parser_util").NodeKind

--------------------------------------------------------------------------------
-- Markdown Formatting Helpers
--------------------------------------------------------------------------------

---@param node table?
---@return string|nil
local function hover_text(node)
  if not node then return nil end

  local lines = {}
  if node.title then
    lines[#lines + 1] = "**" .. node.title .. "**"
  end
  if node.description then
    lines[#lines + 1] = node.description
  end

  local type_label = s_util.get_type_label(node)
  if type_label ~= "any" then
    lines[#lines + 1] = ("Type: `%s`"):format(type_label)
  end

  local default_val = s_util.get_default_toml(node)
  if default_val ~= "" then
    lines[#lines + 1] = ("Default: `%s`"):format(default_val)
  end

  if node.required and #node.required > 0 then
    lines[#lines + 1] = "Required keys: " .. table.concat(node.required, ", ")
  end

  if #lines == 0 then return nil end
  return table.concat(lines, "\n\n")
end

--------------------------------------------------------------------------------
-- Path Building
--------------------------------------------------------------------------------

-- Returns the 1-based index of section_id among root-level AOT nodes sharing
-- the same dot-joined key path.
---@param ast easytasks.toml.Ast
---@param section_id any
---@param section_node easytasks.toml.ArrayOfTablesSectionNode
---@return integer
local function get_aot_index(ast, section_id, section_node)
  local target_path = table.concat(
    vim.tbl_map(function(k) return k.value end, section_node.keys), ".")
  local idx = 0
  for id, data in ast:iter_roots() do
    if data and (data.kind == NodeKind.ArrayOfTablesSection or data.kind == NodeKind.PartialArrayOfTablesSection) then
      local this_path = table.concat(
        vim.tbl_map(function(k) return k.value end, data.keys), ".")
      if this_path == target_path then
        idx = idx + 1
        if id == section_id then return idx end
      end
    end
  end
  return idx
end

-- Build a JSON Pointer path for a tree node by walking up to the root.
-- KeyValuePairs contribute their key, TableSections contribute their key
-- segments, and ArrayOfTablesSections contribute their key segments plus a
-- 1-based array index.
---@param ast easytasks.toml.Ast
---@param node_id any
---@return string|nil
local function build_path(ast, node_id)
  local segments = {}
  local current_id = node_id

  while current_id do
    local n = ast:get_data(current_id)
    local parent_id = ast:get_parent_id(current_id)

    if n.kind == NodeKind.KeyValuePair then
      table.insert(segments, 1, n.key.value)
    elseif n.kind == NodeKind.TableSection or n.kind == NodeKind.PartialTableSection then
      for i = #n.keys, 1, -1 do
        table.insert(segments, 1, n.keys[i].value)
      end
    elseif n.kind == NodeKind.ArrayOfTablesSection or n.kind == NodeKind.PartialArrayOfTablesSection then
      local idx = get_aot_index(ast, current_id, n)
      table.insert(segments, 1, tostring(idx))
      for i = #n.keys, 1, -1 do
        table.insert(segments, 1, n.keys[i].value)
      end
    end
    -- Comments contribute nothing to the path

    current_id = parent_id
  end

  if #segments == 0 then return nil end
  return utils.join_path_parts(segments)
end

--------------------------------------------------------------------------------
-- Hover Request Dispatcher
--------------------------------------------------------------------------------

---@param context easytasks.LspBufferContext
---@param params lsp.HoverParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.Hover)
function M.handler(context, params, callback)
  if not context.schema then
    callback(nil, nil)
    return
  end

  local row = params.position.line
  local col = params.position.character

  local result = context.ast:node_at(row, col)
  if not result then
    callback(nil, nil)
    return
  end

  local path = build_path(context.ast, result.id)
  if not path then
    callback(nil, nil)
    return
  end

  local schema_node = context.decode_tree and context.decode_tree:get_schema(path) or nil

  local contents = hover_text(schema_node)
  if not contents then
    callback(nil, {
      contents = {
        kind = "markdown",
        value = "No documentation for " .. path,
      },
    })
    return
  end

  callback(nil, {
    contents = {
      kind = "markdown",
      value = contents,
    },
  })
end

return M
