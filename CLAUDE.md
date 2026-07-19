# CLAUDE.md

## Overview

`tomltasks.nvim` is a Neovim task runner. Tasks are declared in a per-project
TOML file (`tasks.toml` by default) and run from within Neovim via the `:Tasks`
command. The plugin provides schema-backed LSP completion/diagnostics for the
tasks file (via a vendored TOML engine + language server under
[toml/](lua/tomltasks/toml/) and [lsp/](lua/tomltasks/lsp/)), several built-in
task types, task dependencies, value expressions, and a status-panel UI.

The public API lives in [lua/tomltasks/init.lua](lua/tomltasks/init.lua):
`setup`, `enable`/`disable`, and the extension points `register_task_type`,
`register_qfmatcher`, and `register_expression`.

## Architecture

- [config.lua](lua/tomltasks/config.lua) — runtime config table (command name,
  tasks filename, storage dir). Mutated in place by `setup`.
- [project.lua](lua/tomltasks/project.lua) — locates the project root by finding
  the tasks file in cwd.
- [commands.lua](lua/tomltasks/commands.lua) — registers the user command.
- [runner/](lua/tomltasks/runner/) — resolves and executes tasks
  (`resolver` builds the dependency order, `exec` runs them).
- [types/](lua/tomltasks/types/) — task-type registry and built-in types
  (`process`/`shell`, `debug`, `composite`). `process` and `shell` are
  implemented independently; they only share the quickfix-matcher library in
  [types/qfmatchers.lua](lua/tomltasks/types/qfmatchers.lua) (built-in matchers
  plus the user-registered matcher registry). Each type contributes a JSON Schema
  fragment; [types/schema.lua](lua/tomltasks/types/schema.lua) merges them with
  the shared `base_properties` (name, `if_running`, `depends_on`,
  `depends_order`) into the full schema used by the LSP.
- [expressions.lua](lua/tomltasks/expressions.lua) — `{{ name }}` / `{{ name args }}`
  substitutions available in task config values.
- [toml/](lua/tomltasks/toml/) — vendored TOML engine (parser, decoder,
  encoder, schema validator/navigator). [toml/init.lua](lua/tomltasks/toml/init.lua)
  exposes the public `parse`/`encode`/`find_path` API used by the runner and
  commands.
- [lsp/](lua/tomltasks/lsp/) — vendored in-process language server for the tasks
  file (completion, diagnostics, hover, code actions, formatting), driven by the
  resolved task schema. Attached by name to the tasks buffer only.
- [ui/](lua/tomltasks/ui/) — status panel and tree view.
- [util/](lua/tomltasks/util/) — shared helpers (async, signals, tree, terminal,
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

Function local variable names should NOT begin with underscore

</content>
</invoke>
