# Expression grammar — design spec (draft)

Status: **draft, for review.** Function-call expression grammar for the interior
of a `{{ … }}` hole in [resolver.lua](../lua/easytasks/runner/resolver.lua).

## Goal

One uniform model for the inside of a hole: function calls, comma-separated
arguments, verbatim string literals. Nesting is function composition `f(g(x))` —
no recursive brace matching, no per-context quoting rules. This is the syntax
family used by HCL, GitHub Actions `${{ }}`, and Jinja expressions.

Non-goal: control flow (`if`/`for`). This is value interpolation, not templating.

## Delimiters & top-level rules

- A hole is `{{ … }}`. Only the sequence `{{` is special; everything else at the
  top level is literal (a bare `$`, `\`, lone `}`, or DAP-style `${var}` passes
  through untouched).
- `{{{{` emits a literal `{{`. `lbrace()` does the same from expression position.
- **Type preservation**: if the *entire* trimmed value is a single hole, the
  expression's native value is returned (number / boolean / string survive; a
  `nil` result drops the field). Otherwise the value is string interpolation and
  every hole is stringified into place.

## The grammar (inside a hole)

### Values

| Kind      | Syntax                    | Notes                                                |
|-----------|---------------------------|------------------------------------------------------|
| String    | `` `…` ``, `"…"`, `'…'`    | **Always verbatim.** Backtick is the safe default.   |
| Number    | `8080`, `3.14`, `-1`      | Lua number.                                          |
| Boolean   | `true`, `false`           |                                                      |
| Call      | `name` or `name(a, b, …)` | Bare `name` ≡ zero-arg `name()`.                     |
| Param ref | `$1`, `$2`, …             | Positional macro argument (in `[expressions]` only). |
| Literal `$` | `$$`                    | Escapes the `$` sigil → a literal `$`.               |
| Group     | `( expr )`                |                                                      |
| Concat    | `a .. b`                  | Stringifies both sides; left-associative.            |

There are **no free variables**: every identifier names a built-in, registered,
or inline expression, so `name` is unambiguously a zero-arg call.

### The `$` sigil

`$` is special **only in expression position** (inside a hole). The tokenizer
reads it as:

- `$` + one or more digits → positional param (`$1`, `$2`).
- `$$` → a literal `$` (symmetric to `{{{{` → `{{`).
- `$` + a letter → **reserved** for future named params (parse error for now).

Outside holes (top-level text) and inside verbatim string literals, `$` is an
ordinary character — which is why DAP-style `${var}` passes through untouched and
`` `$` `` yields `$`. So a literal `$` is always insertable: `$$` where params are
live, a bare `$` everywhere else.

### Strings, quoting, and TOML

A string literal is the exact bytes between its delimiters — no escape sequences,
no interpolation. Three interchangeable delimiters exist so you can pick one your
content doesn't contain:

- **`` `…` `` (backtick) — recommended default.** Backtick is not a TOML string
  delimiter, so a backtick literal survives TOML untouched regardless of whether
  the surrounding tasks-file value is a TOML basic (`"…"`) or literal (`'…'`)
  string. No double-layer escaping, ever.
- `"…"` / `'…'` also work, but they can collide with the *outer* TOML string's
  delimiter (a `"` inside a TOML basic string is TOML-decoded to `"` before our
  parser sees it, which would close the literal). Reach for these only when the
  content has a backtick.

Escapes are **free from TOML**: TOML decodes `\n`, `\t`, etc. in a basic string
before our parser runs, and leaves a literal string raw. So a real newline in an
expression string is just a real newline the parser passes through — we add no
escape layer of our own.

To interpolate a value into a string, **concat** it (`$1` and `{{…}}` inside a
string are literal, never expanded):

```
{{ shell(`printf 'a, b'`) }}          # backtick: the ' inside is literal
{{ shell(`echo ` .. file()) }}        # compose a command
{{ env(`HOME`) }}
```

### Quote-aware hole scanning

The scanner that finds a hole's closing `}}` skips string contents, so braces and
`}}` inside a string are safe and never close the hole early:

```
{{ shell(`sed 's/}}/X/'`) }}          # }} inside the string is fine
```

### Concatenation operator

`..` — the only operator in v1; stringifies both operands. No arithmetic (use a
`lua(…)` call if ever needed). `+ - * / | . []` are **reserved** by the tokenizer
(clear parse error) so pipelines/arithmetic can be added later cleanly.

### EBNF

```ebnf
expr      = concat ;
concat    = primary { ".." primary } ;
primary   = call | literal | param | litdollar | "(" expr ")" ;
call      = ident [ "(" [ arglist ] ")" ] ;
arglist   = expr { "," expr } [ "," ] ;
param     = "$" digit { digit } ;
litdollar = "$$" ;
literal   = string | number | boolean ;
string    = "`" { any } "`" | '"' { any } '"' | "'" { any } "'" ;
number    = [ "-" ] digit { digit } [ "." digit { digit } ] ;
boolean   = "true" | "false" ;
ident     = alpha { alpha | digit | "_" | "-" } ;
```

(`ident` allows `-` so names like `select-pid` work.)

## Inline macros (`[expressions]` table)

`[expressions]` maps a name to a **template string** that may contain holes.

- **Positional params `$1`, `$2`, …** — referenced from expression position.
- Called like any function: `{{ greet(`world`) }}`.
- Arguments are evaluated in the **caller's** scope, type-preservingly (a sole
  `$1` keeps a number/boolean).
- Cycle detection and "a real/registered expression shadows an inline one of the
  same name" both apply. Referencing an unsupplied `$N`, or `$N` outside a macro,
  is an error.

```toml
[expressions]
greet  = "`Hello, ` .. $1 .. `!`"
backup = "shell(`cp ` .. $1 .. ` ` .. $1 .. `.bak`)"
tagged = "greet($1) .. ` [` .. env(`USER`) .. `]`"
```

Named params (`greet(name) = …`) are out of scope for v1; `$` + non-digit is
reserved for that.

## Module layout

The grammar lives in **one pure module** — a tokenizer + parser producing an AST,
with **no `vim` calls and no evaluation**. Both consumers import it:

- **Runner** ([resolver.lua](../lua/easytasks/runner/resolver.lua)) walks the AST
  to evaluate (calls into [expressions.lua](../lua/easytasks/expressions.lua) for
  function bodies, handles type preservation).
- **LSP** ([completion.lua](../lua/easytasks/lsp/server/completion.lua)) parses to
  locate the cursor (name position? argument N? which call?) for completion and
  signature help.

Proposed home: `util/expr.lua` (per the shared-helpers convention). Keeping it
pure is what matters — the LSP must not pull in the evaluator's side effects.
`expressions.lua` stays the function **registry**; the evaluator stays in the
runner.

## Expression functions

`M.register(name, fn)` and the `easytasks.ExpressionFn` signature (`fn(ctx, …)`)
are unchanged; a function receives its evaluated arguments positionally. There is
no longer a "raw-body" flavor — a verbatim string literal covers that need.

## LSP impact

A real parser upgrades completion:

- Completion for names after `{{` **and** after `(` (nested calls).
- Signature help per argument (driven by `,`).
- Diagnostics on unterminated string/paren and on reserved operators.
- Hover on a function name (existing descriptions).

## Decisions

1. **Pipelines** — deferred; `|` is reserved by the tokenizer so pipes can be
   added later without a breaking change. `f(g(x))` + `..` covers the pain now.
2. **Concat token** — `..` (Lua-native, no arithmetic confusion).
3. **Macro params** — positional `$1`, `$2`, …; `$$` escapes a literal `$`;
   `$` + letter reserved for future named params.
