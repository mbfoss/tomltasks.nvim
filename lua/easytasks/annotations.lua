---@meta
--- Type annotations for `tasks.lua` authoring. This file declares no runtime
--- code; it exists so lua-language-server can offer completion and diagnostics
--- for the typed task constructors exposed by `require("easytasks")`.
---
--- Every field below may also be a function `fun(ctx: easytasks.ValueCtx): any`,
--- evaluated lazily at run time (this replaces the old `${…}` macros).

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

-- ─── tasks.lua global ────────────────────────────────────────────────────────
-- Injected into a `tasks.lua` file's environment when it is run via `:Tasks`
-- (see runner/exec.lua `_tasks_file_global`), so authoring needs no
-- `require("easytasks")`. Mirrored in meta/easytasks.lua for consumers.
--
-- Deliberately just the authoring surface, not the full `easytasks` module:
-- lifecycle/extension methods (`setup`, `enable`, `register_task_type`, …)
-- belong in the user's init.lua via `require("easytasks")`, not in a task file.
---@class easytasks.TasksFileGlobal
---@field types  easytasks.Types   Task constructors (`easytasks.types.run { … }`)
---@field values easytasks.values  Dynamic value helpers for task field values
---@type easytasks.TasksFileGlobal
easytasks = nil
