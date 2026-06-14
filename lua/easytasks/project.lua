local Signal           = require("easytasks.util.Signal")
local datastore        = require("easytasks.datastore")
local M                = {}

local _cached_root     = nil ---@type string|nil

--- Emitted (with the root path) just before the cwd leaves a project root.
--- Also fires on VimLeavePre so consumers can persist state on exit.
M.on_project_leave_pre = Signal.new() ---@type easytasks.util.Signal<fun(root: string)>

--- Emitted (with the root path) after the cwd enters a project root.
M.on_project_enter     = Signal.new() ---@type easytasks.util.Signal<fun(root: string)>

--- Emitted after a cwd change lands outside any project root.
M.on_project_leave     = Signal.new() ---@type easytasks.util.Signal<fun()>

---@return boolean
function M.in_project()
    return M.find_root() ~= nil
end

--- Find the project root by checking for the tasks file in cwd.
---@return string|nil root
---@return string|nil err
function M.find_root()
    local config = require("easytasks.config")
    local cwd = vim.fn.getcwd() --[[@as string]]
    local tasks_path = vim.fs.normalize(vim.fs.joinpath(cwd, config.tasks_filename))
    ---@diagnostic disable-next-line: undefined-field
    if not vim.uv.fs_stat(tasks_path) then
        return nil, ("tasks file (%s) not found — not in a project root"):format(config.tasks_filename)
    end
    return cwd, nil
end

---@param root string
---@return string
local function _storage_dir(root)
    local config = require("easytasks.config")
    return vim.fs.normalize(vim.fs.joinpath(root, config.storage_dir))
end

local function _flush()
    datastore.save()
end

---@param root string
local function _warm(root)
    local dir = _storage_dir(root)
    vim.fn.mkdir(dir, "p")
    datastore.init(dir)
    _cached_root = root
end

---@param root string
local function _ensure(root)
    if root ~= _cached_root then
        _flush()
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
        end,
    })
    vim.api.nvim_create_autocmd("DirChangedPre", {
        callback = function()
            local root = M.find_root()
            if root then M.on_project_leave_pre:emit(root) end
            _flush()
        end,
    })
    vim.api.nvim_create_autocmd("DirChanged", {
        callback = function()
            _cached_root = nil
            local root = M.find_root()
            if root then
                M.on_project_enter:emit(root)
            else
                M.on_project_leave:emit()
            end
        end,
    })
end

---@param namespace string
---@param data table
---@return boolean ok
---@return string? err
function M.store_set(namespace, data)
    local root, err = M.find_root()
    if not root then return false, err end
    _ensure(root)
    datastore.set(namespace, data)
    return true
end

--- Load data for a namespace key from the project storage file.
---@param  namespace string
---@return table|nil
---@return string?
function M.store_get(namespace)
    local root, err = M.find_root()
    if not root then return nil, err end
    _ensure(root)
    return datastore.load(namespace), nil
end

---@param namespace string
---@param key string
---@param data      table
---@return boolean ok
---@return string? err
function M.store_add_key(namespace, key, data)
    local root, err = M.find_root()
    if not root then return false, err end
    _ensure(root)
    datastore.add(namespace, key, data)
    return true
end

---@param namespace string
---@param key string
---@return boolean ok
---@return string? err
function M.store_remove_key(namespace, key)
    local root, err = M.find_root()
    if not root then return false, err end
    _ensure(root)
    datastore.remove(namespace, key)
    return true
end


return M
