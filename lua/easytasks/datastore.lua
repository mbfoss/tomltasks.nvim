local fsutil = require("easytasks.util.fsutil")
local M      = {}

---@class easytasks.datastore.Pending
---@field writes  table<string, any>
---@field deletes table<string, boolean>

local _dir        = nil ---@type string|nil
local _pending    = {} ---@type table<string, easytasks.datastore.Pending>
local _disk_cache = {} ---@type table<string, table>

---@param namespace string
---@return string
local function _path(namespace)
    return string.format("%s/%s.json", _dir, namespace)
end

---@param path string
---@return table
local function _read_json(path)
    local ok, content = fsutil.read_content(path)
    if not ok or content == "" then return {} end
    local decode_ok, decoded = pcall(vim.fn.json_decode, content)
    if not decode_ok or type(decoded) ~= "table" then return {} end
    return decoded
end

---@param path string
---@param tbl  table
local function _write_json(path, tbl)
    local tmp = string.format("%s.%d.tmp", path, vim.uv.os_getpid())
    fsutil.write_content(tmp, vim.fn.json_encode(tbl))
    os.rename(tmp, path)
end

---@param namespace string
---@return easytasks.datastore.Pending
local function _get_pending(namespace)
    if not _pending[namespace] then
        _pending[namespace] = { writes = {}, deletes = {} }
    end
    return _pending[namespace]
end

--- Initialize (or re-initialize) with a new storage directory.
--- Clears all pending changes and the disk cache.
---@param dir string
function M.init(dir)
    _dir        = dir
    _pending    = {}
    _disk_cache = {}
end

--- Add or update a single key within a namespace.
---@param namespace string
---@param key       string
---@param value     any
function M.add(namespace, key, value)
    local p = _get_pending(namespace)
    p.writes[key]  = value
    p.deletes[key] = nil
end

--- Replace the entire namespace. On save no merge is performed — the disk
--- file is overwritten with exactly this map.
---@param namespace string
---@param map       {string:any}
function M.set(namespace, map)
    _pending[namespace] = { writes = vim.deepcopy(map), deletes = {} }
end

--- Remove a single key from a namespace.
---@param namespace string
---@param key       string
function M.remove(namespace, key)
    local p = _get_pending(namespace)
    p.deletes[key] = true
    p.writes[key]  = nil
end

--- Flush all pending changes to disk.
--- Namespaces written with set() are written directly (no merge).
--- Namespaces modified with add()/remove() are read from disk first so that
--- keys written by other instances are preserved; tombstones and local writes
--- are then applied before the file is atomically renamed into place.
function M.save()
    if not _dir then return end
    for ns, p in pairs(_pending) do
        local result
        local disk = _read_json(_path(ns))
        for k in pairs(p.deletes) do disk[k] = nil end
        for k, v in pairs(p.writes) do disk[k] = v end
        result = disk
        _write_json(_path(ns), result)
        _disk_cache[ns] = result
        _pending[ns]    = nil
    end
end

--- Return the current view of a namespace: disk contents merged with any
--- pending add/set/remove operations. Does not flush to disk.
---@param  namespace string
---@return table
function M.load(namespace)
    if not _dir then return {} end
    if _disk_cache[namespace] == nil then
        _disk_cache[namespace] = _read_json(_path(namespace))
    end
    local p = _pending[namespace]
    if not p then
        return vim.deepcopy(_disk_cache[namespace])
    end
    local result = vim.deepcopy(_disk_cache[namespace])
    for k in pairs(p.deletes) do result[k] = nil end
    for k, v in pairs(p.writes) do result[k] = v end
    return result
end

return M
