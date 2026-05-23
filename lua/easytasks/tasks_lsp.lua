local parser = require("easytasks.toml.parser")
local decoder = require("easytasks.toml.decoder")
local completion = require("easytasks.lsp.completion")
local hover = require("easytasks.lsp.hover")
local code_action = require("easytasks.lsp.code_action")
local BufferContext = require("easytasks.lsp.BufferContext")
local diagnostics = require("easytasks.lsp.diagnostics")
local format = require("easytasks.lsp.format")

local M = {}

M.SERVER_NAME = "easytasks-toml"
M.SERVER_VERSION = "0.1.0"

---@type table<vim.lsp.protocol.Method, fun(context: table, params: table, callback: fun(err: lsp.ResponseError?, result: any))>
local handlers = {}

---@type table<integer, {client_id:integer, context:easytasks.LspBufferContext,autocmd_ids:table}>
local attached_clients = {}

local features = {
  completion = completion,
  hover = hover,
  code_action = code_action,
  diagnostics = diagnostics,
  format = format,
}

local ms = vim.lsp.protocol.Methods

---@type lsp.InitializeResult
local initialize_result = {
  capabilities = {
    hoverProvider = true,
    completionProvider = {
      triggerCharacters = { ".", "[", '"', "=", " " },
    },
    codeActionProvider = {
      codeActionKinds = { "quickfix" },
    },
    documentFormattingProvider = true,
    documentRangeFormattingProvider = true,
  },
  serverInfo = {
    name = M.SERVER_NAME,
    version = M.SERVER_VERSION,
  },
}

---@param feature string
---@param mod { handler: fun(context: table, params: table, callback: fun(err?: lsp.ResponseError, result: any)) }
function M.register_feature(feature, mod)
  features[feature] = mod
  M._bind_handlers()
end

function M._bind_handlers()
  handlers[ms.initialize] = function(_, _, callback)
    callback(nil, initialize_result)
  end
  handlers[ms.textDocument_completion] = features.completion.handler
  handlers[ms.textDocument_hover] = features.hover.handler
  handlers[ms.textDocument_codeAction] = features.code_action.handler
  handlers[ms.textDocument_formatting] = features.format.handler
  handlers[ms.textDocument_rangeFormatting] = features.format.handler
end

M._bind_handlers()

local context_map = {}


---@param context easytasks.LspBufferContext
local function detach(context, autocmd_ids)
  if context.debounce_timer then
    vim.fn.timer_stop(context.debounce_timer)
    context.debounce_timer = nil
  end
  for _, id in ipairs(autocmd_ids[context.bufnr] or {}) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  autocmd_ids[context.bufnr] = nil
  vim.diagnostic.reset(M.namespace, context.bufnr)
end

---@param bufnr integer
---@param context easytasks.LspBufferContext
local function update_context(bufnr, context)
  -- Always re-parse and ensure our context tracking state is built cleanly
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local parsed = parser.parse(text)
  context.ast = parsed.ast
  context.parse_errors = parsed.errors
  context.node_at = parsed.node_at
  local decoded = decoder.decode(context.ast)
  context.data = decoded.data
  context.decode_errors = decoded.errors
  context.location_tree = decoded.location_tree
  context.pos_to_location = decoded.pos_to_location
  context.location_to_pos = decoded.location_to_pos
end

---@param bufnr integer
---@param context easytasks.LspBufferContext
---@param client_id integer?
local function schedule(bufnr, context, client_id)
  if context.debounce_timer then
    vim.fn.timer_stop(context.debounce_timer)
  end
  context.debounce_timer = vim.fn.timer_start(M.debounce_ms, function()
    context.debounce_timer = nil
    vim.schedule(function()
      update_context(bufnr, context)
      diagnostics.update(bufnr, context, client_id)
    end)
  end)
end

---@param context easytasks.LspBufferContext
---@param client_id integer
local function attach(context, client_id, autocmd_ids)
  detach(context, autocmd_ids)
  autocmd_ids[context.bufnr] = {}

  local bufnr = context.bufnr
  local group = vim.api.nvim_create_augroup("easytasks_toml_diag_" .. bufnr, { clear = true })
  local events = { "BufEnter", "TextChanged", "InsertLeave", "BufWritePost" }
  for _, event in ipairs(events) do
    autocmd_ids[bufnr][#autocmd_ids[bufnr] + 1] = vim.api.nvim_create_autocmd(event, {
      group = group,
      buffer = bufnr,
      callback = function()
        schedule(bufnr, context, client_id)
      end,
    })
  end
end


---@class easytasks.LspStartOpts
---@field schema table?

---@param buf integer
---@param opts easytasks.LspStartOpts?
---@return integer? client_id
function M.start(buf, opts)
  opts = opts or {}
  if attached_clients[buf] then
    M.stop(buf)
  end

  local context = BufferContext.new(buf)
  context.schema = opts.schema
  context_map[buf] = context_map

  -- Build a direct, loopback interface matching Neovim's expected RPC interface layout
  local dispatch = {
    request = function(method, params, callback)
      local handler = handlers[method]
      if handler then
        -- FIXED: context is safely passed as the first parameter
        handler(context, params, callback)
        return true, nil
      end
      return false, nil
    end,
    notify = function(_, _) end,
    is_closing = function() return false end,
    terminate = function() end,
  }

  ---@type vim.lsp.ClientConfig
  local client_cfg = {
    name = M.SERVER_NAME,
    -- FIXED: Wrapped inside an initialization function matching internal core API expectations
    cmd = function(dispatchers)
      return dispatch
    end,
  }

  local autocmd_ids = {}

  local client_id = vim.lsp.start(client_cfg, { bufnr = buf, silent = false })
  if client_id then
    attached_clients[buf] = {
      client_id = client_id,
      context = context,
      autocmd_ids = autocmd_ids
    }
    attach(context, client_id, autocmd_ids)
  end

  return client_id
end

---@param buf integer
function M.stop(buf)
  local data = attached_clients[buf]
  if not data then return end
  local client_id = data.client_id
  detach(data.context, data.autocmd_ids)
  local client = vim.lsp.get_client_by_id(client_id)
  if client then
    client:stop(true)
  end
  attached_clients[buf] = nil
end

return M
