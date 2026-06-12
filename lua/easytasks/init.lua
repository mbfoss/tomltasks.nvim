local M            = {}

local cfg            = require("easytasks.config")
local project        = require("easytasks.project")
local _tomltools_lsp = require("tomltools.lsp")
local task_types     = require("easytasks.types")

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
    require("easytasks.macros")[name] = fn
end

---@type easytasks.Config
M.config = cfg.current

local _enabled = false

function M.enable()
    if _enabled then return end
    _enabled = true

    local augroup = vim.api.nvim_create_augroup("easytasks_tasks_lsp", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
        pattern  = { "toml" },
        group    = augroup,
        callback = function(ev)
            if vim.fn.fnamemodify(ev.file, ":t") == cfg.current.tasks_filename then
                _tomltools_lsp.start(ev.buf, { schema = function() return task_types.build_resolved_schema() end })
            end
        end,
    })

    require("easytasks.commands").register(cfg.current.command)
end

function M.disable()
    if not _enabled then return end
    _enabled = false
    vim.api.nvim_del_augroup_by_name("easytasks_tasks_lsp")
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].filetype == "toml" then
            _tomltools_lsp.stop(buf)
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
