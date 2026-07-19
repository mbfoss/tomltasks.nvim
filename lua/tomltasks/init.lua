local M      = {}

local config = require("tomltasks.config")

--- Register a task type. Can be called at any time before setup() to have the
--- type included in the schema, or after setup() for runtime-only use.
--- `loader` may be a module path string, a zero-arg factory function, or a
--- fully-resolved TaskTypeDef table.
---@param name   string
---@param loader tomltasks.TypeLoader
function M.register_task_type(name, loader)
    require("tomltasks.types").register(name, loader)
end

--- Register a custom quickfix matcher for use in process tasks.
---@param name string
---@param fn   tomltasks.QfMatcher
function M.register_qfmatcher(name, fn)
    require("tomltasks.types.process").register_qfmatcher(name, fn)
end

--- Register a custom expression for use in task config values.
--- Expression syntax in TOML: `{{ name }}` or `{{ name(arg1, arg2) }}`.
--- Built-in expressions cannot be overridden (raises an error). Pass
--- `{ desc = … }` to have the name shown (with that text) in LSP completion.
---@param name string
---@param fn   tomltasks.ExpressionFn
---@param opts? { desc?: string }
function M.register_expression(name, fn, opts)
    require("tomltasks.expressions").register(name, fn, opts)
end

--- Run a task whose definition is supplied inline, not from a TOML file.
---@param task_name string
---@param task_def  tomltasks.TaskBase  task data (same shape as a decoded TOML task entry)
function M.run_ephemeral(task_name, task_def)
    require("tomltasks.runner.exec").run_ephemeral(task_name, task_def)
end

local _enabled = false

-- The tasks file gets its own `tomltasks` filetype (not `toml`): it carries
-- vendored TOML + expression-hole highlighting via syntax/tomltasks.vim and no
-- treesitter parser, and the LSP attaches by this filetype.
local FILETYPE = "tomltasks"

--- True if `buf`'s file is the project tasks file, matched by filename. Used to
--- guard LSP attachment so it fires only for the real tasks file, never for a
--- scratch/preview buffer that merely borrows the `tomltasks` filetype.
---@param buf integer
---@return boolean
local function _is_tasks_buf(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    return name ~= "" and vim.fs.basename(name) == config.tasks_filename
end

---@param buf integer
local function _attach_lsp(buf)
    require("tomltasks.lsp").start(buf, {
        schema         = function() return require("tomltasks.types").build_resolved_schema() end,
        expressions    = function() return require("tomltasks.expressions").list() end,
        debug_commands = config.lsp_debug_commands,
    })
end

function M.enable()
    if _enabled then return end
    _enabled = true

    -- Register the tasks file as its own `tomltasks` filetype. This applies
    -- regardless of extension (e.g. a custom name with no `.toml`) and, unlike
    -- reusing `toml`, keeps ordinary `.toml` files untouched and pulls in no
    -- treesitter parser (there is none for this filetype).
    vim.filetype.add({
        filename = {
            [config.tasks_filename] = FILETYPE,
        },
    })

    -- Start the tasks-file LSP for buffers that get the `tomltasks` filetype.
    -- The filename guard keeps it off scratch/preview buffers that borrow the
    -- filetype only for its highlighting.
    local augroup = vim.api.nvim_create_augroup("tomltasks_tasks_lsp", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
        pattern  = FILETYPE,
        group    = augroup,
        callback = function(ev)
            if _is_tasks_buf(ev.buf) then _attach_lsp(ev.buf) end
        end,
    })

    -- Filetype detection only fires on future loads, so handle any tasks
    -- buffer that is already open: set its filetype if needed (which triggers
    -- the autocmd above), or attach directly if it already has it.
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and _is_tasks_buf(buf) then
            if vim.bo[buf].filetype ~= FILETYPE then
                vim.bo[buf].filetype = FILETYPE
            else
                _attach_lsp(buf)
            end
        end
    end

    require("tomltasks.commands").register(config.command)
end

function M.disable()
    if not _enabled then return end
    _enabled = false
    vim.api.nvim_del_augroup_by_name("tomltasks_tasks_lsp")
    local lsp = require("tomltasks.lsp")
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if _is_tasks_buf(buf) then
            lsp.stop(buf)
        end
    end
end

---@param opts tomltasks.Config?
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
    return require("tomltasks.project").find_root() ~= nil
end

return M
