--- Project bootstrap for easytasks.nvim (`:Tasks bootstrap`).
--- Scaffolds a project directory so authoring `tasks.lua` has full
--- lua-language-server support:
---   • creates a starter tasks file if none exists, and
---   • creates or updates `.luarc.json` so lua_ls loads only the plugin's
---     curated public type library (`meta/`) — never the internal `lua/` tree,
---     which would leak private annotations into completion.
local config  = require("easytasks.config")
local ui      = require("easytasks.ui")
local ui_util = require("easytasks.util.ui_util")

local M       = {}

local _SCHEMA = "https://raw.githubusercontent.com/LuaLS/vscode-lua/master/setting/schema.json"

--- Absolute path of the plugin's public type-annotation library (`meta/`).
--- Prefer a runtimepath lookup; fall back to this file's own location
--- (`<root>/lua/easytasks/bootstrap.lua`). Both are resolved to an absolute path
--- so the entry written to `.luarc.json` is machine-usable regardless of cwd.
---@return string
local function _meta_dir()
    local found = vim.api.nvim_get_runtime_file("meta/easytasks.lua", false)[1]
    if found then
        return vim.fs.normalize(vim.fn.fnamemodify(found, ":p:h"))
    end
    local src  = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
    local root = vim.fn.fnamemodify(src, ":h:h:h") -- lua/easytasks → lua → root
    return vim.fs.normalize(vim.fs.joinpath(root, "meta"))
end

--- Absolute path of Neovim's own runtime Lua tree, which ships the `vim.*`
--- lua-language-server annotations (`runtime/lua/vim/_meta/*.lua`) — needed
--- for `vim.fn`/`vim.api`/… completion inside task field functions.
---@return string
local function _vim_runtime_lua_dir()
    return vim.fs.normalize(vim.fs.joinpath(vim.env.VIMRUNTIME, "lua"))
end

--- Encode a Lua value as pretty-printed JSON (2-space indent). Handles the
--- subset present in a `.luarc.json`: objects, arrays, strings, numbers, bools.
--- Object keys are sorted for stable output; an empty table encodes as `[]`.
---@param v any
---@param indent integer
---@return string
local function _encode(v, indent)
    local t = type(v)
    if t == "string" then return vim.json.encode(v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t ~= "table" then return "null" end

    local pad   = string.rep("  ", indent + 1)
    local close = string.rep("  ", indent)
    if next(v) == nil then return "[]" end

    if v[1] ~= nil then -- array
        local parts = {}
        for _, item in ipairs(v) do
            parts[#parts + 1] = pad .. _encode(item, indent + 1)
        end
        return "[\n" .. table.concat(parts, ",\n") .. "\n" .. close .. "]"
    end

    local keys = {} ---@type string[]
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = pad .. vim.json.encode(k) .. ": " .. _encode(v[k], indent + 1)
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. close .. "}"
end

--- Create or update `<dir>/.luarc.json` so every dir in `lib_dirs` is on the
--- lua_ls library list.
---@param dir string
---@param lib_dirs string[]
---@return "created"|"updated"|"unchanged"|"skipped" action, string path, string? note
local function _ensure_luarc(dir, lib_dirs)
    local path   = vim.fs.joinpath(dir, ".luarc.json")
    local exists = vim.fn.filereadable(path) == 1

    local obj ---@type table
    if exists then
        local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
        if not ok or type(decoded) ~= "table" then
            return "skipped", path,
                "could not parse existing .luarc.json; add to Lua.workspace.library manually: "
                .. table.concat(lib_dirs, ", ")
        end
        obj = decoded
    else
        obj = {
            ["$schema"]                       = _SCHEMA,
            ["Lua.runtime.version"]           = "LuaJIT",
            ["Lua.workspace.checkThirdParty"] = false,
            ["Lua.diagnostics.globals"]       = { "vim", "easytasks" },
        }
    end

    -- Locate an existing library list (flat or nested form), else add a flat key.
    local lib = obj["Lua.workspace.library"]
    if type(lib) ~= "table"
        and type(obj.Lua) == "table"
        and type(obj.Lua.workspace) == "table"
        and type(obj.Lua.workspace.library) == "table"
    then
        lib = obj.Lua.workspace.library
    end
    if type(lib) ~= "table" then
        lib = {}
        obj["Lua.workspace.library"] = lib
    end

    local added = false
    for _, dir_entry in ipairs(lib_dirs) do
        local present = false
        for _, entry in ipairs(lib) do
            if entry == dir_entry then
                present = true
                break
            end
        end
        if not present then
            lib[#lib + 1] = dir_entry
            added         = true
        end
    end

    if not added then
        return exists and "unchanged" or "created", path
    end

    vim.fn.writefile(vim.split(_encode(obj, 0), "\n", { plain = true }), path)
    return exists and "updated" or "created", path
end

--- Create `<dir>/<tasks_filename>` from a starter template if it doesn't exist.
---@param dir string
---@return "created"|"exists" action, string path
local function _ensure_tasks_file(dir)
    local path = vim.fs.joinpath(dir, config.tasks_filename)
    if vim.fn.filereadable(path) == 1 then return "exists", path end

    local template = {
        "-- easytasks.nvim task file. Returns a map of task name → task spec, each",
        "-- built with a typed constructor. A field value may be plain data or a",
        "-- function, evaluated lazily at run time. Run tasks with :Tasks.",
        "-- `easytasks` (types, expand, …) is injected as a global; no require needed.",
        "",
        "---@type easytasks.Tasks",
        "return {",
        "    hello = easytasks.types.run {",
        '        command = { "echo", "hello from easytasks" },',
        "    },",
        "}",
        "",
    }
    vim.fn.writefile(template, path)
    return "created", path
end

--- Bootstrap `dir` (defaults to the project root, else the cwd): scaffold the
--- tasks file and wire up `.luarc.json`, reporting what changed.
---@param dir string?
function M.run(dir)
    dir = vim.fs.normalize(dir
        or require("easytasks.project").find_root()
        or vim.fn.getcwd())

    local tf_action, _ = _ensure_tasks_file(dir)
    local lr_action, _, lr_note = _ensure_luarc(dir, { _meta_dir(), _vim_runtime_lua_dir() })

    local lines = {
        "bootstrapped " .. dir,
        ("  %-12s %s"):format(config.tasks_filename, tf_action),
        ("  %-12s %s"):format(".luarc.json", lr_action),
    }
    if lr_note then lines[#lines + 1] = "  " .. lr_note end
    ui.notify_info(table.concat(lines, "\n"))
    ui_util.smart_open_file(config.tasks_filename)
end

return M
