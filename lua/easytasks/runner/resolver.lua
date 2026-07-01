---@class easytasks.runner.resolver
local M = {}

local expressions = require("easytasks.expressions")

--- Find the extent of a `${...}` span by matching braces. Brace counting is the
--- only structure recognised here; there is no backslash escape, so the braces
--- inside an argument must be balanced (or wrapped in a nested expression). `start_pos`
--- points at the opening `{`.
---@param str       string
---@param start_pos integer
---@return string|nil content, integer|nil end_pos, string|nil err
local function _parse_nested(str, start_pos)
    local stack  = 0
    local result = ""
    local i      = start_pos
    while i <= #str do
        local char = str:sub(i, i)
        if char == "{" then
            stack  = stack + 1
            result = result .. char
            i      = i + 1
        elseif char == "}" then
            stack = stack - 1
            if stack == 0 then return result:sub(2), i end
            result = result .. char
            i      = i + 1
        else
            result = result .. char
            i      = i + 1
        end
    end
    return nil, nil, "Unterminated expression"
end

--- Split a raw expression body into a name and arguments. The first top-level `:` ends
--- the name and begins the argument list; subsequent top-level `:` are literal,
--- and top-level `,` separate arguments. There is no backslash escape: to keep a
--- comma (or any other separator) inside a single argument, wrap that argument in
--- quotes — either `"..."` or `'...'`. A literal quote inside a quoted argument is
--- written by doubling it (`""` -> `"`, `''` -> `'`), mirroring how `$$` escapes a
--- literal `$`. Quoting only suppresses comma splitting; a nested `${...}` expression
--- still expands normally inside a quoted argument.
---
--- Splitting runs on the *unexpanded* template and copies `${...}` spans verbatim
--- (even inside quotes), so separators produced by a expression's output can never be
--- mistaken for argument boundaries. An empty argument region (`${name:}`) yields
--- no arguments, `${name:a,}` yields two (`"a"`, `""`), and an explicitly quoted
--- empty argument (`${name:""}`) yields one (`""`).
---@param inner string
---@return string name, string[] args
local function _parse_body(inner)
    local name           ---@type string?
    local args     = {}  ---@type string[]
    local cur      = ""
    local in_args  = false   -- have we passed the name and entered the arg list?
    local at_start = false   -- positioned at the start of an argument value?
    local quoted   = false   -- was the current argument opened with a quote?
    local quote          ---@type string? active quote char, nil outside a span
    local i, n = 1, #inner
    while i <= n do
        local char = inner:sub(i, i)
        if char == "$" and inner:sub(i + 1, i + 1) == "{" then
            -- Copy a nested expression span verbatim (even inside quotes) so its own
            -- separators and quotes survive to be re-parsed when it is expanded.
            local _, end_pos = _parse_nested(inner, i + 1)
            if not end_pos then -- unterminated; copy the remainder verbatim
                cur = cur .. inner:sub(i)
                break
            end
            cur      = cur .. inner:sub(i, end_pos)
            i        = end_pos + 1
            at_start = false
        elseif quote then
            if char == quote then
                if inner:sub(i + 1, i + 1) == quote then -- doubled = literal quote
                    cur = cur .. quote
                    i   = i + 2
                else                                     -- closing quote
                    quote = nil
                    i     = i + 1
                end
            else
                cur = cur .. char
                i   = i + 1
            end
        elseif char == ":" and not in_args then
            name, cur, in_args, at_start = cur, "", true, true
            i = i + 1
        elseif char == "," and in_args then
            args[#args + 1] = cur
            cur, at_start, quoted = "", true, false
            i = i + 1
        elseif (char == '"' or char == "'") and in_args and at_start then
            quote, quoted, at_start = char, true, false
            i = i + 1
        else
            cur      = cur .. char
            at_start = false
            i        = i + 1
        end
    end
    if not in_args then return cur, args end
    -- finalize the last argument unless the region was empty and unquoted
    if cur ~= "" or quoted or #args > 0 then args[#args + 1] = cur end
    return name --[[@as string]], args
end

local function _async_call(fn, args)
    local parent_co = coroutine.running()
    vim.schedule(function()
        coroutine.wrap(function()
            local ret = vim.F.pack_len(pcall(fn, unpack(args)))
            coroutine.resume(parent_co, vim.F.unpack_len(ret))
        end)()
    end)
    return coroutine.yield()
end

---@type fun(str: string, ctx: easytasks.ExpressionCtx): string?, string?
local _expand_recursive

---@type fun(str: string, ctx: easytasks.ExpressionCtx): any, string?
local _expand_value

--- Evaluate a single expression from its *raw* inner text — the part between `${` and
--- `}`, with nested expressions still unexpanded. The body is split into name + args
--- on the raw template (so a nested expression's output can never be mistaken for an
--- argument boundary), then the name and each argument are expanded
--- individually before the expression is called. Returns the expression's *raw* value;
--- callers decide whether to stringify it (string interpolation) or preserve its
--- type (a sole-expression value; see `_expand_value`).
---
--- A name that matches no built-in or registered expression is looked up in the
--- inline `[expressions]` table (`ctx.expressions`). Its template is resolved
--- type-preservingly (via `_expand_value`), so an inline definition may reference
--- other expressions; a cycle guard (`ctx._resolving`) turns runaway recursion
--- into an error. Inline expressions take no arguments.
---@param inner string
---@param ctx   easytasks.ExpressionCtx
---@return any value, string? err
local function _eval_expression(inner, ctx)
    local name_raw, args_raw = _parse_body(inner)
    local name, err = _expand_recursive(name_raw, ctx)
    if err then return nil, err end
    if not name then return nil, "Expression expansion returned nil" end
    name = vim.trim(name)
    if name == "" then return nil, "Unknown expression: ''" end

    local fn = expressions.get(name)
    if not fn then
        local template = ctx.expressions and ctx.expressions[name]
        if template == nil then return nil, "Unknown expression: '" .. name .. "'" end
        if #args_raw > 0 then
            return nil, "[" .. name .. "] inline expression does not accept arguments"
        end
        local resolving = ctx._resolving or {}
        ctx._resolving = resolving
        if resolving[name] then return nil, "Expression cycle detected: '" .. name .. "'" end
        resolving[name] = true
        local val, expand_err = _expand_value(template, ctx)
        resolving[name] = nil
        if expand_err then
            return nil, ("in inline expression `%s`: %s"):format(name, expand_err)
        end
        return val
    end

    local expression_args = { ctx } ---@type any[]
    for _, raw in ipairs(args_raw) do
        local arg, arg_err = _expand_recursive(raw, ctx)
        if arg_err then return nil, arg_err end
        expression_args[#expression_args + 1] = arg
    end

    local status, val, expression_err = _async_call(fn, expression_args)
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

---@param str string
---@param ctx easytasks.ExpressionCtx
---@return string|nil result, string|nil err
_expand_recursive = function(str, ctx)
    local res = ""
    local i   = 1
    while i <= #str do
        local char      = str:sub(i, i)
        local next_char = str:sub(i + 1, i + 1)
        if char == "$" and next_char == "$" then
            res = res .. "$"
            i   = i + 2
        elseif char == "$" and next_char == "{" then
            local content, end_pos, parse_err = _parse_nested(str, i + 1)
            if parse_err then return nil, parse_err end
            if not content then return nil, "Failed to parse expression content" end

            local val, eval_err = _eval_expression(content, ctx)
            if eval_err then return nil, eval_err end

            res = res .. tostring(val or "")
            i   = end_pos + 1
        else
            res = res .. char
            i   = i + 1
        end
    end
    return res
end

--- Expand a single (string) value. When the *entire* trimmed value is one expression
--- (`"${name:args}"`), the expression's raw value is returned, so non-string types
--- (numbers, booleans, …) survive intact. Otherwise the value is treated as
--- string interpolation and every expression result is stringified into place.
---@param str string
---@param ctx easytasks.ExpressionCtx
---@return any value, string? err
_expand_value = function(str, ctx)
    local trimmed = vim.trim(str)
    if trimmed:sub(1, 2) == "${" then
        local content, end_pos, parse_err = _parse_nested(trimmed, 2)
        if not parse_err and content and end_pos == #trimmed then
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
---@param ctx  easytasks.ExpressionCtx
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
---@param ctx      easytasks.ExpressionCtx
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
