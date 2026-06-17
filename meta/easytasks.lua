---@meta easytasks

--- These classes/aliases intentionally mirror lua/easytasks/annotations.lua
--- (see CLAUDE.md). `Lua.workspace.ignoreDir` excludes meta/ from this repo's
--- own workspace scan, but opening a meta/ file directly still loads it
--- alongside annotations.lua, so lua_ls flags the mirrored fields/aliases as
--- duplicates. Suppressed since the duplication itself is by design.
---@diagnostic disable: duplicate-doc-field, duplicate-doc-alias

--- Public type definitions for authoring `tasks.lua` and configuring
--- easytasks.nvim, packaged as a curated lua-language-server library.
---
--- Point lua_ls at *this directory* — never at the plugin's `lua/` — so the
--- typed task constructors and `require("easytasks")` get completion and
--- diagnostics WITHOUT the plugin's internal `---@class` definitions leaking
--- into your `tasks.lua` completion. In a project's `.luarc.json`:
---
---     "workspace.library": [ "/path/to/easytasks.nvim/meta" ]
---
--- Every task field below may also be a function
--- `fun(ctx: easytasks.ValueCtx): any` evaluated lazily at run time (this
--- replaces the old `${…}` macros); see the `easytasks.expand` helpers.

-- ─── Task specs ────────────────────────────────────────────────────────────────

---@alias easytasks.SaveBuffers
---  | boolean
---  | { include?: string[], exclude?: string[], include_hidden?: boolean }

--- Context passed to any function-valued task field when it is resolved.
---@class easytasks.ValueCtx
---@field task  table                 the task being resolved (pre-resolution)
---@field tasks table<string, table>  all tasks declared in the file, by name

--- Fields shared by every task type.
---@class easytasks.BaseSpec
---@field name?          string  Defaults to the map key used in `tasks.lua`
---@field type?          string  Set by the constructor; not normally written by hand
---@field if_running?    "wait"|"restart"|"refuse"|"parallel"  What to do when an instance is already running
---@field depends_on?    string[]  Tasks that must complete successfully first
---@field depends_order? "sequence"|"parallel"  How `depends_on` tasks are run
---@field save_buffers?  easytasks.SaveBuffers  Save modified project buffers before running

--- A `run` (process) task.
---@class easytasks.RunSpec : easytasks.BaseSpec
---@field command          string|string[]|fun(ctx: easytasks.ValueCtx): string|string[]  Command to execute
---@field shell?           boolean  Pass the command string to the shell instead of executing it directly
---@field cwd?             string|fun(ctx: easytasks.ValueCtx): string  Working directory
---@field env?             table<string, string>  Environment variables
---@field quickfix_matcher? string  Name of a quickfix matcher used to parse output

--- A `composite` task: behaviour is entirely its `depends_on` resolution.
---@class easytasks.CompositeSpec : easytasks.BaseSpec

--- The value a `tasks.lua` file returns: a map of task name → task spec.
--- Annotate the returned table with `---@type easytasks.Tasks` for completion.
---@alias easytasks.Tasks table<string, easytasks.BaseSpec>

--- A `debug` task, run through a DAP backend (`config.debug_backend`).
---@class easytasks.DebugSpec : easytasks.BaseSpec
---@field adapter          string  Name of the DAP adapter (e.g. codelldb, delve, debugpy)
---@field request?         "launch"|"attach"
---@field host?            string  DAP server host (attach)
---@field port?            integer  DAP server port (attach)
---@field command?         string|string[]  Program to debug
---@field cwd?             string  Working directory for the debugged program
---@field env?             table<string, string>
---@field clear_env?       boolean
---@field run_in_terminal? boolean
---@field stop_on_entry?   boolean
---@field request_args?    table  Arguments sent verbatim in the DAP request
---@field raw_messages?    boolean

-- ─── expand: dynamic value helpers ──────────────────────────────────────────────

--- Convenience builders for dynamic task field values (`require("easytasks").expand`).
--- Each returns a `fun(ctx): any, string?` to use directly as a field value.
---@class easytasks.expand
local expand = {}

--- Absolute path of the current buffer (`%:p`).
---@param filetype string?  if given, error unless the current file has this filetype
---@return fun(): string?, string?
function expand.file(filetype) end

--- Tail of the current buffer's name (`%:t`).
---@param filetype string?
---@return fun(): string?, string?
function expand.filename(filetype) end

--- Current buffer path without extension (`%:p:r`).
---@param filetype string?
---@return fun(): string?, string?
function expand.fileroot(filetype) end

--- Directory of the current buffer (`%:p:h`).
---@return fun(): string?, string?
function expand.filedir() end

--- Extension of the current buffer (`%:e`), or nil if none.
---@return fun(): string?, string?
function expand.fileext() end

--- The task's own `cwd` if it set one, else the resolved current working dir.
---@return fun(ctx: easytasks.ValueCtx): string
function expand.cwd() end

--- The project root (the cwd, asserting the tasks file lives there).
---@return fun(): string?, string?
function expand.projectdir() end

--- Value of environment variable `varname`, or nil if unset.
---@param varname string
---@return fun(): string?, string?
function expand.env(varname) end

--- Prompt the user for a value via `vim.ui.input`.
---@param prompt_text string
---@param default string?
---@param completion string?  e.g. "file" or "dir" (resolves relative paths)
---@return fun(): string?, string?
function expand.prompt(prompt_text, default, completion) end

--- Let the user pick a running process; resolves to its PID.
---@return fun(): string?, string?
function expand.select_pid() end

-- ─── Extension-point aliases ─────────────────────────────────────────────────────
-- Loosely typed on purpose: the precise internal classes are intentionally not
-- exposed through this public library.

---@alias easytasks.TypeLoader string|table|fun(): table
---@alias easytasks.QfMatcher fun(line: string,context:table): table?
---@alias easytasks.debug.BackendDef table|fun(): table?

---@class easytasks.Config
---@field enabled?        boolean
---@field command?        string   User command name (default "Tasks")
---@field tasks_filename? string   Per-project Lua task file (default "tasks.lua")
---@field storage_dir?    string
---@field debug_backend?  string   Name of the debug backend (default "easydap")

-- ─── Module surface ──────────────────────────────────────────────────────────────

---@class easytasks
---@field types  easytasks.types   Task constructors (also `require("easytasks.types")`)
---@field expand easytasks.expand  Dynamic value helpers for task field values
local M = {}

---@param opts easytasks.Config?
function M.setup(opts) end

function M.enable() end

function M.disable() end

---@return boolean
function M.in_project() end

--- Register a task type (module path, factory, or resolved definition).
---@param name   string
---@param loader easytasks.TypeLoader
function M.register_task_type(name, loader) end

--- Register a custom quickfix matcher for use in `run` tasks.
---@param name string
---@param fn   easytasks.QfMatcher
function M.register_qfmatcher(name, fn) end

--- Register a debug backend definition (selected via `config.debug_backend`).
---@param name string
---@param def  easytasks.debug.BackendDef
function M.register_debug_backend(name, def) end

-- ─── tasks.lua global ────────────────────────────────────────────────────────
-- Injected into a `tasks.lua` file's environment when it is run via `:Tasks`
-- (see runner/exec.lua), so authoring needs no `require("easytasks")`:
--
--     return {
--       build = easytasks.types.run { command = "make" },
--     }
--
-- Only available inside `tasks.lua` itself, not in modules it `require`s.
-- Deliberately just the authoring surface, not the full `easytasks` module:
-- lifecycle/extension methods (`setup`, `enable`, `register_task_type`, …)
-- belong in your init.lua via `require("easytasks")`, not in a task file.
---@class easytasks.TasksFileGlobal
---@field types  easytasks.types   Task constructors (`easytasks.types.run { … }`)
---@field expand easytasks.expand  Dynamic value helpers for task field values
---@type easytasks.TasksFileGlobal
easytasks = nil

return M
