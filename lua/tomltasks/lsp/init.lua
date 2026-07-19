-- In-process alternative to init.lua: same M.start/M.stop/M.dump surface,
-- but the LSP "server" runs as a vim.uv.new_thread worker (thread_server.lua)
-- instead of a `nvim --headless` subprocess. See thread_client.lua for the
-- transport and thread_server.lua for why debug_lua (LuaPanda) isn't
-- supported here.
local thread_client = require("tomltasks.lsp.client")

local M = {}

M.SERVER_NAME    = "tomltasks-toml"
M.SERVER_VERSION = "0.1.0"

--M.diagnostics_ns = vim.api.nvim_create_namespace("tomltasks-toml")

---@type table<integer, {client_id: integer, debug_commands: boolean}>
local attached = {}

-- ── Public API ────────────────────────────────────────────────────────────────

---@class tomltasks.ThreadLspStartOpts
---@field schema         (fun(buf: integer, uri: string): table)?
---@field expressions    (fun(): { name: string, description: string? }[])?  built-in expression list for `{{ … }}` completion
---@field commands       table?   caller-supplied vim.lsp.commands handlers
---@field debug_commands boolean? enable debug dump LSP requests

---@param buf  integer
---@param opts tomltasks.ThreadLspStartOpts?
---@return integer? client_id
function M.start(buf, opts)
    opts = opts or {}
    if attached[buf] then M.stop(buf) end

    local schema         = opts.schema
    local expressions    = opts.expressions
    local debug_commands = opts.debug_commands or false

    -- Register any caller-supplied client-side LSP command handlers.
    if opts.commands then
        for name, handler in pairs(opts.commands) do
            vim.lsp.commands[name] = handler
        end
    end

    local config = {
        name         = M.SERVER_NAME,
        cmd          = thread_client.start,
        init_options = {
            debug_commands = debug_commands,
        },
        root_dir     = vim.fn.getcwd(),

        -- Push the schema to the server as soon as it attaches to a buffer.
        on_attach = function(client, bufnr)
            local uri = vim.uri_from_bufnr(bufnr)
            local s   = schema and schema(bufnr, uri) or nil
            local e   = expressions and expressions() or nil
            client:notify("tomltasks/setSchema", {
                uri         = uri,
                schema      = vim.json.encode(s or {}),
                expressions = vim.json.encode(e or {}),
            })
        end,
    }

    local client_id = vim.lsp.start(config, { bufnr = buf })

    if client_id then
        attached[buf] = { client_id = client_id, debug_commands = debug_commands }
    end

    return client_id
end

---@param buf integer
function M.stop(buf)
    local entry = attached[buf]
    if not entry then return end

    --assert(M.diagnostics_ns)
    --vim.diagnostic.reset(M.diagnostics_ns, buf)
    vim.lsp.buf_detach_client(buf, entry.client_id)
    attached[buf] = nil

    -- Stop the worker thread only when no buffers remain attached.
    local client = vim.lsp.get_client_by_id(entry.client_id)
    if client and next(client.attached_buffers) == nil then
        client:stop(true)
    end
end

-- ── Debug dump API ────────────────────────────────────────────────────────────
-- Only works when opts.debug_commands = true was passed to M.start().

local _dump_methods = {
    cst         = "tomltasks/dumpCst",
    decode_tree = "tomltasks/dumpDecodeTree",
    data        = "tomltasks/dumpData",
    schema      = "tomltasks/dumpSchema",
}

---@param buf  integer
---@param what "cst"|"decode_tree"|"data"|"schema"
function M.dump(buf, what)
    local entry = attached[buf]
    if not entry then
        vim.notify("[tomltasks] no LSP client attached to buffer " .. tostring(buf), vim.log.levels.WARN)
        return
    end
    if not entry.debug_commands then
        vim.notify("[tomltasks] debug_commands not enabled for this buffer", vim.log.levels.WARN)
        return
    end

    local method = _dump_methods[what]
    if not method then
        vim.notify("[tomltasks] unknown dump target: " .. tostring(what), vim.log.levels.ERROR)
        return
    end

    local uri    = vim.uri_from_bufnr(buf)
    local params = { textDocument = { uri = uri } }

    local client = vim.lsp.get_client_by_id(entry.client_id)
    if not client then
        vim.notify("[tomltasks] LSP client not found", vim.log.levels.ERROR)
        return
    end
    client:request(method --[[@as any]], params, function(err, result)
        if err then
            vim.notify("[tomltasks] dump error: " .. tostring(err.message), vim.log.levels.ERROR)
            return
        end
        local text = (result and result.text) or "(empty)"

        local scratch = vim.api.nvim_create_buf(false, true)
        vim.bo[scratch].buftype   = "nofile"
        vim.bo[scratch].bufhidden = "wipe"
        vim.api.nvim_buf_set_name(scratch, "[tomltasks:" .. what .. "]")
        vim.api.nvim_buf_set_lines(scratch, 0, -1, false, vim.split(text, "\n", { plain = true }))
        vim.cmd("split")
        vim.api.nvim_win_set_buf(0, scratch)
    end, buf)
end

return M
