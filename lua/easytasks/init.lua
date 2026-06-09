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

local _enabled = false

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

local function add_template_command()
    local bufnr = vim.api.nvim_get_current_buf()
    local fname  = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
    if fname ~= cfg.current.tasks_filename then
        ui.notify_warning("not in the tasks file (" .. cfg.current.tasks_filename .. ")")
        return
    end

    local pos = vim.api.nvim_win_get_cursor(0)
    local row  = pos[1] - 1
    local col  = pos[2]

    local parser  = require("tomltools.toml.parser")
    local decoder = require("tomltools.toml.decoder")
    local lines   = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local text    = table.concat(lines, "\n")
    local parsed  = parser.parse(text)
    if not parsed.cst then
        ui.notify_warning("failed to parse tasks file")
        return
    end
    local decoded = decoder.decode(parsed.cst)

    local tmpl_actions = require("easytasks.template_ctx")
    local ins_kind, node_id = tmpl_actions.tasks_insertion_ctx(parsed.cst, decoded.decode_tree, row, col)
    if not ins_kind then
        ui.notify_warning("cursor is not in a valid template insertion position")
        return
    end

    local indent = ""
    if ins_kind == "array" and node_id then
        indent = tmpl_actions.array_item_indent(lines, parsed.cst, node_id)
    end

    local all_types  = task_types.get_all()
    local type_names = {}
    for name, def in pairs(all_types) do
        if def.templates then type_names[#type_names + 1] = name end
    end
    table.sort(type_names)

    if #type_names == 0 then
        ui.notify_warning("no task types with templates defined")
        return
    end

    local encoder = require("tomltools.toml.encoder")
    local async   = require("easytasks.util.async")
    local entry   = { row = row, col = col, kind = ins_kind, indent = indent }

    local function apply(tmpl)
        local insert_lines
        if entry.kind == "array" then
            local encoded = encoder.encode_inline(tmpl.task, { multiline = true, indent = entry.indent })
            insert_lines  = vim.split(encoded, "\n", { plain = true })
        else
            local block  = encoder.encode_aot_entry("tasks", tmpl.task)
            insert_lines = vim.split(block, "\n", { plain = true })
        end
        vim.api.nvim_win_set_cursor(0, { entry.row + 1, entry.col })
        vim.api.nvim_put(insert_lines, "c", false, true)
    end

    local function show_template_select(type_name)
        local type_def = all_types[type_name]
        local function do_select(templates)
            if not templates or #templates == 0 then
                ui.notify_warning("no templates for type: " .. type_name)
                return
            end
            vim.ui.select(templates, {
                prompt      = "Choose " .. type_name .. " template:",
                format_item = function(item) return item.label end,
            }, function(choice)
                if choice then vim.schedule(function() apply(choice) end) end
            end)
        end
        if type(type_def.templates) == "function" then
            local fn = type_def.templates ---@cast fn function
            async.go(fn, function(ok, result)
                if ok then do_select(result --[[@as easytasks.TaskTemplate[] ]]) end
            end)
        else
            do_select(type_def.templates --[[@as easytasks.TaskTemplate[] ]])
        end
    end

    if #type_names == 1 then
        show_template_select(type_names[1])
    else
        vim.ui.select(type_names, { prompt = "Task type:" }, function(choice)
            if choice then show_template_select(choice) end
        end)
    end
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
    if _enabled then return end
    _enabled = true

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
        function(_, args, _)
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
            elseif action == "add_template" then
                add_template_command()
            else
                ui.notify_warning("Invalid action: " .. tostring(action))
            end
        end,
        {
            desc = "Easytasks",
            subcommand_fn = function(cmd, rest)
                if cmd == "Easytasks" and #rest == 0 then
                    return { "toggle", "run", "restart", "stop", "stop_all", "dispose", "clear", "jump", "add_template" }
                end
                return {}
            end
        })
end

function M.disable()
    if not _enabled then return end
    _enabled = false
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
