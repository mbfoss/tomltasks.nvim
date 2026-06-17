# CLAUDE.md

## Overview

`easytasks.nvim` is a Neovim task runner. Tasks are declared in a per-project
Lua file (`tasks.lua` by default) and run from within Neovim via the `:Tasks`
command. The tasks file returns a map of name → task; each task is built with a
typed constructor from `easytasks.types`
(`easytasks.types.run/debug/composite{ … }`). The runner injects `easytasks`
as a global into the tasks file's environment (see
[runner/exec.lua](lua/easytasks/runner/exec.lua) `_load_tasks`), so authoring
needs no `require`; elsewhere `require("easytasks")` works the same way. Any
task field value may be a **function**, evaluated lazily at run time (this
replaces the old `${…}` macro system). The plugin ships several built-in task
types, task dependencies, value helpers, and a status-panel UI.

The public API splits across two modules:
- [lua/easytasks/init.lua](lua/easytasks/init.lua) — `setup`, `enable`/`disable`,
  `in_project`, the `values` value helpers, the extension points
  `register_task_type`/`register_qfmatcher`/`register_debug_backend`, plus
  `types`/`values` re-exports.
- [lua/easytasks/types/init.lua](lua/easytasks/types/init.lua) — the task-type
  registry *and* the authoring constructors (`run`, `composite`, `debug`, generic
  `task`, plus a metatable that yields a constructor for any registered custom
  type).

lua-language-server completion for `tasks.lua` comes from a curated library in
[meta/](meta/) — `meta/easytasks.lua` (`---@meta easytasks`) and
`meta/easytasks-types.lua` (`---@meta easytasks.types`). Consumers point
`Lua.workspace.library` at `meta/` (never at `lua/`, which would leak internal
`---@class` definitions); `:Tasks bootstrap` wires this up automatically.
[lua/easytasks/annotations.lua](lua/easytasks/annotations.lua) mirrors the spec
classes for in-repo development only and is excluded from consumers.

## Architecture

- [config.lua](lua/easytasks/config.lua) — runtime config table (command name,
  tasks filename, storage dir, debug backend). Mutated in place by `setup`.
- [annotations.lua](lua/easytasks/annotations.lua) — `---@meta` spec classes
  (`RunSpec`, `DebugSpec`, `CompositeSpec`, …) used for in-repo development.
  Mirrored by [meta/](meta/), which is the curated library shipped to consumers.
  No runtime code.
- [bootstrap.lua](lua/easytasks/bootstrap.lua) — `:Tasks bootstrap`: scaffolds a
  starter `tasks.lua` and creates/updates `.luarc.json` so lua_ls loads `meta/`.
- [project.lua](lua/easytasks/project.lua) — locates the project root by finding
  the tasks file in cwd.
- [commands.lua](lua/easytasks/commands.lua) — registers the user command.
- [runner/](lua/easytasks/runner/) — loads, resolves, and executes tasks. `exec`
  loads `tasks.lua` (via `loadfile`, fresh each run), drives dependency order and
  state; `resolver.resolve_values` replaces any function-valued field with its
  result (functions run in a coroutine, so they may yield, e.g. to prompt).
- [types/](lua/easytasks/types/) — task-type registry, the authoring
  constructors, and built-in types (`run`/process, `debug`, `composite`). Each
  type may contribute a `validate` hook (checked at run time) and `templates`
  (`{ label, spec }`, rendered to Lua snippets by `:Tasks template`).
- [values.lua](lua/easytasks/values.lua) — value helpers (`file()`, `cwd()`,
  `env()`, `prompt()`, `select_pid()`, …); each returns a `fun(ctx)` for use as a
  task field value. Exposed as `require("easytasks").values`.
- [ui/](lua/easytasks/ui/) — status panel and tree view.
- [util/](lua/easytasks/util/) — shared helpers (async, signals, tree, terminal,
  etc.).

The `debug` task type delegates to a pluggable backend
([types/debug/backends/](lua/easytasks/types/debug/backends/)): `nvim-dap` or
`easydap`.

## Testing

Tests use plenary and live in [tests/](tests/). Run them with:

```sh
make test
```

## Styling

Add Lua annotations (`---@param`, `---@return`, `---@class`, etc.) whenever possible.

Class-based modules are named in PascalCase; functional modules are named in snake_case.

Module-scope `local` variables are prefixed with `_`, except:
- a local name bound directly from `require()`
- the conventional `M` module table
- class type names like `MyType`

Inside a class, private members are prefixed with `_`.
</content>
</invoke>
