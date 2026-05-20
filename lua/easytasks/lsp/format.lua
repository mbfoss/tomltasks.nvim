-- easytasks/lsp/formatting.lua
local M = {}

local parser = require("easytasks.toml.parser")
local toml_format = require("easytasks.toml.formatter")

--------------------------------------------------------------------------------
-- Document Text Edit Builders
--------------------------------------------------------------------------------

---@param context easytasks.LspBufferContext
---@param bufnr integer
---@return lsp.TextEdit? edit
---@return string? err
function M.build_edit(context, bufnr)
  local schema = context.schema
  if not schema then
    return nil, "schema not configured"
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local active_ast = context.ast

  -- Fallback protection: If context doesn't hold an AST tree, parse the text cleanly
  if not active_ast then
    local text = table.concat(lines, "\n")
    local parsed = parser.parse(text)

    if parsed.errors and #parsed.errors > 0 then
      return nil, parsed.errors[1].message
    end
    if not parsed.ok or not parsed.ast then
      return nil, "nothing to format or invalid document structure"
    end
    active_ast = parsed.ast
    context.ast = parsed.ast
  end

  -- Pass the context tree directly into your formatting engine
  local new_text = toml_format.format(active_ast)
  local line_count = #lines
  local last_line = lines[line_count] or ""

  return {
    newText = new_text,
    range = {
      start = { line = 0, character = 0 },
      ["end"] = { line = math.max(0, line_count - 1), character = #last_line },
    },
  }, nil
end

--------------------------------------------------------------------------------
-- Formatting Request Dispatcher
--------------------------------------------------------------------------------

---@param context easytasks.LspBufferContext
---@param params lsp.DocumentFormattingParams|lsp.DocumentRangeFormattingParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.TextEdit[]|nil)
function M.handler(context, params, callback)
  local bufnr = context.bufnr or vim.uri_to_bufnr(params.textDocument.uri)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    callback(nil, nil)
    return
  end

  local edit, err = M.build_edit(context, bufnr)
  if not edit then
    callback({
      code = vim.lsp.protocol.ErrorCodes.RequestFailed,
      message = err or "cannot format document",
    }, nil)
    return
  end

  callback(nil, { edit })
end

return M
