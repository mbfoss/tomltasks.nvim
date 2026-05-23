-- easytasks/lsp/hover.lua
local M = {}

local s_util = require("easytasks.toml.schema_util")

--------------------------------------------------------------------------------
-- Markdown Formatting Helpers
--------------------------------------------------------------------------------

---@param node table?
---@return string|nil
local function hover_text(node)
  if not node then
    return nil
  end

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

  if #lines == 0 then
    return nil
  end
  return table.concat(lines, "\n\n")
end

--------------------------------------------------------------------------------
-- Hover Request Dispatcher
--------------------------------------------------------------------------------

---@param context easytasks.LspBufferContext buffer context
---@param params lsp.HoverParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.Hover)
function M.handler(context, params, callback)
  if not context.schema then
    callback(nil, nil)
    return
  end

  local row = params.position.line
  local col = params.position.character


  local contents = hover_text(schema_node)
  if not contents then
    callback(nil, nil)
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
