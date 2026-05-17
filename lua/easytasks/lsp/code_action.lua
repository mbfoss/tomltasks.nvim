local schema_nav = require("easytasks.parse.schema_nav")
local toml_context = require("easytasks.parse.toml_context")

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

---@param bufnr integer
---@param path string[]
---@return integer
local function table_insert_row(bufnr, path)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "toml")
  if ok and parser then
    local tree = parser:parse()[1]
    local root = tree and tree:root()
    if root then
      for child in root:iter_children() do
        if child:type() ~= "table" then
          goto continue
        end
        local header = {}
        for header_child in child:iter_children() do
          local ty = header_child:type()
          if ty == "dotted_key" then
            for part in header_child:iter_children() do
              if part:type() == "bare_key" or part:type() == "quoted_key" then
                header[#header + 1] = vim.treesitter.get_node_text(part, bufnr)
              end
            end
          elseif ty == "bare_key" or ty == "quoted_key" then
            header = { vim.treesitter.get_node_text(header_child, bufnr) }
          elseif ty == "table_header" then
            for dotted in header_child:iter_children() do
              if dotted:type() == "dotted_key" then
                for part in dotted:iter_children() do
                  if part:type() == "bare_key" or part:type() == "quoted_key" then
                    header[#header + 1] = vim.treesitter.get_node_text(part, bufnr)
                  end
                end
              elseif dotted:type() == "bare_key" or dotted:type() == "quoted_key" then
                header = { vim.treesitter.get_node_text(dotted, bufnr) }
              end
            end
          end
          if #header > 0 then
            break
          end
        end
        if vim.deep_equal(header, path) then
          local _, _, er, _ = child:range()
          return er
        end
        ::continue::
      end
    end
  end
  return vim.api.nvim_buf_line_count(bufnr) - 1
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

  local row = table_insert_row(bufnr, ctx.path)
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
