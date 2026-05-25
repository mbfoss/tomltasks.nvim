local parser        = require("easytasks.toml.parser")
local decoder       = require("easytasks.toml.decoder")
local completion    = require("easytasks.lsp.completion")
local hover         = require("easytasks.lsp.hover")
local code_action   = require("easytasks.lsp.code_action")
local BufferContext = require("easytasks.lsp.BufferContext")
local diagnostics   = require("easytasks.lsp.diagnostics")
local format        = require("easytasks.lsp.format")

local M             = {}

M.SERVER_NAME       = "easytasks-toml"
M.SERVER_VERSION    = "0.1.0"

local ms            = vim.lsp.protocol.Methods

---@type table<vim.lsp.protocol.Method, fun(context: table, params: table, callback: fun(err: lsp.ResponseError?, result: any))>
local handlers      = {}

---@type table<integer, {client_id:integer, context:easytasks.LspBufferContext, autocmd_ids:integer[]}>
local attached      = {}

local features      = {
  completion  = completion,
  hover       = hover,
  code_action = code_action,
  diagnostics = diagnostics,
  format      = format,
}

---@type lsp.InitializeResult
local initialize_result = {
  capabilities = {
    hoverProvider              = true,
    completionProvider         = { triggerCharacters = { ".", "[", '"', "=", " " } },
    codeActionProvider         = { codeActionKinds = { "quickfix" } },
    documentFormattingProvider = true,
    documentRangeFormattingProvider = true,
  },
  serverInfo = { name = M.SERVER_NAME, version = M.SERVER_VERSION },
}

-- ─── Handler binding ────────────────────────────────────────────────────────

function M._bind_handlers()
  handlers[ms.initialize]                  = function(_, _, cb) cb(nil, initialize_result) end
  handlers[ms.textDocument_completion]     = features.completion.handler
  handlers[ms.textDocument_hover]          = features.hover.handler
  handlers[ms.textDocument_codeAction]     = features.code_action.handler
  handlers[ms.textDocument_formatting]     = features.format.handler
  handlers[ms.textDocument_rangeFormatting] = features.format.handler
end

M._bind_handlers()

---@param feature string
---@param mod { handler: fun(context: table, params: table, callback: fun(err?: lsp.ResponseError, result: any)) }
function M.register_feature(feature, mod)
  features[feature] = mod
  M._bind_handlers()
end

-- ─── Buffer context ──────────────────────────────────────────────────────────

---@param bufnr integer
---@param context easytasks.LspBufferContext
local function update_context(bufnr, context)
  local buflines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  table.insert(buflines, "\n") -- trailing new lines may not be added by neovim 
  local text            = table.concat(buflines, "\n")
  local parsed          = parser.parse(text)
  context.cst           = parsed.cst
  context.parse_errors  = parsed.errors
  local decoded         = decoder.decode(parsed.cst)
  context.data          = decoded.data
  context.decode_errors = decoded.errors
  context.decode_tree   = decoded.decode_tree
end

---@param bufnr integer
---@param context easytasks.LspBufferContext
---@param client_id integer?
local function schedule_diagnostics(bufnr, context, client_id)
  if context.debounce_timer then
    vim.fn.timer_stop(context.debounce_timer)
  end
  context.debounce_timer = vim.fn.timer_start(M.debounce_ms, function()
    context.debounce_timer = nil
    vim.schedule(function()
      diagnostics.update(bufnr, context, client_id)
    end)
  end)
end

-- ─── Attach / detach ────────────────────────────────────────────────────────

---@param context easytasks.LspBufferContext
---@param autocmd_ids integer[]
local function detach(context, autocmd_ids)
  if context.debounce_timer then
    vim.fn.timer_stop(context.debounce_timer)
    context.debounce_timer = nil
  end
  for _, id in ipairs(autocmd_ids) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  vim.diagnostic.reset(M.namespace, context.bufnr)
end

---@param context easytasks.LspBufferContext
---@param client_id integer
---@return integer[] autocmd_ids
local function attach(context, client_id)
  local bufnr      = context.bufnr
  local group      = vim.api.nvim_create_augroup("easytasks_toml_diag_" .. bufnr, { clear = true })
  local autocmd_ids = {}

  for _, event in ipairs({ "BufEnter", "TextChanged", "TextChangedI", "InsertLeave", "BufWritePost" }) do
    autocmd_ids[#autocmd_ids + 1] = vim.api.nvim_create_autocmd(event, {
      group    = group,
      buffer   = bufnr,
      callback = function()
        update_context(bufnr, context)
        schedule_diagnostics(bufnr, context, client_id)
      end,
    })
  end

  return autocmd_ids
end

-- ─── Dispatcher (loopback RPC interface) ────────────────────────────────────

---@param default_context easytasks.LspBufferContext
---@return table dispatcher
local function make_dispatcher(default_context)
  return {
    request = function(method, params, callback)
      local handler = handlers[method]
      if not handler then return false, nil end

      local ctx = default_context
      if params and params.textDocument then
        local req_bufnr = vim.uri_to_bufnr(params.textDocument.uri)
        local entry     = attached[req_bufnr]
        ctx = (entry and entry.context) or default_context
      end

      handler(ctx, params, callback)
      return true, nil
    end,
    notify     = function(_, _) end,
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

  local client_id = vim.lsp.start(client_cfg, { bufnr = buf, silent = false })
  if client_id then
    local autocmd_ids = attach(context, client_id)
    attached[buf] = { client_id = client_id, context = context, autocmd_ids = autocmd_ids }
  end

  return client_id
end

---@param buf integer
function M.stop(buf)
  local entry = attached[buf]
  if not entry then return end

  detach(entry.context, entry.autocmd_ids)

  local client = vim.lsp.get_client_by_id(entry.client_id)
  if client then client:stop(true) end

  attached[buf] = nil
end

return M
