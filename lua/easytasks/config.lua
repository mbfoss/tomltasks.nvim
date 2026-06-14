local M = {}

---@class easytasks.Config
---@field enabled       boolean
---@field command       string
---@field tasks_filename string
---@field storage_dir   string
---@field debug_backend string?  Name of the debug backend to use (default: "easydap")

---@type easytasks.Config
local config = {
    enabled        = true,
    command        = "Tasks",
    tasks_filename = "tasks.toml",
    storage_dir    = ".easytasks",
    debug_backend  = "nvim-dap"
}

return config
