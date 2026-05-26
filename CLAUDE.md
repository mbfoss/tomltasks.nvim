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

**easytasks.nvim** is a Neovim plugin with two independent subsystems: an **in-process LSP server** for TOML task-config files, and a **task runner** that executes those tasks. `lua/easytasks/init.lua` is the public API — `setup()` wires both together and registers the `:EasyTasksRun` command.

### TOML pipeline (the foundation everything else builds on)

```
buffer text
  → toml/parser.lua      (hand-written recursive descent) → Cst (Concrete Syntax Tree)
  → toml/decoder.lua     (walks CST, evaluates TOML semantics) → data + DecodeTree
  → toml/validator.lua   (JSON Schema subset validator)    → errors with source ranges
  → toml/formatter.lua   (walks CST, produces formatted text)
  → toml/encoder.lua     (Lua table → TOML text, no CST)
```

**Cst** (`toml/Cst.lua`) preserves every source character — whitespace, comments, punctuation. Leaf nodes carry `{ kind, text, value, range }` where `range = { r1, c1, r2, c2 }` (0-indexed). Composite nodes (KeyValuePair, InlineTable, TableSection, etc.) contain children via `util/Tree.lua`. The `tag` field on each CST node stores the corresponding DecodeTree ID (stamped by the decoder).

**DecodeTree** (`toml/DecodeTree.lua`) is a parallel tree mapping semantic data nodes back to source ranges. `dt:key_parts_of(id)` returns the path segments from root to that node (e.g. `{"tasks", "1"}`), which `schema_nav.schema_at` uses to navigate the schema.

**schema_nav.lua** provides two key helpers used throughout LSP handlers:
- `schema_nav.flatten(s, d)` — resolves `allOf`/`oneOf`/`if-then-else` against live data
- `schema_nav.schema_at(root_schema, root_data, dt, dt_id)` — navigates schema+data in parallel by walking `key_parts_of(dt_id)`, handling arrays (numeric segments → `items`) and objects (→ `properties`)

### LSP layer (`lsp/`)

`lsp/init.lua` owns per-buffer state (`attached[bufnr] = { client_id, context, autocmd_ids }`). It passes a loopback dispatcher table implementing `{ request, notify, is_closing, terminate }` to `vim.lsp.start()` — no subprocess. On every edit it re-parses and re-decodes synchronously, then debounces diagnostics by `M.debounce_ms`.

Each LSP feature handler (`lsp/*.lua`) receives `(context, params, callback)` where `context` is a `BufferContext` (`lsp/BufferContext.lua`) holding `{ bufnr, cst, data, decode_tree, schema, parse_errors, decode_errors }`.

`lsp/code_action.lua` exposes debug code actions that insert CST / DecodeTree / decoded-data / error dumps as comments into the buffer — useful when debugging the parser or decoder.

### Completion handler logic (`lsp/completion.lua`)

`token_at(row, col)` descends the CST to find the deepest leaf containing the cursor. The handler then resolves context with a priority chain:

1. **TableHeader / AotHeader ancestor** → suggest table paths from schema
2. **KeyValuePair ancestor** (stopping at InlineTable boundaries — searching for `K.KeyValuePair | K.InlineTable` and checking which was found first):
   - Cursor before `=` → key completions from parent scope's schema
   - Cursor after `=` → value completions (enums, booleans) from the KVP's schema
3. **InlineTable ancestor** (trivia between KVPs, or after a comma) → key completions from the inline table's schema
4. **TableSection / AotSection ancestor** → key completions from section's schema
5. **Document** → top-level key completions

### Schema and type registry (`types/`)

`types/init.lua` holds a registry of task types (`process`, `composite`, `build`, `debug`). Each type module exports `{ run, schema }`. `types/schema.lua` builds the full JSON Schema from the registry: it uses `if/then` conditionals so each `type` value produces a different set of required/optional fields without duplication. `validator_util.lua` and `schema_util.lua` handle schema merging and property enumeration.

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

Module local variable names are to be prefixed with underscore 