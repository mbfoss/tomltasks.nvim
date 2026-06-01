local M            = {}

---@class easytasks.LogConfig
---@field enabled boolean
---@field path? string
---@field level? "debug"|"info"|"warn"|"error"

---@class easytasks.Config
---@field enabled boolean
---@field tasks_filename string
---@field log easytasks.LogConfig

local tasks_lsp    = require("easytasks.lsp")
local task_types   = require("easytasks.types")
local status_panel = require("easytasks.ui.status_panel")
local ui           = require("easytasks.ui")

M.runner           = require("easytasks.runner")

--- Register a task type. Can be called at any time before setup() to have the
--- type included in the schema, or after setup() for runtime-only use.
--- `loader` may be a module path string, a zero-arg factory function, or a
--- fully-resolved TaskTypeDef table.
---@param name   string
---@param loader easytasks.TypeLoader
function M.register_task_type(name, loader)
    task_types.register(name, loader)
end

--- Register a custom quickfix matcher for use in process tasks.
---@param name string
---@param fn   easytasks.QfMatcher
function M.register_qfmatcher(name, fn)
    require("easytasks.types.process").register_qfmatcher(name, fn)
end

local function _get_default_config()
    ---@type easytasks.Config
    return {
        enabled        = true,
        tasks_filename = "tasks.toml",
        log            = { enabled = false },
    }
end

---@type easytasks.Config
M.config = _get_default_config()

local enabled = false

---@param args string[]
local function run_command(args)
    local path = args[1]
    if not path or path == "" then
        path = vim.fn.findfile(M.config.tasks_filename, vim.fn.getcwd() .. ";") --[[@as string]]
    end

    if path == "" then
        ui.notify_error(("tasks file (%s) not found"):format(M.config.tasks_filename))
        return
    end

    local names, err = M.runner.list_tasks(path)
    if not names then
        ui.notify_error(err or "failed to load tasks")
        return
    end

    vim.ui.select(names, {
        prompt = "Run task:",
    }, function(choice)
        if not choice then return end
        status_panel.open()
        M.runner.run(choice, path)
    end)
end

function M.enable()
    if enabled then return end
    enabled = true

    if M.config.log.enabled then
        require("easytasks.util.log").enable(M.config.log.path, M.config.log.level)
    end

    local augroup = vim.api.nvim_create_augroup("easytasks_tasks_lsp", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
        pattern  = { "toml" },
        group    = augroup,
        callback = function(ev)
            if vim.fn.fnamemodify(ev.file, ":t") == M.config.tasks_filename then
                tasks_lsp.start(ev.buf, { schema = task_types.build_schema() })
            end
        end,
    })


    require("easytasks.util.usercmd").register_user_cmd("Easytasks",
        function(cmd, args, cmd_opts)
            local action = args[1]
            table.remove(args, 1)
            if action == nil or action == "" or action == "run" then
                run_command(args)
            elseif action == "toggle" then
                require("easytasks.ui.status_panel").toggle()
            else
                ui.notify_warning("Invalid action: " .. tostring(action))
            end
        end,
        {
            desc = "Easytasks",
            subcommand_fn = function(cmd, rest)
                return { "toggle", "run" }
            end
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

    if M.config.enabled then
        M.enable()
    else
        M.disable()
    end
end

return M
