local M      = {}

local config = require("tomltasks.config")

-- The defaults, captured before `setup()` can mutate the config in place — the
-- health check diffs the live config against them. Nothing else touches the
-- config this early, so this copy is pristine.
local _defaults = vim.deepcopy(config)

---@type boolean
local _setup_called = false

--- Register a task type: before setup() to have it included in the schema, or
--- after for runtime-only use. `loader` may be a module path string, a zero-arg
--- factory function, or a fully-resolved TaskTypeDef table.
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

--- Register a custom expression for use in task config values, written in TOML as
--- `{{ name }}` or `{{ name(arg1, arg2) }}`. Built-ins cannot be overridden; pass
--- `{ desc = … }` to have the name shown with that text in LSP completion.
---@param name string
---@param fn   tomltasks.ExpressionFn
---@param opts? { desc?: string }
function M.register_expression(name, fn, opts)
    require("tomltasks.expressions").register(name, fn, opts)
end

-- The tasks file gets its own `tomltasks` filetype (not `toml`): it carries
-- vendored TOML + expression-hole highlighting via syntax/tomltasks.vim and no
-- treesitter parser, and the LSP attaches by this filetype.
local FILETYPE = "tomltasks"

--- True if `buf`'s file is the project tasks file, matched by filename. The LSP
--- has its own copy of this guard in its `root_dir`; this one is for finding
--- already-open tasks buffers.
---@param buf integer
---@return boolean
local function _is_tasks_buf(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    return name ~= "" and vim.fs.basename(name) == config.tasks_filename
end

function M.enable()
    config.enabled = true

    -- Register the tasks file as its own `tomltasks` filetype, regardless of
    -- extension. Unlike reusing `toml`, this keeps ordinary `.toml` files
    -- untouched and pulls in no treesitter parser (there is none for it). The
    -- default filename is already registered at startup; this covers a
    -- `tasks_filename` changed by `setup()`.
    vim.filetype.add({
        filename = {
            [config.tasks_filename] = FILETYPE,
        },
    })

    -- The server itself is declared for this filetype at startup
    -- (plugin/tomltasks.lua); enabling it is what lets Neovim start it.
    vim.lsp.enable(require("tomltasks.lsp").SERVER_NAME)

    -- Filetype detection only fires on future loads, so re-set the filetype on
    -- any tasks buffer that is already open. The assignment fires `FileType`
    -- even when the value is unchanged, which is what makes Neovim start the
    -- server for a buffer that was already open.
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and _is_tasks_buf(buf) then
            vim.bo[buf].filetype = FILETYPE
        end
    end

    require("tomltasks.commands").register(config.command)
end

function M.disable()
    config.enabled = false
    local lsp = require("tomltasks.lsp")
    vim.lsp.enable(lsp.SERVER_NAME, false)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if _is_tasks_buf(buf) then
            lsp.stop(buf)
        end
    end
end

--- The config as it was before any `setup()`, for comparison.
---@return tomltasks.Config
function M.get_default_config()
    return vim.deepcopy(_defaults)
end

--- True once `setup()` has been called.
---@return boolean
function M.is_setup()
    return _setup_called
end

---@param opts tomltasks.Config?
function M.setup(opts)
    _setup_called = true
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
