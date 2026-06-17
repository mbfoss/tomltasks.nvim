local config       = require("easytasks.config")
local runner       = require("easytasks.runner")
local task_types   = require("easytasks.types")
local status_panel = require("easytasks.ui.status_panel")
local ui           = require("easytasks.ui")
local select       = require("easytasks.util.select").select
local project      = require("easytasks.project")

local M            = {}

---@type { name: string, path: string }?
local _last_task   = nil

local function _run_command()
    local cwd, err = project.find_root()
    if not cwd then
        ui.notify_error(err or "not in a project root")
        return
    end

    local path = vim.fs.normalize(vim.fs.joinpath(cwd, config.tasks_filename))
    local names, by_name, list_err = runner.list_tasks(path)
    if not names then
        ui.notify_error(list_err or "failed to load tasks")
        return
    end

    local items = vim.tbl_map(function(name)
        local task    = by_name and by_name[name]
        local content = task and vim.inspect(task) or nil
        return { name = name, preview = content and { content = content, filetype = "lua" } or nil }
    end, names)

    select(items, {
        prompt      = "Run task:",
        format_item = function(item) return item.name end,
    }, function(choice)
        if not choice then return end
        _last_task = { name = choice.name, path = path }
        status_panel.open()
        runner.run(choice.name, path, by_name)
    end)
end

local function _shell_command()
    status_panel.open_shell({ cwd = project.find_root() or nil })
end

local function _restart_command()
    if not _last_task then
        ui.notify_warning("no task has been run yet")
        return
    end
    local cwd, err = project.find_root()
    if not cwd then
        ui.notify_error(err or "not in a project root")
        return
    end
    local path = vim.fs.normalize(vim.fs.joinpath(cwd, config.tasks_filename))
    if path ~= _last_task.path then
        ui.notify_warning("project changed since last run")
        return
    end
    status_panel.open()
    runner.run(_last_task.name, _last_task.path)
end

local function _stop_command()
    local all = require("easytasks.runner.exec").get_all()
    local names, seen = {}, {}
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
        runner.stop(choice)
    end)
end

local function _stop_all_command()
    local all = require("easytasks.runner.exec").get_all()
    local seen = {}
    for _, entry in pairs(all) do
        if not entry.ephemeral
            and (entry.state == "running" or entry.state == "waiting")
            and not seen[entry.task_name]
        then
            seen[entry.task_name] = true
            runner.stop(entry.task_name)
        end
    end
    if not next(seen) then
        ui.notify_warning("no running tasks")
    end
end

local function _clear_command()
    for _, e in ipairs(status_panel.disposable_entries()) do
        status_panel.dispose_entry(e.run_id)
    end
end

local function _dispose_command()
    local entries = status_panel.disposable_entries()
    if #entries == 0 then
        ui.notify_warning("no finished tasks to dispose")
        return
    end
    local labels = vim.tbl_map(function(e) return e.label end, entries)
    vim.ui.select(labels, { prompt = "Dispose task:" }, function(choice)
        if not choice then return end
        for _, e in ipairs(entries) do
            if e.label == choice then
                local ok, err = status_panel.dispose_entry(e.run_id)
                if not ok then ui.notify_error(err or "dispose failed") end
                return
            end
        end
    end)
end

--- Render a template `spec` table into a Lua task snippet, e.g.
---     run = require("easytasks.types").run {
---       command = "",
---     },
--- The `name`/`type` keys become the map entry name and the constructor call;
--- the remaining keys are the constructor argument.
---@param spec table
---@return string
local function _lua_snippet(spec)
    local name   = spec.name or "task"
    local typ    = spec.type or "run"
    local fields = {}
    for k, v in pairs(spec) do
        if k ~= "name" and k ~= "type" then fields[k] = v end
    end
    local body = vim.inspect(fields)
    return ('%s = easytasks.types.%s %s,'):format(name, typ, body)
end

local function _bootstrap_command()
    require("easytasks.bootstrap").run()
end

local function _add_template_command()
    local bufnr = vim.api.nvim_get_current_buf()
    local fname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
    if fname ~= config.tasks_filename then
        ui.notify_warning("not in the tasks file (" .. config.tasks_filename .. ")")
        return
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

    local async = require("easytasks.util.async")

    local function apply(tmpl)
        local lines  = vim.split(_lua_snippet(tmpl.spec), "\n", { plain = true })
        local indent = (vim.api.nvim_get_current_line():match("^%s*")) or ""
        for i = 2, #lines do lines[i] = indent .. lines[i] end
        vim.api.nvim_put(lines, "c", false, true)
    end

    local function show_templateselect(type_name)
        local type_def = all_types[type_name]
        local function doselect(templates)
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
                if ok then doselect(result --[[@as easytasks.TaskTemplate[] ]]) end
            end)
        else
            doselect(type_def.templates --[[@as easytasks.TaskTemplate[] ]])
        end
    end

    if #type_names == 1 then
        show_templateselect(type_names[1])
    else
        vim.ui.select(type_names, { prompt = "Task type:" }, function(choice)
            if choice then show_templateselect(choice) end
        end)
    end
end

---@param cmd_name string
function M.register(cmd_name)
    local usercmd = require("easytasks.util.usercmd")
    usercmd.register_user_cmd(cmd_name,
        function(_, args, _)
            local action = args[1]
            table.remove(args, 1)
            if action == nil or action == "" or action == "run" then
                _run_command()
            elseif action == "rerun" then
                _restart_command()
            elseif action == "shell" then
                _shell_command()
            elseif action == "stop" then
                _stop_command()
            elseif action == "cancel" then
                _stop_all_command()
            elseif action == "template" then
                _add_template_command()
            elseif action == "bootstrap" then
                _bootstrap_command()
            elseif action == "panel" then
                local sub = args[1]
                if sub == "pick" then
                    status_panel.jump()
                elseif sub == "remove" then
                    _dispose_command()
                elseif sub == "clear" then
                    _clear_command()
                else
                    status_panel.toggle()
                end
            else
                local _sub = usercmd.get_subcommand(action)
                if _sub then
                    _sub.run(action, args, _)
                else
                    ui.notify_warning("Invalid action: " .. tostring(action))
                end
            end
        end,
        {
            desc = cmd_name,
            subcommand_fn = function(_, rest, arg_lead)
                if #rest == 0 then
                    local built_in = { "run", "rerun", "shell", "stop", "cancel", "template", "bootstrap", "panel" }
                    vim.list_extend(built_in, usercmd.subcommand_names())
                    return built_in
                end
                if rest[1] == "panel" and #rest == 1 then
                    return { "pick", "remove", "clear" }
                end
                if #rest >= 1 then
                    local _sub = usercmd.get_subcommand(rest[1])
                    if _sub then return _sub.complete({ unpack(rest, 2) }, arg_lead) end
                end
                return {}
            end,
        })
end

return M
