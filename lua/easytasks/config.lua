local M = {}

---@class easytasks.Config
---@field enabled       boolean
---@field command       string
---@field tasks_filename string
---@field storage_dir   string

---@type easytasks.Config
local config = {
    enabled        = true,
    command        = "Tasks",
    tasks_filename = "tasks.toml",
    storage_dir    = ".easytasks",
}

return config
