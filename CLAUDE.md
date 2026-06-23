# CLAUDE.md

## Overview

`easytasks.nvim` is a Neovim task runner. Tasks are declared in a per-project
TOML file (`tasks.toml` by default) and run from within Neovim via the `:Tasks`
command. The plugin provides schema-backed LSP completion/diagnostics for the
tasks file (via a vendored TOML engine + language server under
[toml/](lua/easytasks/toml/) and [lsp/](lua/easytasks/lsp/)), several built-in
task types, task dependencies, value macros, and a status-panel UI.

The public API lives in [lua/easytasks/init.lua](lua/easytasks/init.lua):
`setup`, `enable`/`disable`, and the extension points `register_task_type`,
`register_qfmatcher`, and `register_macro`.

## Architecture

- [config.lua](lua/easytasks/config.lua) — runtime config table (command name,
  tasks filename, storage dir). Mutated in place by `setup`.
- [project.lua](lua/easytasks/project.lua) — locates the project root by finding
  the tasks file in cwd.
- [commands.lua](lua/easytasks/commands.lua) — registers the user command.
- [runner/](lua/easytasks/runner/) — resolves and executes tasks
  (`resolver` builds the dependency order, `exec` runs them).
- [types/](lua/easytasks/types/) — task-type registry and built-in types
  (`run`/process, `debug`, `composite`). Each type contributes a JSON Schema
  fragment; [types/schema.lua](lua/easytasks/types/schema.lua) merges them with
  the shared `base_properties` (name, `if_running`, `depends_on`,
  `depends_order`) into the full schema used by the LSP.
- [macros.lua](lua/easytasks/macros.lua) — `${name}` / `${name:args}`
  substitutions available in task config values.
- [toml/](lua/easytasks/toml/) — vendored TOML engine (parser, decoder,
  encoder, schema validator/navigator). [toml/init.lua](lua/easytasks/toml/init.lua)
  exposes the public `parse`/`encode`/`find_path` API used by the runner and
  commands.
- [lsp/](lua/easytasks/lsp/) — vendored in-process language server for the tasks
  file (completion, diagnostics, hover, code actions, formatting), driven by the
  resolved task schema. Attached by name to the tasks buffer only.
- [ui/](lua/easytasks/ui/) — status panel and tree view.
- [util/](lua/easytasks/util/) — shared helpers (async, signals, tree, terminal,
  etc.).


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
