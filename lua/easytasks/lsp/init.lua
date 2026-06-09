local diagnostics   = require("tomltools.lsp.diagnostics")

local M             = {}

M.SERVER_NAME       = "easytasks-toml"
M.SERVER_VERSION    = "0.1.0"

-- Path to the headless server script (sibling of this file).
local _this_file    = debug.getinfo(1, "S").source:sub(2)
local _SERVER_SCRIPT = vim.fn.fnamemodify(_this_file, ":h") .. "/server.lua"

---@type table<integer, {client_id:integer}>
local _attached      = {}

-- ── Schema pre-processing ─────────────────────────────────────────────────────

-- Walk a schema node and evaluate any Lua functions stored in `enum` or
-- `x-enumDescriptions`, replacing them with their concrete values before JSON
-- encoding. Functions that return empty or error are set to nil so they don't
-- survive into the server's schema.
---@param node table
local function _resolve_schema_functions(node)
    if type(node) ~= "table" then return end

    if type(node.enum) == "function" then
        local ok, raw = pcall(node.enum --[[@as function]])
        if ok and type(raw) == "table" and #raw > 0 then
            local labels, descs, has_desc = {}, {}, false
            for _, v in ipairs(raw) do
                if type(v) == "table" then
                    labels[#labels + 1] = tostring(v.label)
                    descs[#descs + 1]   = v.description
                    if v.description then has_desc = true end
                else
                    labels[#labels + 1] = tostring(v)
                end
            end
            node.enum = labels
            if has_desc then node["x-enumDescriptions"] = descs end
        else
            node.enum = nil
        end
    end

    if type(node["x-enumDescriptions"]) == "function" then
        local ok, raw = pcall(node["x-enumDescriptions"] --[[@as function]])
        node["x-enumDescriptions"] = (ok and type(raw) == "table") and raw or nil
    end

    for _, v in pairs(node) do _resolve_schema_functions(v) end
end

-- ── Public API ────────────────────────────────────────────────────────────────

---@class easytasks.LspStartOpts
---@field schema table?

---@param buf  integer
---@param opts easytasks.LspStartOpts?
---@return integer? client_id
function M.start(buf, opts)
    opts = opts or {}
    if _attached[buf] then M.stop(buf) end

    local schema = vim.deepcopy(opts.schema or {})
    _resolve_schema_functions(schema)

    local config = {
        name         = M.SERVER_NAME,
        cmd          = { vim.v.progpath, "--headless", "--noplugin", "-n", "-u", "NONE", "-l", _SERVER_SCRIPT },
        init_options = { schema = vim.json.encode(schema) },
        root_dir     = vim.fn.getcwd(),
    }

    local client_id = vim.lsp.start(config, { bufnr = buf })

    if client_id then
        _attached[buf] = { client_id = client_id }
    end

    return client_id
end

---@param buf integer
function M.stop(buf)
    local entry = _attached[buf]
    if not entry then return end

    vim.diagnostic.reset(diagnostics.namespace, buf)

    local client = vim.lsp.get_client_by_id(entry.client_id)
    if client then client:stop(true) end

    _attached[buf] = nil
end

return M
