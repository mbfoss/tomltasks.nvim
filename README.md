# easytasks.nvim

A project-local **task runner for Neovim**. Declare your build, test, run, and
debug tasks once in a TOML file and launch them from inside the editor with
`:Tasks` — with schema-backed completion and diagnostics while you edit the
file, task dependencies, value expressions, quickfix parsing, and a live status
panel that streams each task's output.

> [!WARNING]
> **Work in progress.** The plugin is usable but under active development; the
> configuration format and public API may still change.

---

## Table of contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [The tasks file](#the-tasks-file)
- [Task types](#task-types)
  - [`process`](#process)
  - [`shell`](#shell)
  - [`composite`](#composite)
  - [`debug`](#debug)
- [Shared task options](#shared-task-options)
- [Expressions](#expressions)
- [Quickfix matchers](#quickfix-matchers)
- [The `:Tasks` command](#the-tasks-command)
- [Status panel](#status-panel)
- [Editing support (LSP)](#editing-support-lsp)
- [Configuration](#configuration)
- [Extending easytasks](#extending-easytasks)
- [Credits & license](#credits--license)

---

## Features

- **One TOML file per project** — tasks live in `tasks.toml` at the project
  root; the presence of that file *is* what marks a directory as a project.
- **Built-in task types** — run a program directly (`process`), through a shell
  (`shell`), group other tasks (`composite`), or start a debug session
  (`debug`, via [easydap.nvim](https://github.com/mbfoss/easydap.nvim)).
- **Task dependencies** — declare `depends_on` and run prerequisites in
  `sequence` or in `parallel` before the task itself.
- **Concurrency policies** — control what happens when a task is already running
  (`wait`, `restart`, `refuse`, `parallel`).
- **Value expressions** — interpolate the current file, cwd, environment,
  shell output, or interactive prompts into task values with a small
  `{{ … }}` expression language, and define your own reusable inline macros.
- **Quickfix parsing** — turn compiler/linter/test output into a populated
  quickfix list with a named matcher (GCC, TypeScript, Go, Rust, Python, and
  more built in).
- **Schema-backed editing** — a vendored in-process language server gives the
  tasks file completion, hover, diagnostics, code actions, and formatting driven
  by the live task schema.
- **Live status panel** — a bottom split with a tab per run streaming its
  output, plus an embedded scratch shell.
- **Extensible** — register your own task types, quickfix matchers, and
  expressions from Lua.

## Requirements

- **Neovim ≥ 0.10**
- [easydap.nvim](https://github.com/mbfoss/easydap.nvim) — *optional*, required
  only for the `debug` task type.

The TOML engine is vendored, so there are no external Lua dependencies.

## Installation

Using Neovim's built-in plugin manager, `vim.pack` (**Neovim 0.12+**; see
`:help vim.pack`):

```lua
vim.pack.add({
  -- { src = "https://github.com/mbfoss/easydap.nvim" }, -- optional, only for `debug` tasks
  { src = "https://github.com/mbfoss/easytasks.nvim" },
})

-- require("easydap").setup()
require("easytasks").setup()
```

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "mbfoss/easytasks.nvim",
  -- optional, only for `debug` tasks:
  -- dependencies = { "mbfoss/easydap.nvim" },
  opts = {},
}
```

> `opts = {}` calls `require("easytasks").setup()` with the defaults. Replace it
> with a table to override any [configuration](#configuration) value.

## Quick start

1. Create a `tasks.toml` in your project root:

   ```toml
   [tasks.build]
   type    = "shell"
   command = "make -j"

   [tasks.test]
   type       = "process"
   command    = "ctest --output-on-failure"
   depends_on = ["build"]
   ```

2. Run a task:

   ```vim
   :Tasks
   ```

   Pick a task from the list. The [status panel](#status-panel) opens and streams
   its output. Running `test` first runs `build` (its dependency), then `test`.

3. Re-run the last task, or stop a running one:

   ```vim
   :Tasks rerun
   :Tasks stop
   ```

While editing `tasks.toml` you get completion, hover docs, and inline
diagnostics for every field — see [Editing support](#editing-support-lsp).

## The tasks file

Tasks are defined under the `[tasks]` table, keyed by name. A task's **name is
the header key** (`[tasks.<name>]`) — you do not repeat it as a field. Every
task must declare a `type`.

```toml
# Optional: reusable inline expression macros (see “Expressions”).
[expressions]
outdir = "{{ projectdir }}/build"

[tasks.build]
type    = "shell"
command = "cmake --build {{ outdir }}"

[tasks.run]
type       = "process"
command    = "{{ outdir }}/app --verbose"
depends_on = ["build"]
```

The top-level document has just two tables:

| Key            | Purpose                                                         |
| -------------- | -------------------------------------------------------------- |
| `[tasks]`      | Task definitions, keyed by name (`[tasks.<name>]`). Required.   |
| `[expressions]`| Named inline [expression](#expressions) macros. Optional.      |

## Task types

Every task shares a common set of [options](#shared-task-options); the fields
below are specific to each type.

### `process`

Runs a command **directly, without a shell**. A string command is split into
argv using POSIX shell-word rules; an array is used verbatim (no splitting,
globbing, or shell operators).

```toml
[tasks.lint]
type             = "process"
command          = "eslint src --format unix"   # or ["eslint", "src", …]
cwd              = "{{ projectdir }}"
env              = { NODE_ENV = "development" }
quickfix_matcher = "linter"
```

| Field              | Type                    | Description                                                            |
| ------------------ | ----------------------- | --------------------------------------------------------------------- |
| `command`          | string \| string[]      | **Required.** Program + args. String is shell-word split; array as-is. |
| `cwd`              | string                  | Working directory for the command.                                    |
| `env`              | table\<string,string>   | Environment variables to set.                                         |
| `clear_env`        | boolean                 | Pass `env` verbatim instead of merging it onto the current env.       |
| `quickfix_matcher` | string                  | Name of a [quickfix matcher](#quickfix-matchers) to parse output.     |

### `shell`

Runs a command **string through the shell**, so pipes, globs, redirection, and
`&&` all work.

```toml
[tasks.deploy]
type    = "shell"
command = "npm run build && rsync -a dist/ server:/var/www"
```

Fields are the same as `process`, except `command` must be a single **string**
(it is the shell command line).

### `composite`

A task with no command of its own — it exists purely to group other tasks
through its dependencies. Combine with `depends_order` to run them in sequence
or in parallel.

```toml
[tasks.ci]
type          = "composite"
depends_on    = ["lint", "test", "build"]
depends_order = "sequence"
```

### `debug`

Starts a DAP debug session through [easydap.nvim](https://github.com/mbfoss/easydap.nvim).
This task type is **only available when easydap.nvim is installed** — without it,
easytasks works normally and simply offers no `debug` type.

easytasks owns only the framework fields; the debugger vocabulary comes from
easydap. Each adapter publishes a set of **named configurations** — its
launch/attach shapes — that you pick from with `configuration`, then fill that
configuration's inputs with `parameters`. For anything a configuration
doesn't expose, `request_overrides` merges raw fields straight into the DAP request
body.

```toml
[tasks.debug-app]
type          = "debug"
adapter       = "codelldb"
configuration = "launch"
parameters    = { command = "{{ outdir }}/app --flag", cwd = "{{ projectdir }}" }
```

| Field           | Type                     | Description                                                                                    |
| --------------- | ------------------------ | --------------------------------------------------------------------------------------------- |
| `adapter`       | string                   | **Required.** DAP adapter name (e.g. `codelldb`, `delve`, `debugpy`).                          |
| `configuration` | string                   | **Required.** Which of the adapter's named configurations to run (e.g. `launch`, `attach`).   |
| `parameters`    | table                    | Values for the selected `configuration`'s inputs. Keys depend on `adapter`/`configuration`. |
| `request_overrides` | table                    | Raw DAP request-body fields, deep-merged over the resolved configuration. Advanced escape hatch; not validated against the adapter. |
| `raw_messages`  | boolean                  | Capture the raw DAP protocol messages in a dedicated buffer.                                   |

When the tasks-file LSP has easydap available, `configuration` completes to the
adapter's named configurations and `parameters` is completed and validated
against the inputs that configuration declares. `request_overrides` is passed
through verbatim and is not validated.
 
## Shared task options

These fields are available on **every** task type.

| Field           | Type                                | Description                                                                            |
| --------------- | ----------------------------------- | ------------------------------------------------------------------------------------- |
| `type`          | string                              | **Required.** The task type.                                                          |
| `if_running`    | enum                                | What to do if the task is already running (see below).                                |
| `depends_on`    | string[]                            | Task names that must complete successfully before this task runs.                     |
| `depends_order` | `"sequence"` \| `"parallel"`        | How the `depends_on` tasks are executed. `sequence` = one after another.              |
| `save_buffers`  | boolean \| table                    | Save modified project buffers before the task (and its dependencies) run.             |

**`if_running`** values:

| Value       | Behaviour                                                       |
| ----------- | -------------------------------------------------------------- |
| `wait`      | Wait for the running instance to finish successfully.          |
| `restart`   | Stop the current instance and start a new one.                 |
| `refuse`    | Do not start a new instance if one is already running.         |
| `parallel`  | Start a new instance alongside any existing ones.              |

**`save_buffers`** can be `true` (save every modified project buffer) or a table
with glob filters:

```toml
[tasks.build]
type         = "shell"
command      = "make"
save_buffers = { include = ["src/**"], exclude = ["**/*.tmp"], include_hidden = false }
```

Hidden files (dotfiles / files under dot-directories) are skipped unless
`include_hidden = true`.

## Expressions

Any task value can contain **`{{ … }}` holes** that are evaluated when the task
runs. The interior of a hole is a small expression language: function calls,
comma-separated arguments, string literals, numbers, booleans, and `..`
concatenation. Nesting is function composition — `f(g(x))`.

```toml
[tasks.run]
type    = "process"
command = "{{ projectdir }}/build/app"
cwd     = "{{ filedir }}"
env     = { API_KEY = "{{ env('API_KEY') }}", REV = "{{ shell('git rev-parse --short HEAD') }}" }
```

If the **entire** trimmed value is a single hole, the expression's native value
is preserved (a number stays a number, a boolean a boolean, and a `nil` result
drops the field). Otherwise the value is string interpolation.

### Built-in expressions

| Expression                              | Result                                                            |
| --------------------------------------- | ---------------------------------------------------------------- |
| `file` *(filetype?)*                    | Absolute path of the current file.                               |
| `filename` *(filetype?)*                | File name with extension.                                        |
| `fileroot` *(filetype?)*                | Absolute path without the extension.                             |
| `filedir`                               | Absolute directory of the current file.                          |
| `fileext`                               | Extension (without the dot).                                     |
| `cwd`                                   | The task's `cwd`, or the editor cwd.                             |
| `projectdir`                            | Absolute path of the project root (where the tasks file lives).  |
| `env(NAME)`                             | Value of an environment variable.                                |
| `shell(CMD)`                            | Stdout of a shell command, trailing newlines stripped.           |
| `prompt(TEXT, default?, completion?)`   | Ask for input at run time.                                       |
| `select-pid(prompt?)`                   | Pick a running process and yield its PID.                        |
| `lbrace`                                | A literal `{{` (escape hatch; same as `{{{{`).                   |

Strings inside a hole use `"…"` or `'…'` and are **always verbatim** (no escape
sequences, no nested interpolation) — pick the quote your content lacks. To
build up a value, concatenate with `..`:

```toml
command = "{{ shell('echo ' .. file()) }}"
```

### Inline macros

Define reusable named expressions under `[expressions]`. They may reference
built-ins, other inline macros, and their own positional arguments `$1`, `$2`, …

```toml
[expressions]
greet  = "'Hello, ' .. $1 .. '!'"
tagged = "greet($1) .. ' [' .. env('USER') .. ']'"
outdir = "{{ projectdir }}/build/{{ $1 }}"

[tasks.run]
type    = "shell"
command = "echo {{ tagged('world') }} && ls {{ outdir('release') }}"
```

You can evaluate any expression against the current project without running a
task:

```vim
:Tasks eval file
:Tasks eval {{ shell('git branch --show-current') }}
```

See [docs/expression-grammar.md](docs/expression-grammar.md) for the full
grammar.

## Quickfix matchers

Set `quickfix_matcher` on a `process` or `shell` task to parse its output into
the quickfix list as it streams. The list is cleared when the task starts and
populated line by line, so you can `:copen` and jump straight to errors.

Built-in matchers:

| Name     | Tooling                                             |
| -------- | --------------------------------------------------- |
| `gcc`    | GCC / Clang (incl. template “required from” chains) |
| `msvc`   | MSVC (`file(line): error CXXXX: …`)                 |
| `tsc`    | TypeScript compiler                                 |
| `go`     | Go compiler                                         |
| `gotest` | `go test` output                                    |
| `cargo`  | Rust / Cargo (errors and panics)                    |
| `python` | Python tracebacks                                   |
| `pytest` | pytest / unittest                                   |
| `linter` | Generic `file:line:col: CODE: msg` (ESLint, Pylint, Flake8, Mypy, …) |
| `unix`   | Generic `file:line:col: message`                    |

Register your own with [`register_qfmatcher`](#extending-easytasks).

## The `:Tasks` command

The user command (named `Tasks` by default) is the single entry point. Called
with no argument it opens the task picker.

| Invocation              | Action                                                          |
| ----------------------- | -------------------------------------------------------------- |
| `:Tasks` / `:Tasks run` | Pick a task to run (with a live preview of its definition).    |
| `:Tasks rerun`          | Re-run the last task.                                           |
| `:Tasks stop`           | Pick a running task to stop.                                    |
| `:Tasks cancel`         | Stop **all** running tasks.                                     |
| `:Tasks shell`          | Open a scratch shell tab in the status panel.                  |
| `:Tasks eval [expr]`    | Evaluate an expression (or bare expression name) and echo it.  |
| `:Tasks template`       | Insert a task template at the cursor (only in the tasks file). |
| `:Tasks panel`          | Toggle the [status panel](#status-panel).                      |
| `:Tasks panel jump N`   | Focus panel page/tab N.                                         |
| `:Tasks panel remove`   | Dispose a finished task tab.                                    |
| `:Tasks panel clear`    | Dispose all finished task tabs.                                 |

Subcommands and task names complete on `<Tab>`.

`:Tasks panel jump N` takes the page number as an argument, so you can bind it
with a count prefix — e.g. `3<leader>tj` focuses page 3:

```lua
vim.keymap.set("n", "<leader>tj", function()
    vim.cmd("Tasks panel jump " .. vim.v.count1)
end, { desc = "Jump to status panel page [count]" })
```

## Status panel

Running a task opens a bottom split with a **winbar of tabs** — one per run,
each numbered, showing a status badge (`▶` running, `✓` ok, `✗` failed, `⧗`
waiting on dependencies). Each tab has:

- an **info page** with a timestamped run log, and
- a **terminal page** per spawned buffer, streaming stdout/stderr live.

Click a tab or use `:Tasks panel jump N` to switch pages. New output on an
inactive tab is flagged with an unread marker. Terminal pages autoscroll while
your cursor sits at the bottom, and stop following as soon as you scroll up.
`:Tasks shell` adds a plain interactive shell as its own tab.

## Editing support (LSP)

Opening the tasks file attaches a **vendored, in-process language server**
(it runs on a background thread, not a subprocess) that is driven by the live
task schema — including any task types, adapters, and expressions you have
registered. It provides:

- **Completion** — task types, field names, enum values, dependency task names,
  and expression names/arguments inside `{{ … }}`.
- **Diagnostics** — schema validation, unknown fields, type errors, and
  malformed expressions, shown inline as you type.
- **Hover** — field and expression documentation.
- **Code actions** and **formatting** for the TOML document.

The tasks file gets its own `easytasks` filetype (it is *not* treated as generic
`toml`), so your existing TOML tooling is left untouched and no extra
Tree-sitter parser is pulled in.

## Configuration

Call `setup()` (directly, or via your plugin manager's `opts`). All fields are
optional; defaults shown:

```lua
require("easytasks").setup({
  enabled        = true,          -- attach the LSP + register the command
  command        = "Tasks",       -- name of the user command
  tasks_filename = "tasks.toml",  -- per-project tasks file (also the project marker)
  storage_dir    = ".easytasks",  -- per-project state directory
})
```

Toggle the plugin at runtime with `require("easytasks").enable()` /
`require("easytasks").disable()`, and check whether the cwd is an easytasks
project with `require("easytasks").in_project()`.

## Extending easytasks

The public API in [`require("easytasks")`](lua/easytasks/init.lua) exposes three
extension points. Register **before** `setup()` so the new definitions are
included in the schema the LSP uses.

```lua
local easytasks = require("easytasks")

-- A custom task type (loader may be a module path, a factory fn, or a table).
easytasks.register_task_type("http", function()
  return {
    start = function(task, ctx, on_done)
      -- … kick off work; call ctx.add_bufnr / ctx.report as needed …
      on_done(true)
      return function() --[[ cancel ]] end
    end,
    schema = { properties = { url = { type = "string" } }, required = { "url" } },
  }
end)

-- A custom quickfix matcher for `process`/`shell` tasks.
easytasks.register_qfmatcher("myfmt", function(line, ctx)
  local file, lnum, msg = line:match("^(%S+):(%d+):%s+(.+)$")
  if file then
    return { filename = file, lnum = tonumber(lnum), col = 1, text = msg, type = "E" }
  end
end)

-- A custom expression, usable as `{{ hostname }}` in task values.
easytasks.register_expression("hostname", function(ctx)
  return vim.uv.os_gethostname()
end, { desc = "The machine hostname" })
```

- **`register_task_type(name, loader)`** — add a task type. `loader` is a module
  path string, a zero-arg factory, or a resolved definition table.
- **`register_qfmatcher(name, fn)`** — add a quickfix matcher; `fn(line, ctx)`
  returns a quickfix item or `nil`.
- **`register_expression(name, fn, opts?)`** — add a `{{ … }}` expression;
  built-ins cannot be overridden. `opts.desc` shows in completion.

## Credits & license

- TOML engine: [tomltools](https://github.com/mbfoss/tomltools).
- Debug support: [easydap.nvim](https://github.com/mbfoss/easydap.nvim).

Released under the [MIT License](LICENSE).

Contributing? See [development.md](development.md) for the repository layout,
how to run the tests, and how the vendored TOML engine is maintained.
