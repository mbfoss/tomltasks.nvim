local Signal = require("easytasks.util.Signal")
local M = {}

local _cached_root = nil ---@type string|nil
local _cache       = {} ---@type table
local _dirty       = false

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
local function read_json(path)
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
local function write_json(path, tbl)
    local f = io.open(path, "w")
    if not f then return end
    f:write(vim.fn.json_encode(tbl))
    f:close()
end

---@param root string
---@return string
local function storage_path(root)
    local cfg = require("easytasks.config")
    return vim.fs.normalize(root .. "/" .. cfg.current.storage_filename)
end

local function _flush()
    if not _dirty or not _cached_root then return end
    write_json(storage_path(_cached_root), _cache)
    _dirty = false
end

---@param root string
local function _warm(root)
    _cached_root = root
    _cache = read_json(storage_path(root))
    _dirty = false
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
            _cache = {}
            _dirty = false
            local root = M.find_root()
            if root then
                M.on_project_enter:emit(root)
            else
                M.on_project_leave:emit()
            end
        end,
    })
end

--- Store data under a namespace key in the project storage file.
---@param namespace string
---@param data table
---@return boolean,string?
function M.store_data(namespace, data)
    local root, err = M.find_root()
    if not root then
        return false, err
    end
    _ensure(root)
    _cache[namespace] = data
    _dirty = true
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
    return _cache[namespace]
end

return M
