---@class tomltasks.runner.resolver
local M = {}

local expressions = require("tomltasks.expressions")
local expr = require("tomltasks.util.expr")

--- Expression evaluation
--- ─────────────────────
--- A task string is literal text with `{{ … }}` *holes*. Nothing outside a hole
--- is special, so the top level never needs escaping: a bare `$`, `\`, or single
--- `}` is literal, and DAP-style `${var}` passes through untouched. Only the
--- two-character sequence `{{` opens a hole; a bare `}}` outside a hole is already
--- literal. To emit a literal `{{`, double it: `{{{{` → `{{` (or use the `lbrace`
--- built-in, `{{ lbrace }}`).
---
--- The text *inside* a hole is a function-call expression, parsed by
--- `tomltasks.util.expr` into an AST that this module walks: `name(arg, …)` calls
--- (a bare `name` is a zero-arg call), verbatim string literals
--- (`"…"` / `'…'`), numbers, booleans, `$1`/`$2` positional macro
--- arguments, and the `..` concatenation operator. Nesting is function composition
--- — `upper(env("HOME"))` — so there are no nested `{{ }}` holes and no per-context
--- quoting rules. See docs/expression-grammar.md.
---
--- Because string literals are verbatim, the hole scanner (`_find_span`) skips
--- their contents (via `expr.skip_string`), so a `}}` inside a string never closes
--- the hole early.

---@type fun(str: string, open_at: integer): string?, integer?, string?
local _find_span

--- Find the extent of a `{{ … }}` hole. `open_at` is the index of the opening
--- `{{`'s first `{`. String literals are skipped so a `}}` inside one does not
--- close the hole. There are no nested holes in the grammar (nesting is function
--- composition), so no brace recursion is needed. Returns the inner text (between
--- the braces) and the index of the closing `}}`'s second `}`.
---@param str     string
---@param open_at integer
---@return string? inner, integer? close_at, string? err
_find_span = function(str, open_at)
    local n = #str
    local i = open_at + 2
    while i <= n do
        local skip, serr = expr.skip_string(str, i)
        if serr then
            return nil, nil, "Unterminated string in expression"
        elseif skip then
            i = skip
        elseif str:sub(i, i) == "}" and str:sub(i + 1, i + 1) == "}" then
            return str:sub(open_at + 2, i - 1), i + 1
        else
            i = i + 1
        end
    end
    return nil, nil, "Unterminated expression"
end

--- Run `fn` on the main loop and wait (via coroutine yield) for its result, so an
--- expression may call `vim.*` APIs freely. `n` is the number of arguments in
--- `args` — passed explicitly so a trailing `nil` argument survives.
---@param fn   function
---@param args any[]
---@param n    integer
local function _async_call(fn, args, n)
    local parent_co = coroutine.running()
    vim.schedule(function()
        coroutine.wrap(function()
            local ret = vim.F.pack_len(pcall(fn, unpack(args, 1, n)))
            coroutine.resume(parent_co, vim.F.unpack_len(ret))
        end)()
    end)
    return coroutine.yield()
end

---@type fun(inner: string, ctx: tomltasks.ExpressionCtx): any, string?
local _eval_expression

---@type fun(node: tomltasks.expr.Node, ctx: tomltasks.ExpressionCtx): any, string?
local _eval_node

---@type fun(node: tomltasks.expr.Node, ctx: tomltasks.ExpressionCtx): any, string?
local _eval_call

---@type fun(str: string, ctx: tomltasks.ExpressionCtx): string?, string?
local _expand_recursive

---@type fun(str: string, ctx: tomltasks.ExpressionCtx): any, string?
local _expand_value

--- Evaluate one AST node to a value. Literals yield their value; a `concat`
--- stringifies its operands (a `nil` operand becomes `""`); a `param` reads the
--- current inline-expression argument frame; a `call` is delegated to
--- `_eval_call`. Values are returned type-preservingly (a sole number/boolean
--- survives) — the caller decides whether to stringify.
---@param node tomltasks.expr.Node
---@param ctx  tomltasks.ExpressionCtx
---@return any value, string? err
_eval_node = function(node, ctx)
    local kind = node.kind
    if kind == "string" or kind == "number" or kind == "boolean" then
        return node.value
    elseif kind == "param" then
        local frame = ctx._args and ctx._args[#ctx._args]
        if not frame then
            return nil, ("positional argument $%d used outside an inline expression"):format(node.index)
        end
        if node.index < 1 or node.index > frame.n then
            return nil, ("no argument $%d (inline expression received %d)"):format(node.index, frame.n)
        end
        return frame[node.index]
    elseif kind == "concat" then
        local parts = {} ---@type string[]
        for i = 1, #node.parts do
            local val, err = _eval_node(node.parts[i], ctx)
            if err then return nil, err end
            parts[i] = val == nil and "" or tostring(val)
        end
        return table.concat(parts)
    elseif kind == "call" then
        return _eval_call(node, ctx)
    end
    return nil, "internal error: unknown node kind '" .. tostring(kind) .. "'"
end

--- Evaluate a `call` node. Arguments are evaluated first, in the caller's scope,
--- type-preservingly. The name is then resolved: a built-in or user-registered
--- expression (`expressions.get`) is invoked as `fn(ctx, arg1, …)`; otherwise it
--- is looked up in the inline `[expressions]` table (`ctx.expressions`) and its
--- template resolved with a fresh positional-argument frame (`$1`, `$2`, …) on
--- `ctx._args`. A cycle guard (`ctx._resolving`) turns runaway inline recursion
--- into an error.
---@param node tomltasks.expr.Node
---@param ctx  tomltasks.ExpressionCtx
---@return any value, string? err
_eval_call = function(node, ctx)
    local name = node.name --[[@as string]]
    local nargs = #node.args

    -- A nil result is a legitimate value (e.g. an unset env var), so track the
    -- count explicitly rather than via `#` (unreliable with nil array holes).
    local argvals = {} ---@type any[]
    for k = 1, nargs do
        local val, err = _eval_node(node.args[k], ctx)
        if err then return nil, err end
        argvals[k] = val
    end

    local fn = expressions.get(name)
    if not fn then
        local template = ctx.expressions and ctx.expressions[name]
        if template == nil then return nil, "Unknown expression: '" .. name .. "'" end

        local frame = { n = nargs } ---@type {n:integer,[integer]:any}
        for k = 1, nargs do frame[k] = argvals[k] end

        local resolving = ctx._resolving or {}
        ctx._resolving = resolving
        if resolving[name] then return nil, "Expression cycle detected: '" .. name .. "'" end
        resolving[name] = true

        local args_stack = ctx._args or {}
        ctx._args = args_stack
        args_stack[#args_stack + 1] = frame

        local val, expand_err = _expand_value(template, ctx)

        args_stack[#args_stack] = nil
        resolving[name] = nil
        if expand_err then
            return nil, ("in inline expression `%s`: %s"):format(name, expand_err)
        end
        return val
    end

    -- Built-in / registered function: fn(ctx, arg1, …). Build the argument vector
    -- with an explicit length so a trailing nil survives to the callee.
    local call_args = { ctx } ---@type any[]
    for k = 1, nargs do call_args[k + 1] = argvals[k] end

    local status, val, expression_err = _async_call(fn, call_args, nargs + 1)
    if not status then
        return nil, "[" .. name .. "] Expression crashed: " .. tostring(val)
    end
    if val == nil and expression_err then
        return nil, "[" .. name .. "] " .. tostring(expression_err)
    end
    local valtype = type(val)
    if valtype ~= "nil" and valtype ~= "boolean" and valtype ~= "number" and valtype ~= "string" then
        return nil, "[" .. name .. "] Invalid return type: " .. valtype
    end
    return val
end

--- Evaluate a hole's inner text: parse it to an AST and walk it. Returns the
--- expression's raw value; callers decide whether to stringify it (interpolation)
--- or preserve its type (a sole hole; see `_expand_value`).
---@param inner string
---@param ctx   tomltasks.ExpressionCtx
---@return any value, string? err
_eval_expression = function(inner, ctx)
    local ast, perr = expr.parse(inner)
    if not ast then return nil, perr end
    return _eval_node(ast, ctx)
end

--- Expand a string value as interpolation: literal text is copied through and
--- every `{{ … }}` hole is stringified into place. The top level has no escaping,
--- so backslashes and lone braces are literal; `{{{{` emits a literal `{{`.
---@param str string
---@param ctx tomltasks.ExpressionCtx
---@return string|nil result, string|nil err
_expand_recursive = function(str, ctx)
    local res = {} ---@type string[]
    local n, i = #str, 1
    while i <= n do
        local open = str:find("{{", i, true)
        if not open then
            res[#res + 1] = str:sub(i)
            break
        end
        if open > i then res[#res + 1] = str:sub(i, open - 1) end
        if str:sub(open + 2, open + 3) == "{{" then
            -- `{{{{` escapes a literal `{{` — the "double the delimiter" convention.
            res[#res + 1] = "{{"
            i = open + 4
        else
            local content, close, err = _find_span(str, open)
            if not close then return nil, err end
            local val, eval_err = _eval_expression(content --[[@as string]], ctx)
            if eval_err then return nil, eval_err end
            res[#res + 1] = val == nil and "" or tostring(val)
            i = close + 1
        end
    end
    return table.concat(res)
end

--- Expand a single (string) value. When the *entire* trimmed value is one hole
--- (`"{{ name(args) }}"`), the expression's raw value is returned, so non-string
--- types (numbers, booleans, …) survive intact. Otherwise the value is treated as
--- string interpolation and every hole's result is stringified into place.
---@param str string
---@param ctx tomltasks.ExpressionCtx
---@return any value, string? err
_expand_value = function(str, ctx)
    local trimmed = vim.trim(str)
    if trimmed:sub(1, 2) == "{{" and trimmed:sub(3, 4) ~= "{{" then
        local content, close = _find_span(trimmed, 1)
        if content ~= nil and close == #trimmed then
            return _eval_expression(content, ctx)
        end
    end
    return _expand_recursive(str, ctx)
end

--- Human-readable path to a nested key, for error messages: array indices use
--- `[i]`, map keys are dotted (`env.PATH`).
---@param path string?
---@param key any
---@return string
local function _keylabel(path, key)
    if type(key) == "number" then return (path or "") .. "[" .. key .. "]" end
    return path and (path .. "." .. tostring(key)) or tostring(key)
end

---@param tbl  table
---@param seen table
---@param ctx  tomltasks.ExpressionCtx
---@param path string?  dotted key path to `tbl`, prefixed onto error messages
---@return boolean ok, string? err
local function _expand_table(tbl, seen, ctx, path)
    seen = seen or {}
    if seen[tbl] then return true end
    seen[tbl] = true
    for k, v in pairs(tbl) do
        local keypath = _keylabel(path, k)
        if type(v) == "table" then
            local ok, err = _expand_table(v, seen, ctx, keypath)
            if not ok then return false, err end
        elseif type(v) == "string" then
            local res, err = _expand_value(v, ctx)
            if err then return false, ("in `%s`: %s"):format(keypath, err) end
            tbl[k] = res
        end
    end
    return true
end

---@param val      any                    string or table to expand
---@param ctx      tomltasks.ExpressionCtx
---@param callback fun(ok: boolean, result: any, err: string?)
function M.resolve_expressions(val, ctx, callback)
    coroutine.wrap(function()
        local call_ok, call_ret = xpcall(function()
            if type(val) == "table" then
                local tbl = vim.deepcopy(val)
                local ok, err = _expand_table(tbl, {}, ctx)
                if not ok then error(err) end
                return tbl
            elseif type(val) == "string" then
                local res, err = _expand_value(val, ctx)
                if err then error(err) end
                return res
            else
                return val
            end
        end, debug.traceback)

        local ok, result, err
        if call_ok then
            ok     = true
            result = call_ret
        else
            ok  = false
            err = call_ret
            if type(err) == "string" then
                local clean = err:match(":%d+: (.*)\nstack traceback:")
                if clean then err = clean end
            end
        end

        vim.schedule(function() callback(ok, result, err) end)
    end)()
end

return M
