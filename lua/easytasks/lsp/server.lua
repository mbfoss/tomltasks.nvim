-- easytasks LSP server — runs as a headless Neovim subprocess.
-- Launched via: nvim --headless -l <this file>
-- Communicates with the Neovim LSP client over stdin/stdout using JSON-RPC
-- with Content-Length framing (standard LSP transport).
--
-- All parsing, decoding, and validation runs here, off the main Neovim thread.

-- ── Module resolution ────────────────────────────────────────────────────────
-- The plugin's lua/ directory must be on package.path before any require().
local _src = debug.getinfo(1, "S").source:sub(2)
local _lua = vim.fn.fnamemodify(_src, ":h:h:h")           -- easytasks.nvim/lua
local _tt  = vim.fn.fnamemodify(_src, ":h:h:h:h:h")       -- .../opt/
             .. "/tomltools.nvim/lua"
package.path = _lua .. "/?.lua;" .. _lua .. "/?/init.lua;"
             .. _tt  .. "/?.lua;" .. _tt  .. "/?/init.lua;"
             .. package.path

-- ── Imports ──────────────────────────────────────────────────────────────────
local parser         = require("tomltools.toml.parser")
local decoder        = require("tomltools.toml.decoder")
local diagnostics    = require("tomltools.lsp.diagnostics")
local completion     = require("tomltools.lsp.completion")
local hover          = require("tomltools.lsp.hover")
local code_action    = require("tomltools.lsp.code_action")
local doc_symbol     = require("tomltools.lsp.document_symbol")
local fmt            = require("tomltools.lsp.format")

-- ── Transport ─────────────────────────────────────────────────────────────────
local _uv     = vim.uv
local _stdin  = assert(_uv.new_pipe(false))
local _stdout = assert(_uv.new_pipe(false))
_stdin:open(0)
_stdout:open(1)

---@param obj table
local function write_msg(obj)
    local json = vim.json.encode(obj)
    _stdout:write(("Content-Length: %d\r\n\r\n%s"):format(#json, json))
end

-- ── Logger ───────────────────────────────────────────────────────────────────
-- Sends window/logMessage; filtered by vim.lsp.log.set_level() on the client.
local _MSG = { Error = 1, Warning = 2, Info = 3, Log = 4 }

---@param msg  string
---@param type? integer  _MSG.* constant (default: _MSG.Log)
local function _log(msg, type)
    write_msg({ jsonrpc = "2.0", method = "window/logMessage",
                params = { type = type or _MSG.Log, message = msg } })
end

-- ── Server state ─────────────────────────────────────────────────────────────
---@type table<string, tomltools.LspBufferContext>
local _documents           = {}
---@type table?
local _schema              = nil

-- ── Capabilities ─────────────────────────────────────────────────────────────
local _INITIALIZE_RESULT = {
    capabilities = {
        textDocumentSync                = { openClose = true, change = 2 },
        positionEncoding                = "utf-8",
        hoverProvider                   = true,
        completionProvider              = { triggerCharacters = { ".", "[", '"', "=", " " } },
        codeActionProvider              = { codeActionKinds = { "quickfix", "refactor.extract" } },
        documentFormattingProvider      = true,
        documentRangeFormattingProvider = true,
        documentSymbolProvider          = true,
    },
    serverInfo = { name = "easytasks-toml", version = "0.1.0" },
}

-- ── Document helpers ──────────────────────────────────────────────────────────

local _DIAG_DEBOUNCE_MS = 200

---@type table<string, string>
local _doc_text   = {}
---@type table<string, any>
local _diag_timer = {}

---@param uri  string
---@param text string
---@return tomltools.LspBufferContext
local function parse_document(uri, text)
    local lines  = vim.split(text, "\n", { plain = true })
    local parsed = parser.parse(text)
    ---@type tomltools.LspBufferContext
    local ctx = {
        bufnr               = nil,
        schema              = _schema,
        text                = text,
        lines               = lines,
        cst                 = parsed.cst,
        parse_errors        = parsed.errors,
        data                = nil,
        decode_errors       = {},
        decode_tree         = nil,
        parse_results       = nil,
    }
    if parsed.cst then
        local decoded     = decoder.decode(parsed.cst)
        ctx.data          = decoded.data
        ctx.decode_errors = decoded.errors
        ctx.decode_tree   = decoded.decode_tree
    end
    documents[uri] = ctx
    return ctx
end

---@param uri string
local function publish_diagnostics(uri)
    local ctx = documents[uri]
    if not ctx then return end
    local diags = diagnostics.build(nil, ctx)
    write_msg({
        jsonrpc = "2.0",
        method  = "textDocument/publishDiagnostics",
        params  = { uri = uri, diagnostics = diags },
    })
end

---@param uri string
local function schedule_diagnostics(uri)
    local t = diag_timer[uri]
    if t then
        t:stop()
    else
        t = assert(_uv.new_timer())
        diag_timer[uri] = t
    end
    t:start(DIAG_DEBOUNCE_MS, 0, function()
        t:stop(); t:close(); diag_timer[uri] = nil
        local text = doc_text[uri]
        if text then
            parse_document(uri, text)
            publish_diagnostics(uri)
        end
    end)
end

---@param uri string
local function ensure_parsed(uri)
    local t = diag_timer[uri]
    if not t then return end
    t:stop(); t:close(); diag_timer[uri] = nil
    local text = doc_text[uri]
    if text then
        parse_document(uri, text)
        publish_diagnostics(uri)
    end
end

-- ── Incremental text application ─────────────────────────────────────────────

---@param text   string
---@param change table  { range: {start,end}, text: string }
---@return string
local function apply_incremental(text, change)
    if not change.range then return change.text end
    local r     = change.range
    local lines = vim.split(text, "\n", { plain = true })

    local before = {}
    for i = 1, r.start.line do before[#before + 1] = lines[i] end
    before[#before + 1] = (lines[r.start.line + 1] or ""):sub(1, r.start.character)

    local after = { (lines[r["end"].line + 1] or ""):sub(r["end"].character + 1) }
    for i = r["end"].line + 2, #lines do after[#after + 1] = lines[i] end

    return table.concat(before, "\n") .. change.text .. table.concat(after, "\n")
end

-- ── Request / notification dispatch ─────────────────────────────────────────

---@param id     integer|string|nil
---@param result any
local function respond(id, result)
    if id == nil then return end
    write_msg({ jsonrpc = "2.0", id = id, result = result })
end

---@param id      integer|string|nil
---@param code    integer
---@param message string
local function respond_err(id, code, message)
    if id == nil then return end
    write_msg({ jsonrpc = "2.0", id = id, error = { code = code, message = message } })
end

---@param uri string
---@return tomltools.LspBufferContext?
local function doc_ctx(uri)
    return documents[uri]
end

---@param msg table
local function dispatch(msg)
    local method = msg.method
    local id     = msg.id
    local params = msg.params or {}
    _log("dispatch method=" .. tostring(method) .. " id=" .. tostring(id))

    -- ── Lifecycle ────────────────────────────────────────────────────────────
    if method == "initialize" then
        local opts = params.initializationOptions
        if opts and opts.schema then
            local ok, s = pcall(vim.json.decode, opts.schema)
            if ok then
                _schema = s
                _log("schema loaded")
            else
                _log("schema decode failed", _MSG.Error)
            end
        else
            _log("no initializationOptions.schema", _MSG.Warning)
        end
        respond(id, INITIALIZE_RESULT)
        _log("initialize done")
        return
    end

    if method == "initialized" then return end

    if method == "shutdown" then
        respond(id, vim.NIL)
        return
    end

    if method == "exit" then
        _uv.stop()
        return
    end

    -- ── Text synchronisation ─────────────────────────────────────────────────
    if method == "textDocument/didOpen" then
        local uri  = params.textDocument.uri
        local text = params.textDocument.text
        _log("didOpen " .. tostring(uri))
        doc_text[uri] = text
        parse_document(uri, text)
        publish_diagnostics(uri)
        return
    end

    if method == "textDocument/didChange" then
        local uri     = params.textDocument.uri
        local text    = doc_text[uri] or ""
        local changes = params.contentChanges
        if changes then
            for _, change in ipairs(changes) do
                text = apply_incremental(text, change)
            end
        end
        doc_text[uri] = text
        schedule_diagnostics(uri)
        return
    end

    if method == "textDocument/didClose" then
        local uri = params.textDocument.uri
        local t   = diag_timer[uri]
        if t then t:stop(); t:close(); diag_timer[uri] = nil end
        doc_text[uri]  = nil
        documents[uri] = nil
        return
    end

    -- ── Feature requests ─────────────────────────────────────────────────────
    local uri = params.textDocument and params.textDocument.uri
    if not uri then
        respond_err(id, -32602, "missing textDocument.uri")
        return
    end

    local ctx = doc_ctx(uri)
    if not ctx then
        respond(id, vim.NIL)
        return
    end

    local function cb(err, result)
        if err then
            _log("handler error: " .. tostring(err.message or err), _MSG.Error)
            respond_err(id, err.code or -32603, err.message or "internal error")
        else
            respond(id, result ~= nil and result or vim.NIL)
        end
    end

    if method == "textDocument/completion" then
        ensure_parsed(uri)
        ctx = doc_ctx(uri) or ctx
        local ok, err = pcall(completion.handler, ctx, params, cb)
        if not ok then
            _log("completion pcall error: " .. tostring(err), _MSG.Error)
        end
        return
    end

    if method == "textDocument/hover" then
        ensure_parsed(uri)
        hover.handler(ctx, params, cb)
        return
    end

    if method == "textDocument/codeAction" then
        ensure_parsed(uri)
        code_action.handler(ctx, params, cb)
        return
    end

    if method == "textDocument/formatting"
        or method == "textDocument/rangeFormatting" then
        ensure_parsed(uri)
        fmt.handler(ctx, params, cb)
        return
    end

    if method == "textDocument/documentSymbol" then
        ensure_parsed(uri)
        doc_symbol.handler(ctx, params, cb)
        return
    end

    if method == "workspace/executeCommand" then
        respond(id, vim.NIL)
        return
    end

    if id ~= nil then
        respond_err(id, -32601, "method not found: " .. tostring(method))
    end
end

-- ── stdin reader ─────────────────────────────────────────────────────────────
local _buf = ""

_stdin:read_start(function(err, data)
    if err or not data then
        _log("stdin closed, stopping")
        _uv.stop()
        return
    end
    _buf = _buf .. data
    while true do
        local hdr_end = _buf:find("\r\n\r\n", 1, true)
        if not hdr_end then break end
        local hdr = _buf:sub(1, hdr_end - 1)
        local len = tonumber(hdr:match("Content%-Length:%s*(%d+)"))
        if not len then
            _buf = _buf:sub(hdr_end + 4)
        else
            local body_start = hdr_end + 4
            local body_end   = body_start + len - 1
            if #_buf < body_end then break end
            local body = _buf:sub(body_start, body_end)
            _buf = _buf:sub(body_end + 1)
            local ok, msg = pcall(vim.json.decode, body)
            if ok and type(msg) == "table" then
                dispatch(msg)
            else
                _log("json decode error: " .. tostring(msg), _MSG.Error)
            end
        end
    end
end)

-- Drive the libuv event loop. This call blocks until uv.stop() is called
-- (from the "exit" handler above) or stdin is closed by the client.
_uv.run()
