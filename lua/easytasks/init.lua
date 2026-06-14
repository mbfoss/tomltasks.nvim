local M             = {}

local config        = require("easytasks.config")
local project       = require("easytasks.project")
local tomltools_lsp = require("tomltools.lsp")
local task_types    = require("easytasks.types")

M.runner            = require("easytasks.runner")

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
    require("easytasks.macros")[name] = fn
end

local _enabled = false

function M.enable()
    if _enabled then return end
    _enabled = true

    local augroup = vim.api.nvim_create_augroup("easytasks_tasks_lsp", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
        pattern  = { "toml" },
        group    = augroup,
        callback = function(ev)
            if vim.fn.fnamemodify(ev.file, ":t") == config.tasks_filename then
                tomltools_lsp.start(ev.buf, { schema = function() return task_types.build_resolved_schema() end })
            end
        end,
    })

    require("easytasks.commands").register(config.command)
end

function M.disable()
    if not _enabled then return end
    _enabled = false
    vim.api.nvim_del_augroup_by_name("easytasks_tasks_lsp")
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].filetype == "toml" then
            tomltools_lsp.stop(buf)
        end
    end
end

---@param opts easytasks.Config?
function M.setup(opts)
    local tmp = vim.tbl_deep_extend("force", config or {}, opts or {})
    for k, v in pairs(tmp) do
        config[k] = v
    end

    project.init()

    if config.enabled then
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

--- Replace the entire contents of a namespace in project storage.
---@param namespace string
---@param data table
---@return boolean ok
---@return string? err
function M.store_set(namespace, data)
    return project.store_set(namespace, data)
end

--- Load a namespace from project storage.
---@param  namespace string
---@return table|nil
---@return string? err
function M.store_get(namespace)
    return project.store_get(namespace)
end

--- Add or update a single key within a namespace in project storage.
---@param namespace string
---@param key       string
---@param value     any
---@return boolean ok
---@return string? err
function M.store_add_key(namespace, key, value)
    return project.store_add_key(namespace, key, value)
end

--- Remove a single key from a namespace in project storage.
---@param namespace string
---@param key       string
---@return boolean ok
---@return string? err
function M.store_remove_key(namespace, key)
    return project.store_remove_key(namespace, key)
end

return M
