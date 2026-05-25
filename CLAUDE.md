# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
make test                                        # run all tests (requires plenary.nvim)
nvim -l tests/decode_runner.lua < file.toml      # run TOML decoder against toml-test suite input
```

Tests live in `tests/` and are discovered automatically by Plenary/Busted. `tests/init.lua` clones plenary to `/tmp/plenary.nvim` if not present (override with `NVIM_PLENARY_DIR`).

## Architecture

**easytasks.nvim** is a Neovim plugin providing an in-process LSP server for TOML task-config files. "In-process" means the server runs in Neovim's Lua VM as a loopback dispatcher (not a subprocess) — `tasks_lsp.lua` passes a table implementing `{ request, notify, is_closing, terminate }` to `vim.lsp.start()`.

### TOML pipeline (the foundation everything else builds on)

```
buffer text
  → parser.lua        (hand-written recursive descent) → Cst (Concrete Syntax Tree)
  → decoder.lua       (walks CST, evaluates TOML semantics) → data + DecodeTree
  → validator.lua     (JSON Schema subset validator)    → errors with source ranges
```

**Cst** (`toml/Cst.lua`) preserves every source character — whitespace, comments, punctuation. Leaf nodes carry `{ kind, text, value, range }` where `range = { r1, c1, r2, c2 }` (0-indexed). Composite nodes (KeyValuePair, InlineTable, TableSection, etc.) contain children via `util/Tree.lua`. The `tag` field on each CST node stores the corresponding DecodeTree ID (stamped by the decoder).

**DecodeTree** (`toml/DecodeTree.lua`) is a parallel tree mapping semantic data nodes back to source ranges. `dt:key_parts_of(id)` returns the path segments from root to that node (e.g. `{"tasks", "1"}`), which `schema_nav.schema_at` uses to navigate the schema.

**schema_nav.lua** provides two key helpers used throughout LSP handlers:
- `schema_nav.flatten(s, d)` — resolves `allOf`/`oneOf`/`if-then-else` against live data
- `schema_nav.schema_at(root_schema, root_data, dt, dt_id)` — navigates schema+data in parallel by walking `key_parts_of(dt_id)`, handling arrays (numeric segments → `items`) and objects (→ `properties`)

### LSP layer

`tasks_lsp.lua` owns per-buffer state (`attached[bufnr] = { client_id, context, autocmd_ids }`). On every edit it re-parses and re-decodes synchronously, then debounces diagnostics by 1 s. Each LSP feature handler (`lsp/*.lua`) receives `(context, params, callback)` where `context` is a `BufferContext` holding `{ cst, data, decode_tree, schema, parse_errors, decode_errors }`.

### Completion handler logic (`lsp/completion.lua`)

`token_at(row, col)` descends the CST to find the deepest leaf containing the cursor. The handler then resolves context with a priority chain:

1. **TableHeader / AotHeader ancestor** → suggest table paths from schema
2. **KeyValuePair ancestor** (stopping at InlineTable boundaries — searching for `K.KeyValuePair | K.InlineTable` and checking which was found first):
   - Cursor before `=` → key completions from parent scope's schema
   - Cursor after `=` → value completions (enums, booleans) from the KVP's schema
3. **InlineTable ancestor** (trivia between KVPs, or after a comma) → key completions from the inline table's schema
4. **TableSection / AotSection ancestor** → key completions from section's schema
5. **Document** → top-level key completions

### Schema

`schema.lua` uses JSON Schema `if/then` conditionals so each task `type` (`process`, `build`, `debug`, `composite`) gets different required/optional fields without duplication. `validator_util.lua` and `schema_util.lua` handle merging and property enumeration.

### Newline token range quirk

`emit_nl` in `parser.lua` records the Newline token with the **pre-skip position** as both start and end (`[sr, sc, sr, sc]`), making it zero-width. `token_at` still matches it because `contains` uses `<` (strict) for the lower bound check.

### Styling 
lua annotation should be added when possible
