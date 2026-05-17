local schema_nav = require("easytasks.parse.schema_nav")
local toml_context = require("easytasks.parse.toml_context")
local toml_parse = require("easytasks.parse.toml_parse")

local M = {}

---@param bufnr integer
---@param row integer
---@param lines string[]
---@return lsp.TextEdit[]
local function insert_lines_edit(bufnr, row, lines)
  local line = (vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or "")
  return {
    {
      newText = (#line > 0 and "\n" or "") .. table.concat(lines, "\n") .. "\n",
      range = {
        start = { line = row, character = 0 },
        ["end"] = { line = row, character = 0 },
      },
    },
  }
end

---@param ctx easytasks.TomlContext
---@param bufnr integer
---@return lsp.CodeAction[]
local function missing_required_actions(ctx, bufnr)
  local actions = {}
  local schema_node = ctx.schema_node
  if not schema_node then
    return actions
  end

  local existing = {}
  for _, key in ipairs(ctx.existing_keys) do
    existing[key] = true
  end

  local row = toml_parse.table_end_row(bufnr, ctx.path)
  for _, key in ipairs(schema_nav.required_keys(schema_node)) do
    if not existing[key] then
      local prop = schema_nav.property(schema_node, key)
      if prop then
        local line = ("%s = %s"):format(key, schema_nav.default_toml(prop))
        actions[#actions + 1] = {
          title = ("Add required key: %s"):format(key),
          kind = "quickfix",
          edit = {
            changes = {
              [vim.uri_from_bufnr(bufnr)] = insert_lines_edit(bufnr, row, { line }),
            },
          },
        }
      end
    end
  end
  return actions
end

---@param ctx easytasks.TomlContext
---@param bufnr integer
---@param row integer
---@return lsp.CodeAction[]
local function apply_default_actions(ctx, bufnr, row)
  local actions = {}
  if ctx.kind ~= "table_value" or not ctx.key or not ctx.key_schema then
    return actions
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local eq = line:find("=")
  if not eq then
    return actions
  end

  local default = schema_nav.default_toml(ctx.key_schema)
  actions[#actions + 1] = {
    title = ("Set default for %s"):format(ctx.key),
    kind = "quickfix",
    edit = {
      changes = {
        [vim.uri_from_bufnr(bufnr)] = {
          {
            newText = "= " .. default,
            range = {
              start = { line = row, character = eq - 1 },
              ["end"] = { line = row, character = #line },
            },
          },
        },
      },
    },
  }
  return actions
end

---@param params lsp.CodeActionParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.CodeAction[])
function M.handler(params, callback)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local row = params.range.start.line
  local col = params.range.start.character
  local ctx = toml_context.get(bufnr, row, col)

  local actions = {}
  vim.list_extend(actions, missing_required_actions(ctx, bufnr))
  vim.list_extend(actions, apply_default_actions(ctx, bufnr, row))

  callback(nil, actions)
end

return M
