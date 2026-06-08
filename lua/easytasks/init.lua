local M            = {}

local cfg          = require("easytasks.config")
local project      = require("easytasks.project")
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

--- Register a custom macro for use in task config values.
--- Macro syntax in TOML: `${name}` or `${name:arg1,arg2}`.
---@param name string
---@param fn   fun(ctx: easytasks.MacroCtx, ...): any, string?
function M.register_macro(name, fn)
    require("easytasks.runner.macros").register(name, fn)
end

---@type easytasks.Config
M.config = cfg.current

local enabled = false

---@type { name: string, path: string }?
local _last_task = nil

local function run_command()
    local cwd, err = project.find_root()
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
        _last_task = { name = choice, path = path }
        require("easytasks.save_buffers").save(cwd, cfg.current.save_buffers)
        status_panel.open()
        M.runner.run(choice, path)
    end)
end

local function clear_command()
    local all = require("easytasks.runner.exec").get_all()
    local count = 0
    local to_dispose = {}
    for run_id, entry in pairs(all) do
        if not entry.ephemeral
            and entry.state ~= "running"
            and entry.state ~= "waiting"
        then
            table.insert(to_dispose, run_id)
        end
    end
    for _, run_id in ipairs(to_dispose) do
        local ok, _ = M.runner.dispose(run_id)
        if ok then count = count + 1 end
    end
    if count == 0 then
        ui.notify_warning("no finished tasks to clear")
    end
end

local function stop_all_command()
    local all = require("easytasks.runner.exec").get_all()
    local seen = {}
    for _, entry in pairs(all) do
        if not entry.ephemeral
            and (entry.state == "running" or entry.state == "waiting")
            and not seen[entry.task_name]
        then
            seen[entry.task_name] = true
            M.runner.stop(entry.task_name)
        end
    end
    if not next(seen) then
        ui.notify_warning("no running tasks")
    end
end

local function stop_command()
    local all = require("easytasks.runner.exec").get_all()
    local names = {}
    local seen = {}
    for _, entry in pairs(all) do
        if not entry.ephemeral
            and (entry.state == "running" or entry.state == "waiting")
            and not seen[entry.task_name]
        then
            seen[entry.task_name] = true
            table.insert(names, entry.task_name)
        end
    end
    table.sort(names)
    if #names == 0 then
        ui.notify_warning("no running tasks")
        return
    end
    vim.ui.select(names, { prompt = "Stop task:" }, function(choice)
        if not choice then return end
        M.runner.stop(choice)
    end)
end

local function dispose_command()
    local all = require("easytasks.runner.exec").get_all()
    ---@type {run_id:string, label:string}[]
    local entries = {}
    for run_id, entry in pairs(all) do
        if not entry.ephemeral
            and entry.state ~= "running"
            and entry.state ~= "waiting"
        then
            table.insert(entries, {
                run_id = run_id,
                label  = entry.task_name .. "  [" .. entry.state .. "]",
            })
        end
    end
    table.sort(entries, function(a, b) return a.label < b.label end)
    if #entries == 0 then
        ui.notify_warning("no finished tasks to dispose")
        return
    end
    local labels = vim.tbl_map(function(e) return e.label end, entries)
    vim.ui.select(labels, { prompt = "Dispose task:" }, function(choice)
        if not choice then return end
        for _, e in ipairs(entries) do
            if e.label == choice then
                local ok, err = M.runner.dispose(e.run_id)
                if not ok then ui.notify_error(err or "dispose failed") end
                return
            end
        end
    end)
end

local function restart_command()
    if not _last_task then
        ui.notify_warning("no task has been run yet")
        return
    end
    local cwd, err = project.find_root()
    if not cwd then
        ui.notify_error(err or "not in a project root")
        return
    end
    local path = vim.fs.normalize(cwd .. "/" .. cfg.current.tasks_filename)
    if path ~= _last_task.path then
        ui.notify_warning("project changed since last run")
        return
    end
    require("easytasks.save_buffers").save(cwd, cfg.current.save_buffers)
    status_panel.open()
    M.runner.run(_last_task.name, _last_task.path)
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
            elseif action == "restart" then
                restart_command()
            elseif action == "stop_all" then
                stop_all_command()
            elseif action == "clear" then
                clear_command()
            elseif action == "stop" then
                stop_command()
            elseif action == "dispose" then
                dispose_command()
            elseif action == "toggle" then
                require("easytasks.ui.status_panel").toggle()
            elseif action == "jump" then
                require("easytasks.ui.status_panel").jump()
            else
                ui.notify_warning("Invalid action: " .. tostring(action))
            end
        end,
        {
            desc = "Easytasks",
            subcommand_fn = function(cmd, rest)
                if cmd == "Easytasks" and #rest == 0 then
                    return { "toggle", "run", "restart", "stop", "stop_all", "dispose", "clear", "jump" }
                end
                return {}
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

    project.init()

    if cfg.current.enabled then
        M.enable()
    else
        M.disable()
    end
end

---@return boolean
function M.in_project()
    return project.in_project()
end

--- Emitted (with root path) just before the cwd leaves a project root,
--- and also on VimLeavePre.
M.on_project_leave_pre = project.on_project_leave_pre ---@type easytasks.util.Signal<fun(root: string)>

--- Emitted (with root path) after the cwd enters a project root.
M.on_project_enter = project.on_project_enter ---@type easytasks.util.Signal<fun(root: string)>

--- Emitted after a cwd change lands outside any project root.
M.on_project_leave = project.on_project_leave ---@type easytasks.util.Signal<fun()>

--- Returns true if this instance holds the storage lock for the current project.
---@return boolean
function M.is_writable()
    return project.is_writable()
end

--- Store data under a namespace key in the project storage file.
---@param namespace string
---@param data table
---@return boolean,string?
function M.store_data(namespace, data)
    return project.store_data(namespace, data)
end

--- Load data for a namespace key from the project storage file.
---@param namespace string
---@return table|nil,string?
function M.load_data(namespace)
    return project.load_data(namespace)
end

return M
