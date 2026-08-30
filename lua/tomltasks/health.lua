---@brief Health check for tomltasks.nvim — run with `:checkhealth tomltasks`.
---
---Reports the Neovim version and the optional companion plugins, whether
---`setup()` has run, the options that differ from the defaults, the tasks file
---found for the cwd, and the registered task types (with the ezdap adapters the
---`debug` type may use).

local M = {}

local health = vim.health

---The plugin module, read through `package.loaded` rather than required: an
---unloaded tomltasks is itself the answer, and loading it here would not have
---run `setup()` anyway.
---@return table?
local function _plugin()
    return package.loaded["tomltasks"]
end

---@return boolean
local function _is_setup()
    local plugin = _plugin()
    return (plugin and plugin.is_setup()) or false
end

---Check the Neovim version against the plugin's minimum (see
---`plugin/tomltasks.lua`) and report the optional companion plugins.
local function _check_requirements()
    health.start("tomltasks: requirements")

    if vim.fn.has("nvim-0.11") == 1 then
        health.ok("Neovim " .. tostring(vim.version()))
    else
        health.error("tomltasks.nvim requires Neovim >= 0.11")
    end

    -- Both are optional: without ezdap there is no `debug` task type, and
    -- without dock the task output goes to a plain bottom split.
    if pcall(require, "ezdap.schema") then
        health.ok("ezdap.nvim is installed (the `debug` task type is available)")
    else
        health.info("ezdap.nvim is not installed, so there is no `debug` task type")
    end

    if pcall(require, "dock") then
        health.ok("dock.nvim is installed (task output goes to the dock panel)")
    else
        health.info("dock.nvim is not installed, so task output goes to a bottom split")
    end
end

---Report whether `setup()` has run and what it wired up: the user command and
---the tasks-file LSP both hang off it.
local function _check_setup()
    health.start("tomltasks: setup")

    local config = require("tomltasks.config")

    if _is_setup() then
        health.ok("setup() has been called")
    else
        -- `:Tasks` and the LSP are registered at startup by plugin/tomltasks.lua,
        -- so the plugin works with no setup() at all — it is only needed to
        -- change an option.
        health.info("setup() has not been called (the defaults are in force)")
    end

    if not config.enabled then
        health.warn("the plugin is disabled (`enabled = false`)", {
            "Re-enable it with require('tomltasks').enable()",
        })
        return
    end

    if vim.fn.exists(":" .. config.command) == 2 then
        health.ok((":%s is registered"):format(config.command))
    else
        health.error((":%s is not registered"):format(config.command))
    end

    local server = require("tomltasks.lsp").SERVER_NAME
    local ok, declared = pcall(function() return vim.lsp.config[server] end)
    if ok and declared then
        health.ok(("the `%s` language server is declared for the `tomltasks` filetype")
            :format(server))
    else
        health.warn(("the `%s` language server is not declared"):format(server), {
            "It is declared at startup; check that plugin/tomltasks.lua loaded",
        })
    end
end

---Collect the options whose value differs from the default, as flat paths with
---the value now in force. Lists are compared whole rather than descended into:
---`debug_adapters` is one option, not one option per adapter.
---@param current table
---@param defaults table
---@param prefix string  path of the enclosing table, "" at the top level
---@param out table[]
---@return table[]
local function _diff_config(current, defaults, prefix, out)
    for key, value in pairs(current) do
        local path = prefix .. tostring(key)
        local default = defaults[key]
        if type(value) == "table" and type(default) == "table" and not vim.islist(value) then
            _diff_config(value, default, path .. ".", out)
        elseif not vim.deep_equal(value, default) then
            table.insert(out, {
                path    = path,
                value   = vim.inspect(value),
                unknown = default == nil,
            })
        end
    end
    return out
end

---Report the options that differ from the defaults — the whole config would be
---mostly untouched defaults, and the point here is what this user changed.
---Anything set that the plugin does not define is flagged: `setup()` merges
---`opts` wholesale, so a misspelled option is kept silently.
local function _check_config()
    health.start("tomltasks: configuration")

    local plugin = _plugin()
    if not (plugin and plugin.is_setup()) then
        health.info("setup() has not been called, so every option is at its default")
        return
    end

    local diffs = _diff_config(require("tomltasks.config"), plugin.get_default_config(), "", {})
    table.sort(diffs, function(a, b) return a.path < b.path end)

    if #diffs == 0 then
        health.ok("every option is at its default")
        return
    end

    local lines = {}
    for _, entry in ipairs(diffs) do
        table.insert(lines, ("  %s = %s"):format(entry.path, entry.value))
    end
    health.ok(("%d option%s differ from the defaults:\n%s")
        :format(#diffs, #diffs == 1 and "" or "s", table.concat(lines, "\n")))

    for _, entry in ipairs(diffs) do
        if entry.unknown then
            health.warn(("`%s` is not an option tomltasks defines"):format(entry.path), {
                "Check its spelling against :help tomltasks-config",
            })
        end
    end
end

---Report the project for the cwd and what its tasks file holds. Loading the
---file is the check: the same parse and schema validation the runner does is
---what turns a typo here into an error.
local function _check_project()
    health.start("tomltasks: project")

    local config = require("tomltasks.config")
    local root   = require("tomltasks.project").find_root()
    if not root then
        health.info(("cwd is not a project root (no %s in %s)")
            :format(config.tasks_filename, vim.fn.getcwd()))
        return
    end

    local path = vim.fs.joinpath(root, config.tasks_filename)
    local names, by_name, err = require("tomltasks.runner").list_tasks(path)
    if not names then
        health.error(("%s does not load: %s"):format(path, tostring(err)))
        return
    end

    if #names == 0 then
        health.warn(("%s loads, but declares no tasks"):format(path))
        return
    end

    -- The type counts say at a glance which halves of the plugin this project
    -- leans on, and surface a type no longer registered (an uninstalled ezdap
    -- leaves the project's `debug` tasks behind).
    local counts, types = {}, {}
    for _, name in ipairs(names) do
        local task_type = tostring((by_name[name] or {}).type)
        if not counts[task_type] then
            counts[task_type] = 0
            types[#types + 1] = task_type
        end
        counts[task_type] = counts[task_type] + 1
    end
    table.sort(types)

    local parts = {}
    for _, task_type in ipairs(types) do
        parts[#parts + 1] = ("%s (%d)"):format(task_type, counts[task_type])
    end
    health.ok(("%s: %d task%s — %s")
        :format(path, #names, #names == 1 and "" or "s", table.concat(parts, ", ")))

    local registered = require("tomltasks.types")
    for _, task_type in ipairs(types) do
        if not registered.get(task_type) then
            health.error(("task type `%s` is used but not registered"):format(task_type))
        end
    end
end

---Report the ezdap adapters the `debug` type may use — `debug_adapters`
---resolved against ezdap's registry, since only those get a definition loaded
---and a task on any other adapter refuses to start.
local function _check_debug_adapters()
    local wanted = require("tomltasks.config").debug_adapters or {}
    if #wanted == 0 then
        health.warn("`debug_adapters` is empty, so no `debug` task can start", {
            "List the adapters you use, e.g. debug_adapters = { 'codelldb' }",
            "See the names available with :lua =require('ezdap').available_adapters()",
        })
        return
    end

    -- Resolving the names asks ezdap for its registry, which needs ezdap's own
    -- setup(); that is ezdap's health check to report, not ours.
    local ok, usable = pcall(require("tomltasks.types.debug").adapters)
    if not ok then
        health.warn(("`debug_adapters` cannot be resolved: %s"):format(tostring(usable)), {
            "Run :checkhealth ezdap",
        })
        return
    end
    health.ok(("`debug_adapters`: %s"):format(table.concat(usable, ", ")))

    for _, name in ipairs(wanted) do
        if not vim.tbl_contains(usable, name) then
            health.error(("`%s` is not a registered ezdap adapter"):format(name), {
                "See the names available with :lua =require('ezdap').available_adapters()",
            })
        end
    end
end

---List the registered task types, and for `debug` the adapters behind it.
local function _check_types()
    health.start("tomltasks: task types")

    local names = require("tomltasks.types").get_names()
    table.sort(names)
    health.ok(("%d registered: %s"):format(#names, table.concat(names, ", ")))

    if vim.tbl_contains(names, "debug") then
        _check_debug_adapters()
    end
end

function M.check()
    _check_requirements()
    _check_setup()
    _check_config()
    _check_project()
    _check_types()
end

return M
