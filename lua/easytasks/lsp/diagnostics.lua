local validator = require("easytasks.validate.validator")
local toml_parse = require("easytasks.parse.toml_parse")

local M = {}

local SERVER_NAME = "easytasks-toml"

M.namespace = vim.api.nvim_create_namespace("easytasks-toml")
M.debounce_ms = 250

---@type table<integer, integer?>
local debounce_timers = {}

---@type table<integer, integer[]>
local autocmd_ids = {}

---@param range easytasks.Range4
---@return lsp.Range
local function to_lsp_range(range)
  return {
    start = { line = range[1], character = range[2] },
    ["end"] = { line = range[3], character = range[4] },
  }
end

---@param range easytasks.Range4|nil
---@param bufnr integer
---@return lsp.Range
local function fallback_range(range, bufnr)
  if range then
    return to_lsp_range(range)
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  return {
    start = { line = 0, character = 0 },
    ["end"] = { line = math.max(0, line_count - 1), character = 0 },
  }
end

---@param bufnr integer
---@param schema easytasks.JsonSchema
---@return lsp.Diagnostic[]
function M.build(bufnr, schema)
  local parsed = toml_parse.parse(bufnr)
  local diagnostics = {}

  for _, err in ipairs(parsed.syntax_errors) do
    diagnostics[#diagnostics + 1] = {
      range = fallback_range(err.range, bufnr),
      severity = vim.lsp.protocol.DiagnosticSeverity.Error,
      source = SERVER_NAME,
      message = err.message,
    }
  end

  if parsed.err and not parsed.data then
    diagnostics[#diagnostics + 1] = {
      range = fallback_range(nil, bufnr),
      severity = vim.lsp.protocol.DiagnosticSeverity.Warning,
      source = SERVER_NAME,
      message = parsed.err,
    }
    return diagnostics
  end

  if not parsed.data then
    return diagnostics
  end

  local valid, errors = validator.validate(schema, parsed.data)
  if valid then
    return diagnostics
  end

  for _, err in ipairs(errors) do
    local range = toml_parse.range_for_pointer(bufnr, err.path, parsed.pointer_map)
    diagnostics[#diagnostics + 1] = {
      range = fallback_range(range, bufnr),
      severity = vim.lsp.protocol.DiagnosticSeverity.Error,
      source = SERVER_NAME,
      message = err.err_msg,
    }
  end

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
---@param client_id integer?
---@param bufnr integer
---@param schema easytasks.JsonSchema
---@param client_id integer?
function M.run(bufnr, schema, client_id)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local diagnostics = M.build(bufnr, schema)
  M.publish(bufnr, diagnostics, client_id)
end

---@param bufnr integer
---@param schema easytasks.JsonSchema
---@param client_id integer?
local function schedule(bufnr, schema, client_id)
  if debounce_timers[bufnr] then
    vim.fn.timer_stop(debounce_timers[bufnr])
  end
  debounce_timers[bufnr] = vim.fn.timer_start(M.debounce_ms, function()
    debounce_timers[bufnr] = nil
    vim.schedule(function()
      M.run(bufnr, schema, client_id)
    end)
  end)
end

---@param bufnr integer
function M.detach(bufnr)
  if debounce_timers[bufnr] then
    vim.fn.timer_stop(debounce_timers[bufnr])
    debounce_timers[bufnr] = nil
  end
  for _, id in ipairs(autocmd_ids[bufnr] or {}) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  autocmd_ids[bufnr] = nil
  vim.diagnostic.reset(M.namespace, bufnr)
end

---@param bufnr integer
---@param schema easytasks.JsonSchema
---@param client_id integer?
function M.attach(bufnr, schema, client_id)
  M.detach(bufnr)
  autocmd_ids[bufnr] = {}

  local group = vim.api.nvim_create_augroup("easytasks_toml_diag_" .. bufnr, { clear = true })
  local events = { "BufEnter", "TextChanged", "InsertLeave", "BufWritePost" }
  for _, event in ipairs(events) do
    autocmd_ids[bufnr][#autocmd_ids[bufnr] + 1] = vim.api.nvim_create_autocmd(event, {
      group = group,
      buffer = bufnr,
      callback = function()
        schedule(bufnr, schema, client_id)
      end,
    })
  end

  M.run(bufnr, schema, client_id)
end

return M
