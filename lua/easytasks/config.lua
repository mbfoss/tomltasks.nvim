local M = {}

---@class easytasks.Config
---@field enabled            boolean
---@field command            string
---@field tasks_filename     string
---@field storage_dir        string
---@field lsp_debug_commands boolean enable LSP debug dump requests (`:Task lsp_dump`)

---@type easytasks.Config
local config = {
    enabled            = true,
    command            = "Tasks",
    tasks_filename     = "tasks.toml",
    storage_dir        = ".easytasks",
    lsp_debug_commands = false,
}

return config
