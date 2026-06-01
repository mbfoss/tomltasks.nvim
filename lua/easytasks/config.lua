local M = {}

---@class easytasks.LogConfig
---@field enabled boolean
---@field path? string
---@field level? "debug"|"info"|"warn"|"error"

---@class easytasks.Config
---@field enabled boolean
---@field tasks_filename string
---@field storage_filename string
---@field log easytasks.LogConfig
---@field save_buffers easytasks.SaveBuffersConfig

---@return easytasks.Config
function M.default()
    return {
        enabled          = true,
        tasks_filename   = "tasks.toml",
        storage_filename = ".task-data.json",
        log              = { enabled = false },
        save_buffers     = {
            include_globs = {},
            exclude_globs = {},
        },
    }
end

---@type easytasks.Config
M.current = M.default()

return M
