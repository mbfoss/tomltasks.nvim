# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
make test                                        # run all tests (requires plenary.nvim)
nvim -l tests/run_decoder.lua < file.toml        # run TOML decoder against toml-test suite input
nvim -l tests/run_encoder.lua < file.toml        # run TOML encoder against toml-test suite input
```

Tests live in `tests/` and are discovered automatically by Plenary/Busted. `tests/init.lua` clones plenary to `/tmp/plenary.nvim` if not present (override with `NVIM_PLENARY_DIR`).

## Architecture

**easytasks.nvim** is a Neovim plugin with two independent subsystems: an **LSP server** (headless subprocess) for TOML task-config files, and a **task runner** that executes those tasks. `lua/easytasks/init.lua` is the public API — `setup()` wires both together and registers the `:EasyTasksRun` command.

### Schema and type registry (`types/`)

`types/init.lua` holds a registry of task types (`process`, `composite`, `build`, `debug`). Each type module exports `{ run, schema }`. `types/schema.lua` builds the full JSON Schema from the registry: it uses `if/then` conditionals so each `type` value produces a different set of required/optional fields without duplication. `validator_util.lua` and `schema_util.lua` handle schema merging and property enumeration.

Schema fields that require dynamic completion values (e.g. a list of registered adapter names) use `enum = function() ... end` directly in the schema table. `lsp/init.lua` evaluates these functions and replaces them with concrete arrays before encoding the schema for the server. Functions that need no document data work this way; completions requiring live document content are not supported (the `depends_on` task-names completion was removed for this reason).

New task types are registered with `easytasks.register_task_type(name, type_def)` before or after `setup()`.

### Runner subsystem (`runner/`)

`runner/exec.lua` is the execution engine. `exec.run(task_name, toml_path)`:
1. Parses/decodes the TOML file to get task configs indexed by name
2. Detects dependency cycles (`find_cycle`)
3. Launches the task (and its dependencies, serially or in parallel via `depends_order`) as a coroutine via `runner/async.lua`

`runner/async.lua` implements a minimal coroutine scheduler on top of `vim.fn.jobstart`. `async.go` drives a coroutine; `async.spawn` starts a process in a terminal buffer and `coroutine.yield()`s until it exits (resumed by the `on_exit` callback). `async.wait_all` fans out parallel dependencies and yields until all complete.

`runner/term.lua` manages named terminal buffers (one per task name); `term.open` creates or reuses a buffer, `term.show` opens it in a split.

### Newline token range quirk

`emit_nl` in `parser.lua` records the Newline token with the **pre-skip position** as both start and end (`[sr, sc, sr, sc]`), making it zero-width. `token_at` still matches it because `contains` uses `<` (strict) for the lower bound check.

### Styling

Add Lua annotations (`---@param`, `---@return`, `---@class`, etc.) whenever possible.

Class-based modules are named in PascalCase and functional modules are named in snake_case.

### Naming conventions

module-scope `local` variables should be prefixed with `_` with exception: 
- a local module name from `require()`
- the typical `M` module table.
-  class types like `MyType`

Inside a class, private members are prefixed with `_`