local encoder       = require("tomltools.toml.encoder")
local async         = require("easytasks.util.async")
local _notify       = require("easytasks.ui")
local diagnostics   = require("tomltools.lsp.diagnostics")

local M             = {}

M.SERVER_NAME       = "easytasks-toml"
M.SERVER_VERSION    = "0.1.0"

-- Path to the headless server script (sibling of this file).
local _this_file    = debug.getinfo(1, "S").source:sub(2)
local SERVER_SCRIPT = vim.fn.fnamemodify(_this_file, ":h") .. "/server.lua"

---@type table<integer, {client_id:integer}>
local attached      = {}

-- ── Client-side insertTemplate command ───────────────────────────────────────
-- The server returns "easytasks/insertTemplate" code actions with all needed
-- data in command.arguments[1]. Neovim checks vim.lsp.commands before sending
-- workspace/executeCommand to the server, so this runs entirely on the main thread.

---@param entry { uri:string, row:integer, col:integer, kind:"array"|"aot", type_name:string, indent:string }
local function apply_template(entry, tmpl)
    local bufnr = vim.uri_to_bufnr(entry.uri)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    vim.api.nvim_win_set_cursor(0, { entry.row + 1, entry.col })

    local lines
    if entry.kind == "array" then
        local encoded = encoder.encode_inline(tmpl.task, { multiline = true, indent = entry.indent })
        lines = vim.split(encoded, "\n", { plain = true })
    else
        local block = encoder.encode_aot_entry("tasks", tmpl.task)
        lines = vim.split(block, "\n", { plain = true })
    end
    vim.api.nvim_put(lines, "c", false, true)
end

vim.lsp.commands["easytasks/insertTemplate"] = function(command)
    local args = command.arguments and command.arguments[1]
    if not args then return end
    ---@cast args { uri:string, row:integer, col:integer, kind:"array"|"aot", type_name:string, indent:string }

    local task_types = require("easytasks.types")
    local type_def   = task_types.get_all()[args.type_name]
    if not type_def or not type_def.templates then return end

    local function show_select(templates)
        if not templates or #templates == 0 then
            _notify.notify_warning("no templates for type: " .. args.type_name)
            return
        end
        vim.ui.select(
            templates,
            {
                prompt      = "Choose " .. args.type_name .. " template:",
                format_item = function(item) return item.label end,
            },
            function(choice)
                if choice then
                    vim.schedule(function() apply_template(args, choice) end)
                end
            end
        )
    end

    if type(type_def.templates) == "function" then
        local fn = type_def.templates ---@cast fn function
        async.go(fn, function(ok, result)
            if ok then show_select(result --[[@as easytasks.TaskTemplate[] ]]) end
        end)
    else
        show_select(type_def.templates --[[@as easytasks.TaskTemplate[] ]])
    end
end

-- ── Schema pre-processing ─────────────────────────────────────────────────────

-- Walk a schema node and evaluate any Lua functions stored in `enum` or
-- `x-enumDescriptions`, replacing them with their concrete values before JSON
-- encoding. Functions that return empty or error are set to nil so they don't
-- survive into the server's schema.
---@param node table
local function resolve_schema_functions(node)
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

    for _, v in pairs(node) do resolve_schema_functions(v) end
end

-- ── Public API ────────────────────────────────────────────────────────────────

---@class easytasks.LspStartOpts
---@field schema table?

---@param buf  integer
---@param opts easytasks.LspStartOpts?
---@return integer? client_id
function M.start(buf, opts)
    opts = opts or {}
    if attached[buf] then M.stop(buf) end

    local task_types     = require("easytasks.types")
    local template_types = {}
    for name, def in pairs(task_types.get_all()) do
        if def.templates then template_types[#template_types + 1] = name end
    end

    local schema = vim.deepcopy(opts.schema or {})
    resolve_schema_functions(schema)

    local config = {
        name         = M.SERVER_NAME,
        cmd          = { vim.v.progpath, "--headless", "--noplugin", "-n", "-u", "NONE", "-l", SERVER_SCRIPT },
        init_options = { schema = vim.json.encode(schema), template_types = template_types },
        root_dir     = vim.fn.getcwd(),
    }

    local client_id = vim.lsp.start(config, { bufnr = buf })

    if client_id then
        attached[buf] = { client_id = client_id }
    end

    return client_id
end

---@param buf integer
function M.stop(buf)
    local entry = attached[buf]
    if not entry then return end

    vim.diagnostic.reset(diagnostics.namespace, buf)

    local client = vim.lsp.get_client_by_id(entry.client_id)
    if client then client:stop(true) end

    attached[buf] = nil
end

return M
