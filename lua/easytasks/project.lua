local Signal = require("easytasks.util.Signal")
local flock  = require("easytasks.util.flock")
local M = {}

local _cached_root = nil    ---@type string|nil
local _cache       = {}     ---@type table<string, table>
local _dirty       = {}     ---@type table<string, boolean>
local _lock_held   = false  ---@type boolean

--- Emitted (with the root path) just before the cwd leaves a project root.
--- Also fires on VimLeavePre so consumers can persist state on exit.
M.on_project_leave_pre = Signal.new() ---@type easytasks.util.Signal<fun(root: string)>

--- Emitted (with the root path) after the cwd enters a project root.
M.on_project_enter = Signal.new() ---@type easytasks.util.Signal<fun(root: string)>

--- Emitted after a cwd change lands outside any project root.
M.on_project_leave  = Signal.new() ---@type easytasks.util.Signal<fun()>

---@return boolean
function M.in_project()
    local root = M.find_root()
    return root ~= nil
end

--- Find the project root by checking for the tasks file in cwd.
---@return string|nil root
---@return string|nil err
function M.find_root()
    local cfg = require("easytasks.config")
    local cwd = vim.fn.getcwd() --[[@as string]]
    local tasks_path = vim.fs.normalize(cwd .. "/" .. cfg.current.tasks_filename)
    ---@diagnostic disable-next-line: undefined-field
    if not vim.uv.fs_stat(tasks_path) then
        return nil, ("tasks file (%s) not found — not in a project root"):format(cfg.current.tasks_filename)
    end
    return cwd, nil
end

---@param path string
---@return table
local function _read_json(path)
    local f = io.open(path, "r")
    if not f then return {} end
    local data = f:read("*a")
    f:close()
    if not data or data == "" then return {} end
    local ok, decoded = pcall(vim.fn.json_decode, data)
    if not ok or type(decoded) ~= "table" then return {} end
    return decoded
end

---@param path string
---@param tbl table
local function _write_json(path, tbl)
    local f = io.open(path, "w")
    if not f then return end
    f:write(vim.fn.json_encode(tbl))
    f:close()
end

---@param root string
---@return string
local function _storage_dir(root)
    local cfg = require("easytasks.config")
    return vim.fs.normalize(root .. "/" .. cfg.current.storage_dir)
end

---@param root string
---@param namespace string
---@return string
local function _namespace_path(root, namespace)
    return vim.fs.normalize(_storage_dir(root) .. "/" .. namespace .. ".json")
end

---@param root string
---@return string
local function _lock_path(root)
    return vim.fs.normalize(_storage_dir(root) .. "/.lock")
end

local function _flush()
    if not _cached_root or not _lock_held then return end
    local has_dirty = false
    for _, v in pairs(_dirty) do
        if v then has_dirty = true; break end
    end
    if not has_dirty then return end
    for ns, dirty in pairs(_dirty) do
        if dirty then
            _write_json(_namespace_path(_cached_root, ns), _cache[ns] or {})
            _dirty[ns] = false
        end
    end
end

local function _release()
    if _cached_root and _lock_held then
        flock.unlock(_lock_path(_cached_root))
        _lock_held = false
    end
end

---@param root string
local function _warm(root)
    local dir = _storage_dir(root)
    vim.fn.mkdir(dir, "p")
    local ok = flock.lock(_lock_path(root))
    _cached_root = root
    _cache = {}
    _dirty = {}
    _lock_held = ok
end

---@param root string
local function _ensure(root)
    if root ~= _cached_root then
        _flush()
        _release()
        _warm(root)
    end
end

local _initialized = false

--- Register autocmds for flush-on-exit and cwd-change tracking.
--- Called once during plugin setup.
function M.init()
    if _initialized then return end
    _initialized = true

    vim.api.nvim_create_autocmd("VimLeavePre", {
        once     = true,
        callback = function()
            local root = M.find_root()
            if root then M.on_project_leave_pre:emit(root) end
            _flush()
            _release()
        end,
    })
    vim.api.nvim_create_autocmd("DirChangedPre", {
        callback = function()
            local root = M.find_root()
            if root then M.on_project_leave_pre:emit(root) end
            _flush()
            _release()
        end,
    })
    vim.api.nvim_create_autocmd("DirChanged", {
        callback = function()
            _cached_root = nil
            _cache = {}
            _dirty = {}
            _lock_held = false
            local root = M.find_root()
            if root then
                M.on_project_enter:emit(root)
            else
                M.on_project_leave:emit()
            end
        end,
    })
end

--- Returns true if this instance holds the storage lock for the current project.
--- Plugins can subscribe to their own change signals and call this to decide
--- whether to warn the user that writes will be dropped.
---@return boolean
function M.is_writable()
    local root = M.find_root()
    if not root then return false end
    _ensure(root)
    return _lock_held
end

--- Store data under a namespace key in the project storage file.
--- If another Neovim instance holds the storage lock a one-time warning is
--- emitted (per project) and the write is dropped — callers do not need to
--- handle the conflict themselves.
---@param namespace string
---@param data table
---@return boolean ok
---@return string? err
function M.store_data(namespace, data)
    local root, err = M.find_root()
    if not root then return false, err end
    _ensure(root)
    if not _lock_held then return false, "storage folder is in use by another Neovim instance" end
    _cache[namespace] = data
    _dirty[namespace] = true
    return true
end

--- Load data for a namespace key from the project storage file.
---@param namespace string
---@return table|nil,string?
function M.load_data(namespace)
    local root, err = M.find_root()
    if not root then
        return nil, err
    end
    _ensure(root)
    if not _lock_held then return nil, "storage folder is in use by another Neovim instance" end
    if _cache[namespace] == nil then
        _cache[namespace] = _read_json(_namespace_path(root, namespace))
    end
    return _cache[namespace]
end

return M
