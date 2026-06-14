local config       = require("easytasks.config")
local runner       = require("easytasks.runner")
local task_types   = require("easytasks.types")
local status_panel = require("easytasks.ui.status_panel")
local ui           = require("easytasks.ui")
local select       = require("easytasks.util.select").select
local tomltools    = require("tomltools")
local project       = require("easytasks.project")

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
        local content = task and tomltools.encode(task) or nil
        return { name = name, preview = content and { content = content, filetype = "toml" } or nil }
    end, names)

    select(items, {
        prompt      = "Run task:",
        format_item = function(item) return item.name end,
    }, function(choice)
        if not choice then return end
        _last_task = { name = choice.name, path = path }
        status_panel.open()
        runner.run(choice.name, path)
    end)
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
    local all = require("easytasks.runner.exec").get_all()
    local count, to_dispose = 0, {}
    for run_id, entry in pairs(all) do
        if not entry.ephemeral
            and entry.state ~= "running"
            and entry.state ~= "waiting"
        then
            table.insert(to_dispose, run_id)
        end
    end
    for _, run_id in ipairs(to_dispose) do
        local ok, _ = runner.dispose(run_id)
        if ok then count = count + 1 end
    end
    if count == 0 then
        ui.notify_warning("no finished tasks to clear")
    end
end

local function _dispose_command()
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
                local ok, err = runner.dispose(e.run_id)
                if not ok then ui.notify_error(err or "dispose failed") end
                return
            end
        end
    end)
end

local function _add_template_command()
    local bufnr = vim.api.nvim_get_current_buf()
    local fname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
    if fname ~= config.tasks_filename then
        ui.notify_warning("not in the tasks file (" .. config.tasks_filename .. ")")
        return
    end

    local pos   = vim.api.nvim_win_get_cursor(0)
    local row   = pos[1] - 1
    local col   = pos[2]
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    table.insert(lines, "\n")
    local text = table.concat(lines, "\n")

    local path = tomltools.find_path(text, row, col)
    if not path or (path[1] and path[1].name ~= "tasks") then
        ui.notify_warning("cursor is not in a valid template insertion position")
        return
    end
    local _node      = path[1]

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
        local insert_lines = tomltools.encode(tmpl.task, {
            style  = (_node and _node.type == "array") and "inline" or "aot",
            key    = "tasks",
            indent = _node and _node.indent,
        })
        vim.api.nvim_win_set_cursor(0, { row + 1, col })
        vim.api.nvim_put(insert_lines, "c", false, true)
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
            elseif action == "stop" then
                _stop_command()
            elseif action == "cancel" then
                _stop_all_command()
            elseif action == "template" then
                _add_template_command()
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
                    local built_in = { "run", "rerun", "stop", "cancel", "template", "panel" }
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
