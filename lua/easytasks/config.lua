local M = {}

---@class easytasks.Config
---@field enabled boolean
---@field command string
---@field tasks_filename string
---@field storage_dir string

---@return easytasks.Config
function M.default()
    return {
        enabled        = true,
        command        = "Tasks",
        tasks_filename = "tasks.toml",
        storage_dir    = ".easytasks",
    }
end

---@type easytasks.Config
M.current = M.default()

return M
