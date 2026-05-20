-- easytasks/toml/parser.lua
local M = {}
local Tree = require("easytasks.util.tree")

---@class easytasks.Range4
---@field [1] integer
---@field [2] integer
---@field [3] integer
---@field [4] integer

---@class easytasks.Token
---@field type string
---@field value any
---@field range easytasks.Range4

local function token(type_, value, range)
    return {
        type = type_,
        value = value,
        range = range,
    }
end

---@param text string
---@return easytasks.Token[], table[]
local function tokenize(text)
    local tokens = {}
    local errors = {}

    local i = 1
    local len = #text

    local row = 0
    local col = 0

    local function current()
        return text:sub(i, i)
    end

    local function advance(n)
        n = n or 1
        for _ = 1, n do
            if i > len then
                break
            end

            local c = text:sub(i, i)

            if c == "\n" then
                row = row + 1
                col = 0
            else
                col = col + 1
            end

            i = i + 1
        end
    end

    while i <= len do
        local c = current()

        -- whitespace
        if c == " " or c == "\t" then
            local sr, sc = row, col
            local start = i

            while i <= len and (current() == " " or current() == "\t") do
                advance()
            end

            table.insert(tokens, token(
                "WHITESPACE",
                text:sub(start, i - 1),
                { sr, sc, row, col }
            ))

            -- newline
        elseif c == "\n" then
            local sr, sc = row, col
            advance()

            table.insert(tokens, token(
                "NEWLINE",
                "\n",
                { sr, sc, row, col }
            ))

            -- comment
        elseif c == "#" then
            local sr, sc = row, col
            local start = i

            while i <= len and current() ~= "\n" do
                advance()
            end

            table.insert(tokens, token(
                "COMMENT",
                text:sub(start, i - 1),
                { sr, sc, row, col }
            ))
        elseif c == "[" then
            table.insert(tokens, token("LBRACKET", "[", { row, col, row, col + 1 }))
            advance()
        elseif c == "]" then
            table.insert(tokens, token("RBRACKET", "]", { row, col, row, col + 1 }))
            advance()
        elseif c == "{" then
            table.insert(tokens, token("LBRACE", "{", { row, col, row, col + 1 }))
            advance()
        elseif c == "}" then
            table.insert(tokens, token("RBRACE", "}", { row, col, row, col + 1 }))
            advance()
        elseif c == "=" then
            table.insert(tokens, token("EQUALS", "=", { row, col, row, col + 1 }))
            advance()
        elseif c == "," then
            table.insert(tokens, token("COMMA", ",", { row, col, row, col + 1 }))
            advance()
        elseif c == "." then
            table.insert(tokens, token("DOT", ".", { row, col, row, col + 1 }))
            advance()
        elseif c == '"' then
            local sr, sc = row, col

            advance()

            local val = ""
            local closed = false

            while i <= len do
                local nc = current()

                if nc == "\\" then
                    advance()

                    local esc = current()

                    if esc == '"' then
                        val = val .. '"'
                    elseif esc == "\\" then
                        val = val .. "\\"
                    else
                        val = val .. "\\" .. esc
                    end

                    advance()
                elseif nc == '"' then
                    closed = true
                    advance()
                    break
                elseif nc == "\n" then
                    break
                else
                    val = val .. nc
                    advance()
                end
            end

            if not closed then
                table.insert(errors, {
                    message = "Unterminated string",
                    range = { sr, sc, row, col },
                })
            else
                table.insert(tokens, token(
                    "STRING",
                    val,
                    { sr, sc, row, col }
                ))
            end
        else
            local sr, sc = row, col
            local start = i

            while i <= len and current():match("[%w%-%_]") do
                advance()
            end

            local val = text:sub(start, i - 1)

            if val == "" then
                table.insert(errors, {
                    message = "Unexpected character: " .. c,
                    range = { row, col, row, col + 1 },
                })

                advance()
            else
                local t

                if val == "true" then
                    t = token("BOOLEAN", true, { sr, sc, row, col })
                elseif val == "false" then
                    t = token("BOOLEAN", false, { sr, sc, row, col })
                elseif tonumber(val) then
                    t = token("NUMBER", tonumber(val), { sr, sc, row, col })
                else
                    t = token("IDENTIFIER", val, { sr, sc, row, col })
                end

                table.insert(tokens, t)
            end
        end
    end

    table.insert(tokens, token(
        "EOF",
        "",
        { row, col, row, col }
    ))

    return tokens, errors
end

local function parse(tokens)
    local idx = 1
    local errors = {}
    local node_counter = 0

    -- Create and prepare the tree instance
    local tree_ast = Tree.new()
    tree_ast:init()

    local function next_id()
        node_counter = node_counter + 1
        return "node_" .. tostring(node_counter)
    end

    local function peek(offset)
        return tokens[idx + (offset or 0)]
    end

    local function advance()
        local t = peek()
        if t and t.type ~= "EOF" then
            idx = idx + 1
        end
        return t
    end

    local function skip_trivia()
        while true do
            local t = peek()
            if not t then return end
            if t.type == "WHITESPACE" or t.type == "NEWLINE" then
                idx = idx + 1
            else
                return
            end
        end
    end

    local parse_value

    local function parse_array(open_tok)
        local items = {}
        advance() -- Consume '['

        while true do
            skip_trivia()
            local t = peek()

            if t and t.type == "COMMENT" then
                advance()
                t = peek()
            end

            if not t or t.type == "RBRACKET" or t.type == "EOF" then
                break
            end

            local val = parse_value()
            if val then
                table.insert(items, val)
            else
                table.insert(errors, {
                    message = "Expected value inside array",
                    range = t.range,
                })
                advance()
            end

            skip_trivia()
            local next_t = peek()
            if next_t and next_t.type == "COMMENT" then
                advance()
                next_t = peek()
            end

            if next_t and next_t.type == "COMMA" then
                advance()
            elseif next_t and next_t.type == "RBRACKET" then
                break
            elseif next_t and next_t.type ~= "EOF" then
                table.insert(errors, {
                    message = "Expected ',' or ']' inside array block structure",
                    range = next_t.range,
                })
                break
            end
        end

        local close_tok = peek()
        if close_tok and close_tok.type == "RBRACKET" then
            advance()
        else
            table.insert(errors, {
                message = "Expected closing ']' for array element context",
                range = close_tok and close_tok.range or open_tok.range,
            })
            close_tok = close_tok or token("RBRACKET", "]", open_tok.range)
        end

        return {
            kind = "Array",
            items = items,
            range = { open_tok.range[1], open_tok.range[2], close_tok.range[3], close_tok.range[4] },
        }
    end

    local function parse_inline_table(open_tok)
        local pairs = {}
        advance() -- Consume '{'

        while true do
            skip_trivia()
            local t = peek()
            if not t or t.type == "RBRACE" or t.type == "EOF" then
                break
            end

            if t.type ~= "IDENTIFIER" and t.type ~= "STRING" then
                table.insert(errors, {
                    message = "Expected inline table key definition entry",
                    range = t.range,
                })
                break
            end

            local k = advance()
            skip_trivia()

            local eq = peek()
            if not eq or eq.type ~= "EQUALS" then
                table.insert(errors, {
                    message = "Expected '=' tracking structural pairing assigner",
                    range = eq and eq.range or k.range,
                })
                break
            end
            advance()

            local v = parse_value()
            if not v then
                table.insert(errors, {
                    message = "Expected trailing mapping definition inside table element bounds",
                    range = eq.range,
                })
                break
            end

            table.insert(pairs, { key = k, value = v })

            skip_trivia()
            local next_t = peek()
            if next_t and next_t.type == "COMMA" then
                advance()
            elseif next_t and next_t.type == "RBRACE" then
                break
            elseif next_t and next_t.type ~= "EOF" then
                table.insert(errors, {
                    message = "Expected ',' or '}' delineator constraint tracking parameters",
                    range = next_t.range,
                })
                break
            end
        end

        local close_tok = peek()
        if close_tok and close_tok.type == "RBRACE" then
            advance()
        else
            table.insert(errors, {
                message = "Expected matching closing bracket '}' block structure component wrapper",
                range = close_tok and close_tok.range or open_tok.range,
            })
            close_tok = close_tok or token("RBRACE", "}", open_tok.range)
        end

        return {
            kind = "InlineTable",
            pairs = pairs,
            range = { open_tok.range[1], open_tok.range[2], close_tok.range[3], close_tok.range[4] },
        }
    end

    parse_value = function()
        skip_trivia()
        local t = peek()
        if not t then return nil end

        if t.type == "STRING" or t.type == "NUMBER" or t.type == "BOOLEAN" then
            advance()
            return {
                kind = "Literal",
                token = t,
                range = t.range,
            }
        elseif t.type == "LBRACKET" then
            return parse_array(t)
        elseif t.type == "LBRACE" then
            return parse_inline_table(t)
        end
        return nil
    end

    -- Tracks the active table section block container node ID for proper hierarchy nesting
    local current_container_id = nil

    while true do
        skip_trivia()
        local t = peek()

        if not t or t.type == "EOF" then break end

        if t.type == "COMMENT" then
            tree_ast:add_item(current_container_id, next_id(), {
                kind = "Comment",
                token = advance(),
            })

            -- [table]
        elseif t.type == "LBRACKET" then
            local open = advance()
            skip_trivia()

            local keys = {}
            while true do
                local kt = peek()
                if not kt or (kt.type ~= "IDENTIFIER" and kt.type ~= "STRING") then
                    break
                end

                table.insert(keys, advance())
                skip_trivia()

                local next_t = peek()
                if next_t and next_t.type == "DOT" then
                    advance()
                    skip_trivia()
                else
                    break
                end
            end

            local close = peek()
            local section_id = next_id()

            if close and close.type == "RBRACKET" then
                advance()
                tree_ast:add_item(nil, section_id, {
                    kind = "TableSection",
                    open_bracket = open,
                    keys = keys,
                    close_bracket = close,
                    range = { open.range[1], open.range[2], close.range[3], close.range[4] },
                })
            else
                -- Fault Tolerant Branch: User is actively typing inside a block bracket section header
                table.insert(errors, {
                    message = "Expected closing ']'",
                    range = close and close.range or open.range,
                })
                local end_t = peek(-1) or open
                tree_ast:add_item(nil, section_id, {
                    kind = "PartialTableSection",
                    open_bracket = open,
                    keys = keys,
                    range = { open.range[1], open.range[2], end_t.range[3], end_t.range[4] },
                })
            end

            -- Shift subsequent keys into this new container block section context scope
            current_container_id = section_id

            -- key = value OR active word key prefixes
        elseif t.type == "IDENTIFIER" or t.type == "STRING" then
            local key = advance()
            local save_idx = idx
            skip_trivia()

            local eq = peek()
            if not eq or eq.type ~= "EQUALS" then
                -- Fault Tolerant Branch: Captured a trailing context word before an equals operator assignment exists
                idx = save_idx -- Backtrack past spacing adjustments
                tree_ast:add_item(current_container_id, next_id(), {
                    kind = "PartialKeyValuePair",
                    key = key,
                    range = key.range,
                })
                goto continue
            end

            advance() -- Consume '='
            local value = parse_value()

            if value then
                tree_ast:add_item(current_container_id, next_id(), {
                    kind = "KeyValuePair",
                    key = key,
                    equals = eq,
                    value = value,
                    range = { key.range[1], key.range[2], value.range[3], value.range[4] },
                })
            else
                -- Fault Tolerant Branch: Empty value assignments (e.g. `foo = `)
                local end_t = peek(-1) or eq
                tree_ast:add_item(current_container_id, next_id(), {
                    kind = "KeyValuePair",
                    key = key,
                    equals = eq,
                    value = nil,
                    range = { key.range[1], key.range[2], end_t.range[3], end_t.range[4] },
                })
                table.insert(errors, {
                    message = "Expected value after '='",
                    range = eq.range,
                })
            end
        else
            table.insert(errors, {
                message = "Unexpected token: " .. t.type,
                range = t.range,
            })
            advance()
        end

        ::continue::
    end

    return tree_ast, errors
end

function M.parse(text)
    local tokens, lex_errors = tokenize(text)
    local tree_ast, parse_errors = parse(tokens)

    -- Combine errors but return ok = true so downstream LSP handlers can leverage the AST values
    local all_errors = {}
    vim.list_extend(all_errors, lex_errors)
    vim.list_extend(all_errors, parse_errors or {})

    return {
        ok = true,      -- Always true to bypass strict rejection block drop-outs
        ast = tree_ast, -- Complete bidirectional easytasks.utils.Tree instance object
        tokens = tokens,
        errors = all_errors,
    }
end

return M