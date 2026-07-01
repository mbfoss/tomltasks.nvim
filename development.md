# Development

Developer notes for `easytasks.nvim`. For an architectural overview see
[CLAUDE.md](CLAUDE.md).

## Repository layout

```
lua/easytasks/            plugin source
  init.lua                public API (setup, enable/disable, register_* hooks)
  config.lua              runtime config
  commands.lua            :Tasks user command
  project.lua             project-root discovery
  runner/                 task resolution + execution
  types/                  task-type registry + built-ins + schema merge
  expressions.lua              ${name} value substitutions
  lsp/                    in-process language server for the tasks file
  ui/                     status panel + tree view
  util/                   shared helpers
  tomltools/              VENDORED TOML engine (git subtree, see below)
tests/                    plenary specs
```

## Running tests

The suite uses [plenary](https://github.com/nvim-lua/plenary.nvim). Run it with:

```sh
make test          # alias for unit_test
make unit_test     # plenary specs under tests/
```

Run a single plenary spec while iterating:

```sh
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/completion_spec.lua"
```

## The vendored TOML engine (`tomltools`)

The TOML parser/decoder/encoder/validator/formatter and the schema
navigation used by the LSP all live in the separate
[`tomltools`](https://github.com/mbfoss/tomltools) repository. It is vendored
into this plugin as a **git subtree** (not a submodule), so a fresh clone has
everything it needs with no extra fetch step.

### Why it is namespaced under `easytasks.`

Upstream `tomltools` ships its library at `lua/tomltools/` and its modules
`require` each other by the absolute name `tomltools.*`. If we vendored it at
the runtimepath-visible path `lua/tomltools/`, the top-level module name
`tomltools` would be **global to Neovim**: any other installed plugin that also
vendored `tomltools` would collide, and whichever loaded first would silently
win for both.

To make collisions impossible, the engine is vendored under this plugin's own
namespace instead:

| | |
|---|---|
| Vendored at | `lua/easytasks/tomltools/` |
| Imported as | `require("easytasks.tomltools")` (and `.parser`, `.Cst`, …) |

**Invariant:** every internal `require("tomltools…")` inside the vendored files
is rewritten to `require("easytasks.tomltools…")`. The update script below
re-applies this rewrite on every sync. LuaCATS type annotations
(`---@class tomltools.Cst`, etc.) are left as the upstream `tomltools.*` names —
they are documentation only and do not affect module resolution.

### Updating the vendored engine

Run the update script. It adds the upstream remote if missing, mirrors
`lua/tomltools/*.lua` into `lua/easytasks/tomltools/` with the namespace rewrite
applied, prunes any files upstream deleted, verifies no bare `tomltools` require
survived, and records the pinned commit in [scripts/tomltools.lock](scripts/tomltools.lock):

```sh
scripts/update-tomltools.sh          # vendor upstream main
scripts/update-tomltools.sh v1.2.3   # …or a specific tag / branch / commit
```

The script does **not** commit. Review the diff, run the suite, then commit:

```sh
git diff lua/easytasks/tomltools
make test
git add lua/easytasks/tomltools scripts/tomltools.lock
git commit -m "Update vendored tomltools"
```

The currently vendored commit is recorded in `scripts/tomltools.lock`. Note that
the pinned commit may lag `main` on purpose — pass an explicit ref to move it.

### After updating: check the consuming API

The plugin calls into the engine at a handful of sites; if the `tomltools`
public or submodule API changed, these must be updated to match:

- `runner/exec.lua`, `commands.lua` — `toml.parse`, `toml.find_path`,
  `toml.encode` (whole-document → `string`), `toml.encode_entry` (styled
  snippet → `string[]`).
- `lsp/server/*` — direct use of submodules `parser`, `decoder`, `formatter`,
  `validator`, `Cst`, `schema_nav`, `schema_util`.

A good smoke test is to open a `tasks.toml` (LSP completion/diagnostics/hover)
and run a task via `:Tasks`, in addition to `make test`.
