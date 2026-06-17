# CLAUDE.md

## Overview

`easytasks.nvim` is a Neovim task runner. Tasks are declared in a per-project
Lua file (`tasks.lua` by default) and run from within Neovim via the `:Tasks`
command. The tasks file returns a map of name → task; each task is built with a
typed constructor (`require("easytasks").run/debug/composite{ … }`) so
lua-language-server provides completion/diagnostics from the `---@class` specs in
[annotations.lua](lua/easytasks/annotations.lua). Any task field value may be a
**function**, evaluated lazily at run time (this replaces the old `${…}` macro
system). The plugin ships several built-in task types, task dependencies, value
helpers, and a status-panel UI.

The public API lives in [lua/easytasks/init.lua](lua/easytasks/init.lua):
`setup`, `enable`/`disable`, the task constructors (`run`, `composite`, `debug`,
generic `task`), the `expand` value helpers, and the extension points
`register_task_type`, `register_qfmatcher`, and `register_debug_backend`.

## Architecture

- [config.lua](lua/easytasks/config.lua) — runtime config table (command name,
  tasks filename, storage dir, debug backend). Mutated in place by `setup`.
- [annotations.lua](lua/easytasks/annotations.lua) — `---@meta` spec classes
  (`RunSpec`, `DebugSpec`, `CompositeSpec`, …) that drive lua-ls completion when
  authoring `tasks.lua`. No runtime code.
- [project.lua](lua/easytasks/project.lua) — locates the project root by finding
  the tasks file in cwd.
- [commands.lua](lua/easytasks/commands.lua) — registers the user command.
- [runner/](lua/easytasks/runner/) — loads, resolves, and executes tasks. `exec`
  loads `tasks.lua` (via `loadfile`, fresh each run), drives dependency order and
  state; `resolver.resolve_values` replaces any function-valued field with its
  result (functions run in a coroutine, so they may yield, e.g. to prompt).
- [types/](lua/easytasks/types/) — task-type registry and built-in types
  (`run`/process, `debug`, `composite`). Each type may contribute a `validate`
  hook (checked at run time) and `templates` (`{ label, spec }`, rendered to Lua
  snippets by `:Tasks template`).
- [expand.lua](lua/easytasks/expand.lua) — value helpers (`file()`, `cwd()`,
  `env()`, `prompt()`, `select_pid()`, …); each returns a `fun(ctx)` for use as a
  task field value. Exposed as `require("easytasks").expand`.
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
