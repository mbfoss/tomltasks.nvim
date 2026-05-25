local M = {}

---@class easytasks.Config
---@field enabled boolean
---@field schema  table?

local tasks_lsp = require("easytasks.tasks_lsp")

M.runner = require("easytasks.runner")

--- Register a task type. Can be called at any time before setup() to have the
--- type included in the schema, or after setup() for runtime-only use.
---@param name     string
---@param type_def easytasks.TaskTypeDef
function M.register_task_type(name, type_def)
    M.runner.register(name, type_def)
end

local function _get_default_config()
    ---@type easytasks.Config
    return {
        enabled = true,
        schema  = nil, -- built in setup() from registered types
    }
end

---@type easytasks.Config
M.config = _get_default_config()

local enabled = false

function M.enable()
    if enabled then return end
    enabled = true
    local augroup = vim.api.nvim_create_augroup("easytasks_tasks_lsp", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
        pattern  = { "toml" },
        group    = augroup,
        callback = function(ev)
            tasks_lsp.start(ev.buf, { schema = M.config.schema })
        end,
    })
end

function M.disable()
    if not enabled then return end
    enabled = false
    vim.api.nvim_del_augroup_by_name("easytasks_tasks_lsp")
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].filetype == "toml" then
            tasks_lsp.stop(buf)
        end
    end
end

---@param opts easytasks.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", _get_default_config(), opts or {})

    -- Build schema from all types registered so far (built-ins + any user types).
    -- Callers may supply their own schema to skip this entirely.
    if not M.config.schema then
        M.config.schema = M.runner.build_schema()
    end

    if M.config.enabled then
        M.enable()
    else
        M.disable()
    end
end

return M
