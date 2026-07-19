local config       = require("tomltasks.config")
local runner       = require("tomltasks.runner")
local task_types   = require("tomltasks.types")
local status_panel = require("tomltasks.ui.status_panel")
local ui           = require("tomltasks.ui")
local select       = require("tomltasks.util.select").select
local toml         = require("tomltasks.tomltools")
local project       = require("tomltasks.project")

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
        local content = task and toml.encode_entry(task, {style = "table", key = "task"}) or nil
        return { name = name, preview = content and { content = content, filetype = "tomltasks" } or nil }
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

local function _shell_command()
    status_panel.open_shell({ cwd = project.find_root() or nil })
end

--- Prompt for (or take, from the command arguments) an expression template and
--- print its resolved value. Runs against the current project's tasks file so
--- inline `[expressions]` are available alongside the built-ins.
---@param args string[]
local function _eval_command(args)
    local cwd, err = project.find_root()
    if not cwd then
        ui.notify_error(err or "not in a project root")
        return
    end
    local path = vim.fs.normalize(vim.fs.joinpath(cwd, config.tasks_filename))

    local function run(expr)
        if not expr or expr == "" then return end
        -- A bare expression (no `{{ … }}` hole) is treated as an expression name
        -- and wrapped, so `:Tasks eval file` resolves the `file` expression.
        if not expr:find("{{", 1, true) then
            expr = "{{ " .. expr .. " }}"
        end
        runner.eval_expression(expr, path, function(ok, result, eval_err)
            if not ok then
                ui.notify_error(eval_err or "expression evaluation failed")
                return
            end
            local text = type(result) == "string" and result or vim.inspect(result)
            vim.api.nvim_echo({ { text } }, true, {})
        end)
    end

    if #args > 0 then
        run(table.concat(args, " "))
    else
        vim.ui.input({ prompt = "Evaluate expression: " }, run)
    end
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
    local all = require("tomltasks.runner.exec").get_all()
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
    local all = require("tomltasks.runner.exec").get_all()
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

---@param args string[]
local function _lsp_dump_command(args)
    if not config.lsp_debug_commands then
        ui.notify_warning("lsp_debug_commands is not enabled")
        return
    end
    local buf = vim.api.nvim_get_current_buf()
    local what = args[1] or "data"
    require("tomltasks.lsp").dump(buf, what)
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

    local async = require("tomltasks.util.async")

    -- Insert the chosen template as a new `[tasks.<name>]` section. The template's
    -- own name becomes the header key (tasks are keyed by name), and the block is
    -- put on its own line(s) at the cursor, blank-separated from any preceding text.
    local function apply(tmpl)
        local task  = vim.deepcopy(tmpl.task)
        local name  = (type(task.name) == "string" and task.name ~= "") and task.name or "task"
        task.name   = nil
        local block = toml.encode_entry(task, { style = "table", key = { "tasks", name } })
        if vim.api.nvim_get_current_line() ~= "" then table.insert(block, 1, "") end
        vim.api.nvim_put(block, "l", true, true)
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
                if ok then doselect(result --[[@as tomltasks.TaskTemplate[] ]]) end
            end)
        else
            doselect(type_def.templates --[[@as tomltasks.TaskTemplate[] ]])
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
    local usercmd = require("tomltasks.tk.usercmd")
    usercmd.register_user_cmd(cmd_name,
        function(_, args, cmd_opts)
            local action = args[1]
            table.remove(args, 1)
            if action == nil or action == "" or action == "run" then
                _run_command()
            elseif action == "rerun" then
                _restart_command()
            elseif action == "shell" then
                _shell_command()
            elseif action == "eval" then
                _eval_command(args)
            elseif action == "stop" then
                _stop_command()
            elseif action == "cancel" then
                _stop_all_command()
            elseif action == "template" then
                _add_template_command()
            elseif action == "lsp_dump" then
                _lsp_dump_command(args)
            elseif action == "panel" then
                local sub = args[1]
                if sub == "jump" then
                    status_panel.jump(tonumber(args[2]))
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
                    _sub.run(action, args, cmd_opts)
                else
                    ui.notify_warning("Invalid action: " .. tostring(action))
                end
            end
        end,
        {
            desc = cmd_name,
            subcommand = function(_, rest, arg_lead)
                if #rest == 0 then
                    local actions = { "run", "rerun", "shell", "eval", "stop", "cancel", "template", "panel" }
                    if config.lsp_debug_commands then
                        table.insert(actions, "lsp_dump")
                    end
                    return actions
                end
                if rest[1] == "eval" and #rest == 1 then
                    local cwd = project.find_root()
                    if not cwd then return {} end
                    local path = vim.fs.normalize(vim.fs.joinpath(cwd, config.tasks_filename))
                    return runner.list_expression_names(path)
                end
                if rest[1] == "panel" and #rest == 1 then
                    return { "jump", "remove", "clear" }
                end
                if rest[1] == "lsp_dump" and #rest == 1 then
                    return { "cst", "decode_tree", "data", "schema" }
                end
                return {}
            end,
        })
end

return M
