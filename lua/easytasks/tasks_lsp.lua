local default_schema = require("easytasks.parse.schema")
local toml_context = require("easytasks.parse.toml_context")

local completion = require("easytasks.lsp.completion")
local hover = require("easytasks.lsp.hover")
local code_action = require("easytasks.lsp.code_action")
local diagnostics = require("easytasks.lsp.diagnostics")

local M = {}

---https://neo451.github.io/blog/posts/in-process-lsp-guide/
M.SERVER_NAME = "easytasks-toml"
M.SERVER_VERSION = "0.1.0"

---@type easytasks.JsonSchema
M.schema = default_schema

---@type table<vim.lsp.protocol.Method, fun(params: table, callback: fun(err: lsp.ResponseError?, result: any))>
local handlers = {}

---@type table<integer, integer?>
local attached_clients = {}

local features = {
  completion = completion,
  hover = hover,
  code_action = code_action,
  diagnostics = diagnostics,
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
  },
  serverInfo = {
    name = M.SERVER_NAME,
    version = M.SERVER_VERSION,
  },
}

---@param feature string
---@param mod { handler: fun(params: table, callback: fun(err?: lsp.ResponseError, result: any)) }
function M.register_feature(feature, mod)
  features[feature] = mod
  M._bind_handlers()
end

function M._bind_handlers()
  handlers[ms.initialize] = function(_, callback)
    callback(nil, initialize_result)
  end
  handlers[ms.textDocument_completion] = completion.handler
  handlers[ms.textDocument_hover] = hover.handler
  handlers[ms.textDocument_codeAction] = code_action.handler
end

M._bind_handlers()

---@param schema easytasks.JsonSchema?
function M.set_schema(schema)
  M.schema = schema or default_schema
  toml_context.set_schema(M.schema)
end

---@class easytasks.LspStartOpts
---@field schema easytasks.JsonSchema?

---@param buf integer
---@param opts easytasks.LspStartOpts?
---@return integer? client_id
function M.start(buf, opts)
  opts = opts or {}
  if attached_clients[buf] then
    M.stop(buf)
  end
  M.set_schema(opts.schema)

  ---@type vim.lsp.ClientConfig
  local client_cfg = {
    name = M.SERVER_NAME,
    cmd = function()
      return {
        request = function(method, params, callback)
          local handler = handlers[method]
          if handler then
            handler(params, callback)
            return true
          end
          return false
        end,
        notify = function() end,
        is_closing = function() end,
        terminate = function() end,
      }
    end,
  }

  local client_id = vim.lsp.start(client_cfg, { bufnr = buf, silent = false })
  if client_id then
    attached_clients[buf] = client_id
    diagnostics.attach(buf, M.schema, client_id)
  end
  return client_id
end

---@param buf integer
function M.stop(buf)
  diagnostics.detach(buf)
  attached_clients[buf] = nil
  local clients = vim.lsp.get_clients({ bufnr = buf, name = M.SERVER_NAME })
  for _, client in ipairs(clients) do
    vim.lsp.stop_client(client.id, true)
  end
end

M.set_schema(M.schema)

return M
