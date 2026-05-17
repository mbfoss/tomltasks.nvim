local schema_nav = require("easytasks.parse.schema_nav")
local toml_context = require("easytasks.parse.toml_context")

local M = {}

---@param node easytasks.JsonSchema?
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
  if node.type then
    local ty = node.type
    if type(ty) == "table" then
      ty = table.concat(ty, " | ")
    end
    lines[#lines + 1] = ("Type: `%s`"):format(ty)
  end
  if node.default ~= nil then
    lines[#lines + 1] = ("Default: `%s`"):format(schema_nav.lua_to_toml(node.default))
  end
  if node.required then
    lines[#lines + 1] = "Required keys: " .. table.concat(node.required, ", ")
  end
  if #lines == 0 then
    return nil
  end
  return table.concat(lines, "\n\n")
end

---@param params lsp.HoverParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.Hover)
function M.handler(params, callback)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local row = params.position.line
  local col = params.position.character
  local ctx = toml_context.get(bufnr, row, col)

  local node = ctx.key_schema or ctx.schema_node
  if ctx.kind == "root_key" or ctx.kind == "table_key" then
    if ctx.key then
      node = schema_nav.property(ctx.schema_node or ctx.schema, ctx.key)
    elseif ctx.schema_node then
      node = ctx.schema_node
    else
      node = ctx.schema
    end
  end

  if ctx.kind == "table_header" and #ctx.path > 0 then
    node = schema_nav.at_path(ctx.schema, ctx.path)
  end

  local contents = hover_text(node)
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
