-- easytasks/lsp/diagnostics.lua

local validator = require("easytasks.toml.validator")
local M = {}

local SERVER_NAME = "easytasks-toml"

M.namespace = vim.api.nvim_create_namespace("easytasks-toml")

---@type table<integer, integer[]>
local autocmd_ids = {}

---@return lsp.Range
local function to_lsp_range(range)
  return {
    start = { line = range[1], character = range[2] },
    ["end"] = { line = range[3], character = range[4] },
  }
end

---@return lsp.Range
local function fallback_range(range)
  if range then
    return to_lsp_range(range)
  end
  return {
    start = { line = 0, character = 0 },
    ["end"] = { line = 0, character = 0 },
  }
end

---@param context easytasks.LspBufferContext
---@return lsp.Diagnostic[]
function M.build(context)
  local diagnostics = {}
  local accumulated_errors = {}

  for _, err in ipairs(context.parse_errors or {}) do
    table.insert(accumulated_errors, err)
    diagnostics[#diagnostics + 1] = {
      range = fallback_range(err.range),
      severity = vim.lsp.protocol.DiagnosticSeverity.Error,
      source = SERVER_NAME,
      message = err.message,
    }
  end

  if not context.cst then
    context.parse_results = { data = nil, errors = accumulated_errors }
    return diagnostics
  end

  for _, err in ipairs(context.decode_errors or {}) do
    table.insert(accumulated_errors, err)
    diagnostics[#diagnostics + 1] = {
      range = fallback_range(err.range),
      severity = vim.lsp.protocol.DiagnosticSeverity.Error,
      source = SERVER_NAME,
      message = err.message,
    }
  end

  -- Stop if semantic evaluation failed
  if not context.data then
    context.parse_results = { data = nil, errors = accumulated_errors }
    return diagnostics
  end

  -- 2. Schema validation running on top of decoded outputs
  if context.schema then
    local valid, errors = validator.validate(context.schema, context.data, context.decode_tree)

    if not valid then
      for _, err in ipairs(errors) do
        table.insert(accumulated_errors, err)
        local range = (context.decode_tree and err.node_id)
            and context.decode_tree:range_of_id(err.node_id) or nil
        diagnostics[#diagnostics + 1] = {
          range = fallback_range(range),
          severity = vim.lsp.protocol.DiagnosticSeverity.Error,
          source = SERVER_NAME,
          message = err.err_msg,
        }
      end
    end
  end

  -- Safely sync all accumulated state details back to context closure tracking
  context.parse_results = {
    data = context.data,
    errors = accumulated_errors,
  }

  return diagnostics
end

---@param bufnr integer
---@param diagnostics lsp.Diagnostic[]
---@param client_id integer?
function M.publish(bufnr, diagnostics, client_id)
  if client_id then
    vim.lsp.handlers[vim.lsp.protocol.Methods.textDocument_publishDiagnostics](
      nil,
      {
        uri = vim.uri_from_bufnr(bufnr),
        diagnostics = diagnostics,
      },
      { client_id = client_id, method = vim.lsp.protocol.Methods.textDocument_publishDiagnostics }
    )
    return
  end

  local items = {}
  for _, diag in ipairs(diagnostics) do
    items[#items + 1] = {
      lnum = diag.range.start.line,
      col = diag.range.start.character,
      end_lnum = diag.range["end"].line,
      end_col = diag.range["end"].character,
      severity = vim.diagnostic.severity.ERROR,
      message = diag.message,
      source = diag.source,
    }
  end
  vim.diagnostic.set(M.namespace, bufnr, items)
end

---@param bufnr integer
---@param context easytasks.LspBufferContext
---@param client_id integer?
function M.update(bufnr, context, client_id)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local diagnostics = M.build(context)
  M.publish(bufnr, diagnostics, client_id)
end

return M
