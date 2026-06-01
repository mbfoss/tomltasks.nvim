local M            = {}

local cfg          = require("easytasks.config")
local workspace    = require("easytasks.workspace")
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

---@type easytasks.Config
M.config = cfg.current

local enabled = false

local function run_command()
    local cwd, err = workspace.find_root()
    if not cwd then
        ui.notify_error(err or "not in a project root")
        return
    end

    local path = vim.fs.normalize(cwd .. "/" .. cfg.current.tasks_filename)
    local names, list_err = M.runner.list_tasks(path)
    if not names then
        ui.notify_error(list_err or "failed to load tasks")
        return
    end

    vim.ui.select(names, {
        prompt = "Run task:",
    }, function(choice)
        if not choice then return end
        require("easytasks.save_buffers").save(cwd, cfg.current.save_buffers)
        status_panel.open()
        M.runner.run(choice, path)
    end)
end

function M.enable()
    if enabled then return end
    enabled = true

    if cfg.current.log.enabled then
        require("easytasks.util.log").enable(cfg.current.log.path, cfg.current.log.level)
    end

    local augroup = vim.api.nvim_create_augroup("easytasks_tasks_lsp", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
        pattern  = { "toml" },
        group    = augroup,
        callback = function(ev)
            if vim.fn.fnamemodify(ev.file, ":t") == cfg.current.tasks_filename then
                tasks_lsp.start(ev.buf, { schema = task_types.build_schema() })
            end
        end,
    })


    require("easytasks.util.usercmd").register_user_cmd("Easytasks",
        function(cmd, args, cmd_opts)
            local action = args[1]
            table.remove(args, 1)
            if action == nil or action == "" or action == "run" then
                run_command()
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
    cfg.current = vim.tbl_deep_extend("force", cfg.default(), opts or {})
    M.config = cfg.current

    if cfg.current.enabled then
        M.enable()
    else
        M.disable()
    end
end

--- Store data under a namespace key in the workspace storage file.
---@param namespace string
---@param data table
function M.store_data(namespace, data)
    workspace.store_data(namespace, data)
end

--- Load data for a namespace key from the workspace storage file.
---@param namespace string
---@return table|nil
function M.load_data(namespace)
    return workspace.load_data(namespace)
end

return M
