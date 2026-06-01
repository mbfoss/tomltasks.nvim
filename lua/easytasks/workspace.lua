local M = {}

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

--- Store data under a namespace key in the workspace storage file.
--- Reports an error if not in a project root.
---@param namespace string
---@param data table
function M.store_data(namespace, data)
    local root, err = M.find_root()
    if not root then
        vim.notify("easytasks: " .. (err or "unknown error"), vim.log.levels.ERROR)
        return
    end
    local path = storage_path(root)
    local all = read_json(path)
    all[namespace] = data
    write_json(path, all)
end

--- Load data for a namespace key from the workspace storage file.
--- Returns nil and reports an error if not in a project root.
---@param namespace string
---@return table|nil
function M.load_data(namespace)
    local root, err = M.find_root()
    if not root then
        vim.notify("easytasks: " .. (err or "unknown error"), vim.log.levels.ERROR)
        return nil
    end
    local all = read_json(storage_path(root))
    return all[namespace]
end

return M
