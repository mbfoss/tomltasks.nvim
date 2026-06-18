local M      = {}

local config = require("easytasks.config")

--- Register a task type. Can be called at any time before setup() to have the
--- type included in the schema, or after setup() for runtime-only use.
--- `loader` may be a module path string, a zero-arg factory function, or a
--- fully-resolved TaskTypeDef table.
---@param name   string
---@param loader easytasks.TypeLoader
function M.register_task_type(name, loader)
    require("easytasks.types").register(name, loader)
end

--- Register a custom quickfix matcher for use in process tasks.
---@param name string
---@param fn   easytasks.QfMatcher
function M.register_qfmatcher(name, fn)
    require("easytasks.types.process").register_qfmatcher(name, fn)
end

--- Register a debug backend definition under `name`, for use by `debug` tasks
--- (selected via `config.debug_backend`). Overrides any existing backend with
--- the same name.
---@param name string
---@param def  easytasks.debug.BackendDef
function M.register_debug_backend(name, def)
    require("easytasks.types.debug").register_backend(name, def)
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
                require("tomltools.lsp").start(ev.buf, {
                    schema = function() return require("easytasks.types").build_resolved_schema() end,
                })
            end
        end,
    })

    require("easytasks.commands").register(config.command)
end

function M.disable()
    if not _enabled then return end
    _enabled = false
    vim.api.nvim_del_augroup_by_name("easytasks_tasks_lsp")
    local tomltools_lsp = require("tomltools.lsp")
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
    if config.enabled then
        M.enable()
    else
        M.disable()
    end
end

---@return boolean
function M.in_project()
    return require("easytasks.project").find_root() ~= nil
end

return M
