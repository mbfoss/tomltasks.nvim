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

--- Register a custom expression for use in task config values.
--- Expression syntax in TOML: `{{ name }}` or `{{ name arg1 arg2 }}`.
--- Built-in expressions cannot be overridden (raises an error). Pass
--- `{ raw = true }` to receive the raw body instead of tokenized arguments, and
--- `{ desc = … }` to have the name shown (with that text) in LSP completion.
---@param name string
---@param fn   easytasks.ExpressionFn
---@param opts? { raw?: boolean, desc?: string }
function M.register_expression(name, fn, opts)
    require("easytasks.expressions").register(name, fn, opts)
end

local _enabled = false

--- True if `buf`'s file is the project tasks file, matched by filename. The
--- tasks file keeps the plain `toml` filetype; the LSP attaches only to
--- buffers matching this check, never to ordinary `.toml` buffers.
---@param buf integer
---@return boolean
local function _is_tasks_buf(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    return name ~= "" and vim.fs.basename(name) == config.tasks_filename
end

---@param buf integer
local function _attach_lsp(buf)
    require("easytasks.lsp").start(buf, {
        schema      = function() return require("easytasks.types").build_resolved_schema() end,
        expressions = function() return require("easytasks.expressions").list() end,
    })
end

function M.enable()
    if _enabled then return end
    _enabled = true

    -- Make sure the configured tasks filename is recognized as `toml` even if
    -- it doesn't match the `*.toml` glob (e.g. a custom name with no extension).
    vim.filetype.add({
        filename = {
            [config.tasks_filename] = "toml",
        },
    })

    -- Start the tasks-file LSP only for buffers that are the project tasks
    -- file, never for ordinary toml buffers.
    local augroup = vim.api.nvim_create_augroup("easytasks_tasks_lsp", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
        pattern  = "toml",
        group    = augroup,
        callback = function(ev)
            if _is_tasks_buf(ev.buf) then _attach_lsp(ev.buf) end
        end,
    })

    -- Filetype detection only fires on future loads, so handle any tasks
    -- buffer that is already open: set its filetype if needed (which triggers
    -- the autocmd above), or attach directly if it's already `toml`.
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and _is_tasks_buf(buf) then
            if vim.bo[buf].filetype ~= "toml" then
                vim.bo[buf].filetype = "toml"
            else
                _attach_lsp(buf)
            end
        end
    end

    require("easytasks.commands").register(config.command)
end

function M.disable()
    if not _enabled then return end
    _enabled = false
    vim.api.nvim_del_augroup_by_name("easytasks_tasks_lsp")
    local lsp = require("easytasks.lsp")
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if _is_tasks_buf(buf) then
            lsp.stop(buf)
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
