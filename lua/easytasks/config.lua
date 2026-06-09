local M = {}

---@class easytasks.LogConfig
---@field enabled boolean
---@field path? string
---@field level? "debug"|"info"|"warn"|"error"

---@class easytasks.Config
---@field enabled boolean
---@field command string
---@field tasks_filename string
---@field storage_dir string
---@field log easytasks.LogConfig
---@field save_buffers easytasks.SaveBuffersConfig

---@return easytasks.Config
function M.default()
    return {
        enabled        = true,
        command        = "Task",
        tasks_filename = "tasks.toml",
        storage_dir    = ".easytasks",
        log            = { enabled = false },
        save_buffers     = {
            include_globs = {},
            exclude_globs = {},
        },
    }
end

---@type easytasks.Config
M.current = M.default()

return M
