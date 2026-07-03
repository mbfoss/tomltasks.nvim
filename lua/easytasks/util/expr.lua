--- Pure tokenizer + parser for the `{{ … }}` hole expression grammar.
---
--- This module is *pure*: no `vim` calls, no evaluation, no side effects. It
--- turns the text *inside* a hole into an AST that two consumers walk — the
--- runner (to evaluate) and the LSP (to locate the cursor). Keeping it pure lets
--- the language server import it without dragging in the evaluator.
---
--- Grammar (see docs/expression-grammar.md for the full spec):
---
---   expr      = concat
---   concat    = primary { ".." primary }        -- stringifying, left-assoc
---   primary   = call | literal | param | "(" expr ")"
---   call      = ident [ "(" [ arglist ] ")" ]   -- bare ident = zero-arg call
---   arglist   = expr { "," expr } [ "," ]
---   param     = "$" digit { digit }             -- positional macro argument
---   literal   = string | number | boolean
---   string    = "`" { any } "`" | '"' { any } '"' | "'" { any } "'"  -- verbatim
---   number    = [ "-" ] digit { digit } [ "." digit { digit } ]
---   boolean   = "true" | "false"
---   ident     = alpha { alpha | digit | "_" | "-" }
---
--- Every node carries 1-based `from`/`to` byte offsets into the source string so
--- the LSP can map a cursor column back to a node.
local M = {}

---@alias easytasks.expr.TokenKind "ident" | "number" | "string" | "boolean" | "param" | "concat" | "lparen" | "rparen" | "comma"

---@class easytasks.expr.Token
---@field kind  easytasks.expr.TokenKind
---@field from  integer                    1-based index of the first byte
---@field to    integer                    1-based index of the last byte
---@field value? string|number|boolean     text (ident/string), number, bool, or param index

---@alias easytasks.expr.NodeKind "string" | "number" | "boolean" | "param" | "call" | "concat"

---@class easytasks.expr.Node
---@field kind        easytasks.expr.NodeKind
---@field from        integer
---@field to          integer
---@field value?      string|number|boolean   literal value (string/number/boolean)
---@field index?      integer                 param index (param)
---@field name?       string                  callee name (call)
---@field name_from?  integer                 span of the callee name (call)
---@field name_to?    integer
---@field paren_open?  integer                index of `(`, if the call was parenthesized
---@field paren_close? integer                index of `)`
---@field args?       easytasks.expr.Node[]   argument nodes (call)
---@field parts?      easytasks.expr.Node[]   operands (concat)

-- ── Character classes ─────────────────────────────────────────────────────────

---@param c string
local function _is_space(c) return c == " " or c == "\t" or c == "\n" or c == "\r" or c == "\f" or c == "\v" end

---@param c string
local function _is_digit(c) return c >= "0" and c <= "9" end

---@param c string
local function _is_alpha(c) return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") end

---@param c string
local function _is_ident_start(c) return _is_alpha(c) end

---@param c string
local function _is_ident_cont(c) return _is_alpha(c) or _is_digit(c) or c == "_" or c == "-" end

--- String-literal delimiters. All three are verbatim (no escapes); the choice
--- exists so text can carry any one of them by picking another. Backtick is the
--- recommended default — it never collides with TOML's own `"`/`'`.
local _delims = { ['"'] = true, ["'"] = true, ["`"] = true }

--- Operators/brackets accepted by the tokenizer but not the grammar (yet).
--- Reported as a distinct, friendlier error than a stray character.
local _reserved = { ["+"] = true, ["*"] = true, ["/"] = true, ["|"] = true, ["["] = true, ["]"] = true }

---@param msg string
---@param pos integer
---@return string
local function _err(msg, pos)
    return ("%s (at col %d)"):format(msg, pos)
end

-- ── Tokenizer ─────────────────────────────────────────────────────────────────

--- Split `src` into tokens. Whitespace separates tokens and is otherwise
--- insignificant. Returns `nil, err` on the first malformed token.
---@param src string
---@return easytasks.expr.Token[]? tokens, string? err
local function _tokenize(src)
    local n = #src
    local i = 1
    local toks = {} ---@type easytasks.expr.Token[]

    while i <= n do
        local c = src:sub(i, i)

        if _is_space(c) then
            i = i + 1
        elseif c == "(" then
            toks[#toks + 1] = { kind = "lparen", from = i, to = i }; i = i + 1
        elseif c == ")" then
            toks[#toks + 1] = { kind = "rparen", from = i, to = i }; i = i + 1
        elseif c == "," then
            toks[#toks + 1] = { kind = "comma", from = i, to = i }; i = i + 1
        elseif c == "." then
            if src:sub(i + 1, i + 1) == "." then
                toks[#toks + 1] = { kind = "concat", from = i, to = i + 1 }; i = i + 2
            else
                return nil, _err("operator '.' is reserved for a future version", i)
            end
        elseif c == "$" then
            local nxt = src:sub(i + 1, i + 1)
            if _is_digit(nxt) then
                local j = i + 1
                while j <= n and _is_digit(src:sub(j, j)) do j = j + 1 end
                toks[#toks + 1] = { kind = "param", from = i, to = j - 1, value = tonumber(src:sub(i + 1, j - 1)) }
                i = j
            elseif _is_alpha(nxt) then
                return nil, _err("named parameters ($name) are reserved for a future version", i)
            else
                return nil, _err("'$' must be followed by a digit (e.g. $1)", i)
            end
        elseif _delims[c] then
            local j = i + 1
            while j <= n and src:sub(j, j) ~= c do j = j + 1 end
            if j > n then return nil, _err("unterminated string", i) end
            toks[#toks + 1] = { kind = "string", from = i, to = j, value = src:sub(i + 1, j - 1) }
            i = j + 1
        elseif _is_digit(c) or (c == "-" and _is_digit(src:sub(i + 1, i + 1))) then
            local j = (c == "-") and i + 1 or i
            while j <= n and _is_digit(src:sub(j, j)) do j = j + 1 end
            if src:sub(j, j) == "." and _is_digit(src:sub(j + 1, j + 1)) then
                j = j + 2
                while j <= n and _is_digit(src:sub(j, j)) do j = j + 1 end
            end
            toks[#toks + 1] = { kind = "number", from = i, to = j - 1, value = tonumber(src:sub(i, j - 1)) }
            i = j
        elseif _is_ident_start(c) then
            local j = i + 1
            while j <= n and _is_ident_cont(src:sub(j, j)) do j = j + 1 end
            local text = src:sub(i, j - 1)
            if text == "true" or text == "false" then
                toks[#toks + 1] = { kind = "boolean", from = i, to = j - 1, value = text == "true" }
            else
                toks[#toks + 1] = { kind = "ident", from = i, to = j - 1, value = text }
            end
            i = j
        elseif _reserved[c] then
            return nil, _err(("operator '%s' is reserved for a future version"):format(c), i)
        else
            return nil, _err(("unexpected character '%s'"):format(c), i)
        end
    end

    return toks
end

--- Public wrapper around the tokenizer (exported for the LSP).
---@param src string
---@return easytasks.expr.Token[]? tokens, string? err
function M.tokenize(src)
    return _tokenize(src)
end

--- If `src:sub(i, i)` opens a verbatim string literal, return the index just
--- past its closing delimiter; otherwise return `nil`. On an unterminated string
--- returns `nil, err`. Shared with the runner's hole scanner so that locating a
--- hole's closing `}}` and tokenizing its interior agree on where strings begin
--- and end — a `}}` inside a string must not be mistaken for the hole's end.
---@param src string
---@param i   integer
---@return integer? next_i, string? err
function M.skip_string(src, i)
    local c = src:sub(i, i)
    if not _delims[c] then return nil end
    local n = #src
    local j = i + 1
    while j <= n and src:sub(j, j) ~= c do j = j + 1 end
    if j > n then return nil, "unterminated string" end
    return j + 1
end

--- Given `text` that ends at a cursor, determine whether the cursor sits inside
--- an open `{{ … }}` hole and, if so, return the hole's interior from just after
--- the opening `{{` up to the end of `text` (i.e. what has been typed into the
--- hole so far). Returns `nil` when the cursor is not inside a hole. `text` must
--- begin at a point known to be outside any hole (e.g. just after a `=`) so hole
--- state can be tracked forward. A `{{{{` escape is a literal `{{`, not an opener;
--- string literals are skipped so a `}}` inside one does not close the hole. Used
--- by the LSP to locate the cursor for completion.
---@param text string
---@return string? interior
function M.scan_hole(text)
    local n = #text
    local i = 1
    local hole_start = nil ---@type integer?
    while i <= n do
        if not hole_start then
            if text:sub(i, i + 1) == "{{" then
                if text:sub(i + 2, i + 3) == "{{" then
                    i = i + 4                       -- `{{{{` escape → a literal `{{`
                else
                    hole_start = i + 2
                    i = i + 2
                end
            else
                i = i + 1
            end
        else
            local skip, serr = M.skip_string(text, i)
            if serr then
                i = n + 1                           -- unterminated string runs to the cursor
            elseif skip then
                i = skip
            elseif text:sub(i, i + 1) == "}}" then
                hole_start = nil
                i = i + 2
            else
                i = i + 1
            end
        end
    end
    if hole_start then return text:sub(hole_start) end
    return nil
end

--- Return the interior text of every *complete* `{{ … }}` hole in `text`, in
--- order. A `{{{{` escape is skipped (a literal `{{`); string literals are skipped
--- so a `}}` inside one does not close a hole; an unterminated final hole is
--- omitted (left for run time, and so half-typed expressions are not flagged).
--- Used by the LSP to diagnose each hole's expression.
---@param text string
---@return string[]
function M.holes(text)
    local out = {} ---@type string[]
    local n, i = #text, 1
    while i <= n do
        if text:sub(i, i + 1) ~= "{{" then
            i = i + 1
        elseif text:sub(i + 2, i + 3) == "{{" then
            i = i + 4                                   -- `{{{{` escape → literal `{{`
        else
            local j, closed = i + 2, false
            while j <= n do
                local skip, serr = M.skip_string(text, j)
                if serr then
                    j = n + 1                           -- unterminated string → hole never closes
                elseif skip then
                    j = skip
                elseif text:sub(j, j + 1) == "}}" then
                    out[#out + 1] = text:sub(i + 2, j - 1)
                    i, closed = j + 2, true
                    break
                else
                    j = j + 1
                end
            end
            if not closed then break end                -- unterminated hole: stop
        end
    end
    return out
end

-- ── Parser ────────────────────────────────────────────────────────────────────

--- Parse `src` (the inner text of a hole) into a single expression AST. Returns
--- `nil, err` on any syntax error. A parenthesized group is unwrapped — grouping
--- only affects precedence, so it leaves no node of its own.
---@param src string
---@return easytasks.expr.Node? ast, string? err
function M.parse(src)
    local toks, terr = _tokenize(src)
    if not toks then return nil, terr end

    local pos = 1
    local eof_col = #src + 1

    ---@return easytasks.expr.Token?
    local function peek() return toks[pos] end

    ---@return integer
    local function here() local t = toks[pos]; return t and t.from or eof_col end

    ---@type fun(): easytasks.expr.Node?, string?
    local parse_expr

    ---@return easytasks.expr.Node?, string?
    local function parse_primary()
        local t = peek()
        if not t then return nil, _err("unexpected end of expression", eof_col) end

        if t.kind == "lparen" then
            pos = pos + 1
            local inner, err = parse_expr()
            if err then return nil, err end
            local close = peek()
            if not close or close.kind ~= "rparen" then
                return nil, _err("expected ')'", here())
            end
            pos = pos + 1
            return inner
        elseif t.kind == "string" then
            pos = pos + 1
            return { kind = "string", value = t.value, from = t.from, to = t.to }
        elseif t.kind == "number" then
            pos = pos + 1
            return { kind = "number", value = t.value, from = t.from, to = t.to }
        elseif t.kind == "boolean" then
            pos = pos + 1
            return { kind = "boolean", value = t.value, from = t.from, to = t.to }
        elseif t.kind == "param" then
            pos = pos + 1
            return { kind = "param", index = t.value --[[@as integer]], from = t.from, to = t.to }
        elseif t.kind == "ident" then
            pos = pos + 1
            ---@type easytasks.expr.Node
            local node = {
                kind = "call", name = t.value --[[@as string]], args = {},
                from = t.from, to = t.to, name_from = t.from, name_to = t.to,
            }
            if peek() and peek().kind == "lparen" then
                node.paren_open = peek().from
                pos = pos + 1
                while true do
                    local nxt = peek()
                    if not nxt then return nil, _err("expected ')'", eof_col) end
                    if nxt.kind == "rparen" then break end
                    local arg, aerr = parse_expr()
                    if aerr then return nil, aerr end
                    node.args[#node.args + 1] = arg
                    local sep = peek()
                    if not sep then
                        return nil, _err("expected ')'", eof_col)
                    elseif sep.kind == "comma" then
                        pos = pos + 1                      -- consume ',' (trailing comma allowed)
                    elseif sep.kind == "rparen" then
                        break
                    else
                        return nil, _err("expected ',' or ')'", here())
                    end
                end
                local close = peek() --[[@as easytasks.expr.Token]]
                node.paren_close = close.to
                node.to = close.to
                pos = pos + 1
            end
            return node
        end

        return nil, _err(("unexpected token '%s'"):format(src:sub(t.from, t.to)), t.from)
    end

    ---@return easytasks.expr.Node?, string?
    function parse_expr()
        local first, err = parse_primary()
        if err then return nil, err end
        if not (peek() and peek().kind == "concat") then return first end

        local parts = { first }
        while peek() and peek().kind == "concat" do
            pos = pos + 1
            local part, perr = parse_primary()
            if perr then return nil, perr end
            parts[#parts + 1] = part
        end
        return { kind = "concat", parts = parts, from = parts[1].from, to = parts[#parts].to }
    end

    if not peek() then return nil, _err("empty expression", 1) end
    local ast, err = parse_expr()
    if err then return nil, err end
    if peek() then
        local t = peek() --[[@as easytasks.expr.Token]]
        return nil, _err(("unexpected trailing token '%s'"):format(src:sub(t.from, t.to)), t.from)
    end
    return ast
end

return M
