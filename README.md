# easytasks.nvim

A project-local **task runner for Neovim**. Declare your build, test, run, and
debug tasks once in a TOML file and launch them from inside the editor with
`:Tasks` — with smart completion and inline diagnostics while you edit the file,
task dependencies, value expressions, quickfix parsing, and a live status panel
that streams each task's output.

> [!WARNING]
> **Work in progress.** The plugin is usable but under active development; the
> configuration format may still change.

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
- [Editing support](#editing-support)
- [Configuration](#configuration)
- [License](#license)

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
- **Smart editing** — the tasks file gets completion, hover, diagnostics, code
  actions, and formatting as you type.
- **Live status panel** — a bottom split with a tab per run streaming its
  output, plus an embedded scratch shell.

## Requirements

- **Neovim ≥ 0.10**
- [easydap.nvim](https://github.com/mbfoss/easydap.nvim) — *optional*, required
  only for the `debug` task type.

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
diagnostics for every field — see [Editing support](#editing-support).

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

Starts a debug session through [easydap.nvim](https://github.com/mbfoss/easydap.nvim).
This task type is **only available when easydap.nvim is installed** — without it,
easytasks works normally and simply offers no `debug` type.

Each debug adapter publishes a set of **named profiles** — its launch/attach
shapes — that you pick from with `profile`, then fill that profile's inputs with
`parameters`. For anything a profile doesn't expose, `request_overrides` merges
raw fields straight into the debug request.

```toml
[tasks.debug-app]
type       = "debug"
adapter    = "codelldb"
profile    = "launch"
parameters = { command = "{{ outdir }}/app --flag", cwd = "{{ projectdir }}" }
```

| Field           | Type                     | Description                                                                                    |
| --------------- | ------------------------ | --------------------------------------------------------------------------------------------- |
| `adapter`       | string                   | **Required.** Debug adapter name (e.g. `codelldb`, `delve`, `debugpy`).                        |
| `profile`       | string                   | **Required.** Which of the adapter's named profiles to run (e.g. `launch`, `attach`).         |
| `parameters`    | table                    | Values for the selected `profile`'s inputs. Keys depend on `adapter`/`profile`.               |
| `request_overrides` | table                | Raw request fields, deep-merged over the resolved profile. Advanced escape hatch.             |
| `raw_messages`  | boolean                  | Capture the raw debug protocol messages in a dedicated buffer.                                 |

When easydap is available, `profile` completes to the adapter's named profiles
and `parameters` is completed and validated against the inputs that profile
declares.

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
inactive tab is flagged with an unread marker.
`:Tasks shell` adds a plain interactive shell as its own tab.

## Editing support

Opening the tasks file gives you rich, schema-aware editing — including any task
types, adapters, and expressions available in your setup:

- **Completion** — task types, field names, enum values, dependency task names,
  and expression names/arguments inside `{{ … }}`.
- **Diagnostics** — schema validation, unknown fields, type errors, and
  malformed expressions, shown inline as you type.
- **Hover** — field and expression documentation.
- **Code actions** and **formatting** for the TOML document.

The tasks file gets its own `easytasks` filetype, so your existing TOML tooling
is left untouched.

## Configuration

Call `setup()` (directly, or via your plugin manager's `opts`). All fields are
optional; defaults shown:

```lua
require("easytasks").setup({
  enabled        = true,          -- register the command and editing support
  command        = "Tasks",       -- name of the user command
  tasks_filename = "tasks.toml",  -- per-project tasks file (also the project marker)
  storage_dir    = ".easytasks",  -- per-project state directory
})
```

Toggle the plugin at runtime with `require("easytasks").enable()` /
`require("easytasks").disable()`, and check whether the cwd is an easytasks
project with `require("easytasks").in_project()`.

## License

Released under the [MIT License](LICENSE). Debug support is provided by
[easydap.nvim](https://github.com/mbfoss/easydap.nvim).
