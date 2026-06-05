local parser            = require("easytasks.toml.parser")
local decoder           = require("easytasks.toml.decoder")
local completion        = require("easytasks.lsp.completion")
local hover             = require("easytasks.lsp.hover")
local code_action       = require("easytasks.lsp.code_action")
local document_symbol   = require("easytasks.lsp.document_symbol")
local BufferContext     = require("easytasks.lsp.BufferContext")
local diagnostics       = require("easytasks.lsp.diagnostics")
local format            = require("easytasks.lsp.format")

local M                 = {}

M.SERVER_NAME           = "easytasks-toml"
M.SERVER_VERSION        = "0.1.0"
M.debounce_ms           = 300

local ms                = vim.lsp.protocol.Methods

---@type table<vim.lsp.protocol.Method, fun(context: table, params: table, callback: fun(err: lsp.ResponseError?, result: any))>
local handlers          = {}

---@type table<integer, {client_id:integer, context:easytasks.LspBufferContext, augroup:integer}>
local attached          = {}

local features          = {
  completion      = completion,
  hover           = hover,
  code_action     = code_action,
  document_symbol = document_symbol,
  diagnostics     = diagnostics,
  format          = format,
}

---@type lsp.InitializeResult
local initialize_result = {
  capabilities = {
    hoverProvider                   = true,
    completionProvider              = { triggerCharacters = { ".", "[", '"', "=", " " } },
    codeActionProvider              = { codeActionKinds = { "quickfix", "refactor.extract" } },
    documentFormattingProvider      = true,
    documentRangeFormattingProvider = true,
    documentSymbolProvider          = true,
    executeCommandProvider          = { commands = { "easytasks/insertTemplate" } },
  },
  serverInfo = { name = M.SERVER_NAME, version = M.SERVER_VERSION },
}

-- ─── Handler binding ────────────────────────────────────────────────────────

function M._bind_handlers()
  handlers[ms.initialize]                   = function(_, _, cb) cb(nil, initialize_result) end
  handlers[ms.textDocument_completion]      = features.completion.handler
  handlers[ms.textDocument_hover]           = features.hover.handler
  handlers[ms.textDocument_codeAction]      = features.code_action.handler
  handlers[ms.workspace_executeCommand]     = features.code_action.execute_command
  handlers[ms.textDocument_formatting]      = features.format.handler
  handlers[ms.textDocument_rangeFormatting] = features.format.handler
  handlers[ms.textDocument_documentSymbol]  = features.document_symbol.handler
end

M._bind_handlers()

---@param feature string
---@param mod { handler: fun(context: table, params: table, callback: fun(err?: lsp.ResponseError, result: any)) }
function M.register_feature(feature, mod)
  features[feature] = mod
  M._bind_handlers()
end

-- ─── Buffer context ──────────────────────────────────────────────────────────

---@param context easytasks.LspBufferContext
---@param text string
local function update_context(context, text)
  local parsed          = parser.parse(text)
  context.cst           = parsed.cst
  context.parse_errors  = parsed.errors
  local decoded         = decoder.decode(parsed.cst)
  context.data          = decoded.data
  context.decode_errors = decoded.errors
  context.decode_tree   = decoded.decode_tree
end

---@param bufnr integer
---@return string
local function buf_text(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  table.insert(lines, "\n") -- trailing newlines may not be added by neovim
  return table.concat(lines, "\n")
end

---@param bufnr integer
---@param context easytasks.LspBufferContext
---@param client_id integer?
local function schedule_update(bufnr, context, client_id)
  if context.debounce_timer then
    vim.fn.timer_stop(context.debounce_timer)
  end
  context.debounce_timer = vim.fn.timer_start(M.debounce_ms, function()
    context.debounce_timer = nil
    vim.schedule(function()
      update_context(context, buf_text(bufnr))
      diagnostics.update(bufnr, context, client_id)
    end)
  end)
end

-- ─── Attach / detach ────────────────────────────────────────────────────────

---@param context easytasks.LspBufferContext
local function detach(context)
  if context.debounce_timer then
    vim.fn.timer_stop(context.debounce_timer)
    context.debounce_timer = nil
  end
  vim.diagnostic.reset(diagnostics.namespace, context.bufnr)
end

-- ─── Dispatcher (loopback RPC interface) ────────────────────────────────────

---@param default_context easytasks.LspBufferContext
---@return table dispatcher
local function make_dispatcher(default_context)
  return {
    request    = function(method, params, callback)
      local handler = handlers[method]
      if not handler then return false, nil end

      local ctx = default_context
      if params and params.textDocument then
        local req_bufnr = vim.uri_to_bufnr(params.textDocument.uri)
        local entry     = attached[req_bufnr]
        ctx             = (entry and entry.context) or default_context
      end

      handler(ctx, params, callback)
      return true, nil
    end,
    notify     = function() end,
    is_closing = function() return false end,
    terminate  = function() end,
  }
end

-- ─── Public API ──────────────────────────────────────────────────────────────

---@class easytasks.LspStartOpts
---@field schema table?

---@param buf integer
---@param opts easytasks.LspStartOpts?
---@return integer? client_id
function M.start(buf, opts)
  opts = opts or {}
  if attached[buf] then M.stop(buf) end

  local context    = BufferContext.new(buf)
  context.schema   = opts.schema

  local dispatcher = make_dispatcher(context)

  ---@type vim.lsp.ClientConfig
  local client_cfg = {
    name = M.SERVER_NAME,
    cmd  = function(_) return dispatcher end,
  }

  local client_id  = vim.lsp.start(client_cfg, { bufnr = buf, silent = false })
  if client_id then
    update_context(context, buf_text(buf))
    vim.schedule(function() diagnostics.update(buf, context, client_id) end)
    local augroup = vim.api.nvim_create_augroup("EasyTasksLsp_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
      buffer   = buf,
      group    = augroup,
      callback = function() schedule_update(buf, context, client_id) end,
    })
    attached[buf] = { client_id = client_id, context = context, augroup = augroup }
  end

  return client_id
end

---@param buf integer
function M.stop(buf)
  local entry = attached[buf]
  if not entry then return end

  detach(entry.context)
  pcall(vim.api.nvim_del_augroup_by_id, entry.augroup)

  local client = vim.lsp.get_client_by_id(entry.client_id)
  if client then client:stop(true) end

  attached[buf] = nil
end

return M
