local toml_parse = require("easytasks.parse.toml_parse")
local toml_emit = require("easytasks.parse.toml_emit")
local toml_context = require("easytasks.parse.toml_context")

local M = {}

---@param bufnr integer
---@return lsp.TextEdit? edit
---@return string? err
function M.build_edit(bufnr)
  local schema = toml_context.schema
  if not schema then
    return nil, "schema not configured"
  end

  local parsed = toml_parse.parse(bufnr)
  if #parsed.syntax_errors > 0 then
    return nil, parsed.syntax_errors[1].message
  end
  if parsed.err and not parsed.data then
    return nil, toml_parse.clean_error_message(parsed.err)
  end
  if not parsed.data then
    return nil, "nothing to format"
  end

  local new_text = toml_emit.format_data(parsed.data, schema)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local last_line = vim.api.nvim_buf_get_lines(bufnr, line_count - 1, line_count, false)[1] or ""

  return {
    newText = new_text,
    range = {
      start = { line = 0, character = 0 },
      ["end"] = { line = math.max(0, line_count - 1), character = #last_line },
    },
  }, nil
end

---@param params lsp.DocumentFormattingParams|lsp.DocumentRangeFormattingParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.TextEdit[]|null)
function M.handler(params, callback)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    callback(nil, nil)
    return
  end

  local edit, err = M.build_edit(bufnr)
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
