-- easytasks/toml/parser.lua

---@alias easytasks.toml.Range {[1]: integer, [2]: integer, [3]: integer, [4]: integer}

---@class easytasks.toml.ParseError
---@field message string
---@field range easytasks.toml.Range

---@class easytasks.toml.Date
---@field year integer?
---@field month integer?
---@field day integer?
---@field hour integer?
---@field min integer?
---@field sec number?
---@field zone integer?

---@class easytasks.toml.Token
---@field value any
---@field range easytasks.toml.Range

---@class easytasks.toml.KeyRef
---@field value string
---@field range easytasks.toml.Range

---@class easytasks.toml.Pair
---@field key easytasks.toml.KeyRef
---@field value easytasks.toml.ValueNode?

---@class easytasks.toml.LiteralNode
---@field kind "Literal"
---@field token easytasks.toml.Token
---@field range easytasks.toml.Range

---@class easytasks.toml.ArrayNode
---@field kind "Array"
---@field items easytasks.toml.ValueNode[]
---@field range easytasks.toml.Range

---@class easytasks.toml.InlineTableNode
---@field kind "InlineTable"
---@field pairs easytasks.toml.Pair[]
---@field range easytasks.toml.Range

---@alias easytasks.toml.ValueNode easytasks.toml.LiteralNode|easytasks.toml.ArrayNode|easytasks.toml.InlineTableNode

---@class easytasks.toml.KeyValuePairNode
---@field kind "KeyValuePair"
---@field key easytasks.toml.KeyRef
---@field value easytasks.toml.ValueNode
---@field trailing_comment string?
---@field range easytasks.toml.Range

---@class easytasks.toml.TableSectionNode
---@field kind "TableSection"|"PartialTableSection"
---@field keys easytasks.toml.KeyRef[]
---@field trailing_comment string?
---@field range easytasks.toml.Range

---@class easytasks.toml.ArrayOfTablesSectionNode
---@field kind "ArrayOfTablesSection"|"PartialArrayOfTablesSection"
---@field keys easytasks.toml.KeyRef[]
---@field trailing_comment string?
---@field range easytasks.toml.Range

---@class easytasks.toml.CommentNode
---@field kind "Comment"
---@field text string
---@field range easytasks.toml.Range

---@alias easytasks.toml.AstNode
---| easytasks.toml.KeyValuePairNode
---| easytasks.toml.TableSectionNode
---| easytasks.toml.ArrayOfTablesSectionNode
---| easytasks.toml.CommentNode

---@class easytasks.toml.NodeAtResult
---@field id integer
---@field node easytasks.toml.AstNode

---@class easytasks.toml.ParseResult
---@field ok boolean
---@field ast easytasks.util.Tree
---@field errors easytasks.toml.ParseError[]
---@field node_at fun(r: integer, c: integer): easytasks.toml.NodeAtResult?

local Tree = require("easytasks.util.Tree")
local M = {}

local date_mt = {
    __tostring = function(t)
        local s = ""
        if t.year then
            s = s .. string.format("%04d-%02d-%02d", t.year, t.month, t.day)
        end
        if t.hour then
            if t.year then s = s .. "T" end
            local si = math.floor(t.sec or 0)
            local sf = (t.sec or 0) - si
            s = s .. string.format("%02d:%02d:%02d", t.hour, t.min, si)
            if sf > 0 then s = s .. tostring(sf):sub(2) end
        end
        if t.zone ~= nil then
            if t.zone == 0 then
                s = s .. "Z"
            elseif t.zone > 0 then
                s = s .. string.format("+%02d:00", t.zone)
            else
                s = s .. string.format("-%02d:00", -t.zone)
            end
        end
        return s
    end,
}

---@type metatable
M._date_mt = date_mt

local function make_date(t) return setmetatable(t, date_mt) end

---@param v any
---@return boolean
M.is_date = function(v) return type(v) == "table" and getmetatable(v) == date_mt end

local function utf8_encode(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 4096),
            0x80 + math.floor(cp % 4096 / 64),
            0x80 + cp % 64)
    else
        return string.char(
            0xF0 + math.floor(cp / 262144),
            0x80 + math.floor(cp % 262144 / 4096),
            0x80 + math.floor(cp % 4096 / 64),
            0x80 + cp % 64)
    end
end

---@param text string
---@return easytasks.toml.ParseResult
function M.parse(text)
    local errors = {}
    local ast = Tree.new()
    local cursor = 1
    local row, col = 0, 0
    local nid = 0

    ---@return integer
    local function next_id()
        nid = nid + 1; return nid
    end

    ---@param msg string
    ---@param r easytasks.toml.Range?
    local function add_err(msg, r)
        table.insert(errors, { message = msg, range = r or { row, col, row, col } })
    end

    ---@param sr integer
    ---@param sc integer
    ---@param er integer
    ---@param ec integer
    ---@return easytasks.toml.Range
    local function mkr(sr, sc, er, ec) return { sr, sc, er, ec } end

    ---@param off integer?
    ---@return string
    local function char(off)
        local i = cursor + (off or 0)
        return i <= #text and text:sub(i, i) or ""
    end

    ---@param n integer
    ---@param off integer?
    ---@return string
    local function ahead(n, off)
        local s = cursor + (off or 0)
        return text:sub(s, s + n - 1)
    end

    ---@return boolean
    local function bounds() return cursor <= #text end

    ---@param n integer?
    local function step(n)
        n = n or 1
        for _ = 1, n do
            if cursor <= #text then
                local c = text:sub(cursor, cursor)
                if c == "\n" then
                    row = row + 1; col = 0
                elseif c ~= "\r" then
                    col = col + 1
                end
            end
            cursor = cursor + 1
        end
    end

    ---@return boolean
    local function is_ws()
        local c = char(); return c == " " or c == "\t"
    end

    ---@return boolean
    local function is_nl() return char() == "\n" or (char() == "\r" and char(1) == "\n") end

    local function skip_ws() while bounds() and is_ws() do step() end end

    local function skip_nl()
        if char() == "\r" then step() end
        if char() == "\n" then step() end
    end

    ---@param s string
    ---@return string
    local function trim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end

    -- ===== value parsers =====

    local parse_value

    ---@return easytasks.toml.LiteralNode
    local function parse_string()
        local sr, sc = row, col
        local q = char()
        local ml = char(1) == q and char(2) == q
        step(ml and 3 or 1)
        local s, closed = "", false

        while bounds() do
            if ml and s == "" and is_nl() then skip_nl() end

            if char() == q then
                if ml then
                    if char(1) == q and char(2) == q then
                        step(3); closed = true; break
                    end
                else
                    step(); closed = true; break
                end
            end

            if not ml and is_nl() then
                add_err("Newline in single-line string"); break
            end

            if q == '"' and char() == "\\" then
                local nc = char(1)
                if ml and (nc == "\n" or (nc == "\r" and char(2) == "\n")) then
                    step(); skip_nl()
                    while bounds() and is_ws() do step() end
                else
                    local esc = { b = "\b", t = "\t", n = "\n", f = "\f", r = "\r", e = "\x1b", ['"'] = '"', ["\\"] =
                    "\\" }
                    if esc[nc] then
                        s = s .. esc[nc]; step(2)
                    elseif nc == "u" then
                        step(2)
                        local cp = tonumber(ahead(4), 16); step(4)
                        if cp then s = s .. utf8_encode(cp) else add_err("Invalid unicode escape") end
                    elseif nc == "U" then
                        step(2)
                        local cp = tonumber(ahead(8), 16); step(8)
                        if cp then s = s .. utf8_encode(cp) else add_err("Invalid unicode escape") end
                    elseif nc == "x" then
                        step(2)
                        local cp = tonumber(ahead(2), 16); step(2)
                        if cp then s = s .. string.char(cp) else add_err("Invalid hex escape") end
                    else
                        add_err("Invalid escape: \\" .. nc); step()
                    end
                end
            else
                s = s .. char(); step()
            end
        end

        if not closed then add_err("Unterminated string") end
        local er, ec = row, col
        return { kind = "Literal", token = { value = s, range = mkr(sr, sc, er, ec) }, range = mkr(sr, sc, er, ec) }
    end

    ---@return boolean
    local function is_datetime_start() return ahead(10):match("^%d%d%d%d%-%d%d%-%d%d") ~= nil end

    ---@return boolean
    local function is_time_start() return ahead(5):match("^%d%d:%d%d") ~= nil end

    ---@return easytasks.toml.LiteralNode
    local function parse_datetime()
        local sr, sc = row, col
        local y = tonumber(ahead(4)); step(4); step()  -- year, -
        local mo = tonumber(ahead(2)); step(2); step() -- month, -
        local d = tonumber(ahead(2)); step(2)          -- day
        local h, mi, sec, zone

        if bounds() and (char() == "T" or char() == " ") then
            step()
            h = tonumber(ahead(2)); step(2); step() -- hour, :
            mi = tonumber(ahead(2)); step(2)        -- min
            sec = 0
            if bounds() and char() == ":" then
                step()
                local ss = ""
                while bounds() and char():match("[%d%.]") do
                    ss = ss .. char(); step()
                end
                sec = tonumber(ss) or 0
            end

            if bounds() and char() == "Z" then
                zone = 0; step()
            elseif bounds() and (char() == "+" or char() == "-") then
                local sign = char() == "+" and 1 or -1; step()
                local oh = tonumber(ahead(2)) or 0; step(2)
                if bounds() and char() == ":" then step() end
                if bounds() and char():match("%d") then step(2) end
                zone = sign * oh
            end
        end

        local er, ec = row, col
        local dv = make_date({ year = y, month = mo, day = d, hour = h, min = mi, sec = sec, zone = zone })
        return { kind = "Literal", token = { value = dv, range = mkr(sr, sc, er, ec) }, range = mkr(sr, sc, er, ec) }
    end

    ---@return easytasks.toml.LiteralNode
    local function parse_time()
        local sr, sc = row, col
        local h = tonumber(ahead(2)); step(2); step() -- hour, :
        local mi = tonumber(ahead(2)); step(2)        -- min
        local sec = 0
        if bounds() and char() == ":" then
            step()
            local ss = ""
            while bounds() and char():match("[%d%.]") do
                ss = ss .. char(); step()
            end
            sec = tonumber(ss) or 0
        end
        local er, ec = row, col
        local dv = make_date({ hour = h, min = mi, sec = sec })
        return { kind = "Literal", token = { value = dv, range = mkr(sr, sc, er, ec) }, range = mkr(sr, sc, er, ec) }
    end

    ---@return boolean
    local function is_num_term()
        return not bounds() or is_ws() or is_nl()
            or char() == "#" or char() == "," or char() == "]" or char() == "}"
    end

    ---@return easytasks.toml.LiteralNode
    local function parse_number()
        local sr, sc = row, col
        local s = ""

        if char() == "+" or char() == "-" then
            s = s .. char(); step()
        end

        if char() == "0" and (char(1) == "x" or char(1) == "o" or char(1) == "b") then
            local pfx = char(1); step(2)
            local bases = { x = 16, o = 8, b = 2 }
            local digits = ""
            while bounds() and not is_num_term() do
                if char() ~= "_" then digits = digits .. char() end; step()
            end
            if digits == "" then add_err("Empty based number") end
            local er, ec = row, col
            local v = tonumber(digits, bases[pfx]) or 0
            return { kind = "Literal", token = { value = v, range = mkr(sr, sc, er, ec) }, range = mkr(sr, sc, er, ec) }
        end

        while bounds() and not is_num_term() do
            local c = char()
            if c == "." then
                s = s .. c; step()
            elseif c:lower() == "e" then
                s = s .. c; step()
                if bounds() and (char() == "+" or char() == "-") then
                    s = s .. char(); step()
                end
            elseif c == "_" then
                step()
            elseif c:match("[%d]") then
                s = s .. c; step()
            else
                break
            end
        end

        local er, ec = row, col
        local v = tonumber(s)
        if not v then
            add_err("Invalid number: " .. s); v = 0
        end
        return { kind = "Literal", token = { value = v, range = mkr(sr, sc, er, ec) }, range = mkr(sr, sc, er, ec) }
    end

    ---@return easytasks.toml.LiteralNode
    local function parse_bool_special()
        local sr, sc = row, col
        local val, len
        if ahead(5) == "false" then
            val = false; len = 5
        elseif ahead(4) == "true" then
            val = true; len = 4
        elseif ahead(4) == "+inf" then
            val = math.huge; len = 4
        elseif ahead(4) == "-inf" then
            val = -math.huge; len = 4
        elseif ahead(3) == "inf" then
            val = math.huge; len = 3
        elseif ahead(4) == "+nan" then
            val = 0 / 0; len = 4
        elseif ahead(4) == "-nan" then
            val = 0 / 0; len = 4
        elseif ahead(3) == "nan" then
            val = 0 / 0; len = 3
        else
            add_err("Unexpected value near: " .. ahead(8))
            while bounds() and not is_num_term() do step() end
            local er, ec = row, col
            return { kind = "Literal", token = { value = nil, range = mkr(sr, sc, er, ec) }, range = mkr(sr, sc, er, ec) }
        end
        step(len)
        local er, ec = row, col
        return { kind = "Literal", token = { value = val, range = mkr(sr, sc, er, ec) }, range = mkr(sr, sc, er, ec) }
    end

    ---@return easytasks.toml.ArrayNode
    local function parse_array()
        local sr, sc = row, col
        step() -- [
        local items = {}

        while bounds() do
            skip_ws()
            if is_nl() then
                skip_nl()
            elseif char() == "#" then
                while bounds() and not is_nl() do step() end
            elseif char() == "]" then
                break
            else
                local item = parse_value()
                if item then table.insert(items, item) end
                skip_ws()
                if char() == "," then step() end
            end
        end

        if char() ~= "]" then add_err("Missing ] in array") else step() end
        local er, ec = row, col
        return { kind = "Array", items = items, range = mkr(sr, sc, er, ec) }
    end

    ---@return easytasks.toml.InlineTableNode
    local function parse_inline_table()
        local sr, sc = row, col
        step() -- {
        local pairs_list = {}

        while bounds() and char() ~= "}" do
            -- TOML 1.1: whitespace and newlines are allowed between pairs
            while bounds() and (is_ws() or is_nl()) do
                if is_nl() then skip_nl() else step() end
            end
            if not bounds() or char() == "}" then break end

            local ks_r, ks_c = row, col
            local key_str
            if char() == '"' or char() == "'" then
                local kn = parse_string(); key_str = kn.token.value
            else
                key_str = ""
                while bounds() and char() ~= "=" and char() ~= "." and not is_ws() and not is_nl() and char() ~= "}" do
                    key_str = key_str .. char(); step()
                end
                key_str = trim(key_str)
            end
            local ke_r, ke_c = row, col
            skip_ws()

            if char() ~= "=" then
                add_err("Expected = in inline table"); break
            end
            step()
            -- TOML 1.1: whitespace and newlines allowed after =
            while bounds() and (is_ws() or is_nl()) do
                if is_nl() then skip_nl() else step() end
            end

            local val = parse_value()
            table.insert(pairs_list, {
                key = { value = key_str, range = mkr(ks_r, ks_c, ke_r, ke_c) },
                value = val,
            })
            -- TOML 1.1: trailing comma and newlines allowed after value
            while bounds() and (is_ws() or is_nl()) do
                if is_nl() then skip_nl() else step() end
            end
            if char() == "," then
                step()
                while bounds() and (is_ws() or is_nl()) do
                    if is_nl() then skip_nl() else step() end
                end
            end
        end

        if char() ~= "}" then add_err("Missing } in inline table") else step() end
        local er, ec = row, col
        return { kind = "InlineTable", pairs = pairs_list, range = mkr(sr, sc, er, ec) }
    end

    ---@return easytasks.toml.ValueNode?
    function parse_value()
        if not bounds() then return nil end
        local c = char()
        if c == '"' or c == "'" then
            return parse_string()
        elseif is_datetime_start() then
            return parse_datetime()
        elseif is_time_start() then
            return parse_time()
        elseif c == "[" then
            return parse_array()
        elseif c == "{" then
            return parse_inline_table()
        elseif c:match("[%+%-0-9]") then
            local a4 = ahead(4)
            if a4 == "+inf" or a4 == "-inf" or a4 == "+nan" or a4 == "-nan" then
                return parse_bool_special()
            end
            return parse_number()
        else
            return parse_bool_special()
        end
    end

    -- ===== key parsing =====

    -- TOML 1.1: bare keys may include Unicode letters/numbers (any byte >= 0x80),
    -- except combining marks U+0300-U+036F (bytes CC:80-CD:AF) as the first character.
    ---@return boolean
    local function is_bare_key_start()
        local b = char():byte()
        if not b then return false end
        if (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) or
            (b >= 0x30 and b <= 0x39) or b == 0x5F or b == 0x2D then
            return true
        end
        if b >= 0x80 then
            -- exclude U+0300-U+036F (combining marks) as first char
            if b == 0xCC then
                local b2 = char(1):byte(); if b2 and b2 >= 0x80 then return false end
            elseif b == 0xCD then
                local b2 = char(1):byte(); if b2 and b2 <= 0xAF then return false end
            end
            return true
        end
        return false
    end

    ---@return boolean
    local function is_bare_key_cont()
        local b = char():byte()
        if not b then return false end
        if (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) or
            (b >= 0x30 and b <= 0x39) or b == 0x5F or b == 0x2D then
            return true
        end
        return b >= 0x80
    end

    ---@return easytasks.toml.KeyRef
    local function parse_bare_key()
        local sr, sc = row, col
        local k = ""
        if bounds() and is_bare_key_start() then
            k = k .. char(); step()
            while bounds() and is_bare_key_cont() do
                k = k .. char(); step()
            end
        end
        local er, ec = row, col
        return { value = k, range = mkr(sr, sc, er, ec) }
    end

    ---@return easytasks.toml.KeyRef
    local function parse_key_token()
        if char() == '"' or char() == "'" then
            local n = parse_string()
            return { value = n.token.value, range = n.range }
        end
        return parse_bare_key()
    end

    ---@return easytasks.toml.KeyRef[]
    local function parse_key_list()
        local keys = {}
        while bounds() do
            skip_ws()
            local kt = parse_key_token()
            if kt.value == "" then
                add_err("Empty key segment"); break
            end
            table.insert(keys, kt)
            skip_ws()
            if char() == "." then step() else break end
        end
        return keys
    end

    -- ===== document-level loop =====

    ---@return string?
    local function read_trailing_comment()
        skip_ws()
        if char() ~= "#" then return nil end
        local cmt = ""
        while bounds() and not is_nl() do
            cmt = cmt .. char(); step()
        end
        return cmt
    end

    -- Recursively add inline-table pairs and array-of-inline-table items as Tree
    -- children so the full value structure is visible in the tree.
    local expand_value
    expand_value = function(parent_id, value_node)
        if not value_node then return end
        if value_node.kind == "InlineTable" then
            for _, pair in ipairs(value_node.pairs) do
                local pair_id = next_id()
                ast:add_item(parent_id, pair_id, {
                    kind = "KeyValuePair",
                    key = pair.key,
                    value = pair.value,
                    range = pair.key.range,
                })
                expand_value(pair_id, pair.value)
            end
        elseif value_node.kind == "Array" then
            for _, item in ipairs(value_node.items) do
                expand_value(parent_id, item)
            end
        end
    end

    -- nil means top-level (before any section header)
    local current_section_id = nil

    while bounds() do
        skip_ws()
        if not bounds() then break end

        if is_nl() then
            skip_nl()
        elseif char() == "#" then
            local sr, sc = row, col
            local ctext = ""
            while bounds() and not is_nl() do
                ctext = ctext .. char(); step()
            end
            local er, ec = row, col
            ast:add_item(current_section_id, next_id(), { kind = "Comment", text = ctext, range = mkr(sr, sc, er, ec) })
        elseif char() == "[" then
            local sr, sc = row, col
            step() -- first [
            local is_aot = char() == "["
            if is_aot then step() end
            skip_ws()

            local keys, valid = {}, true

            while bounds() and char() ~= "]" and not is_nl() do
                skip_ws()
                if char() == "]" then break end
                if char() == '"' or char() == "'" then
                    local kn = parse_string()
                    table.insert(keys, { value = kn.token.value, range = kn.range })
                elseif char() == "." then
                    step()
                else
                    local kt = parse_bare_key()
                    if kt.value ~= "" then table.insert(keys, kt) end
                    skip_ws()
                    if char() == "." then step() end
                end
            end

            if char() ~= "]" then
                add_err("Missing ] in section header"); valid = false
            else
                step()
            end

            if is_aot then
                if char() ~= "]" then
                    add_err("Missing ]] in array-of-tables header"); valid = false
                else
                    step()
                end
            end

            local er, ec = row, col
            local kind
            if valid then
                kind = is_aot and "ArrayOfTablesSection" or "TableSection"
            else
                kind = is_aot and "PartialArrayOfTablesSection" or "PartialTableSection"
            end

            local trail = read_trailing_comment()
            local section_id = next_id()
            ast:add_item(nil, section_id, {
                kind = kind,
                keys = keys,
                trailing_comment = trail,
                range = mkr(sr, sc, er, ec),
            })
            current_section_id = section_id
            if bounds() and is_nl() then skip_nl() end
        else
            -- key = value
            local sr, sc = row, col
            local keys = parse_key_list()
            skip_ws()

            if char() ~= "=" then
                add_err("Expected = after key")
                while bounds() and not is_nl() do step() end
                if bounds() then skip_nl() end
            else
                step() -- =
                skip_ws()
                local val = parse_value()
                local er, ec = row, col

                -- Expand dotted keys: a.b.c = v → a = { b = { c = v } }
                local node_val = val
                if #keys > 1 then
                    for i = #keys, 2, -1 do
                        local k = keys[i]
                        node_val = {
                            kind = "InlineTable",
                            pairs = { { key = k, value = node_val } },
                            range = node_val and node_val.range or mkr(sr, sc, er, ec),
                        }
                    end
                end

                local trail = read_trailing_comment()
                local kvp_id = next_id()
                ast:add_item(current_section_id, kvp_id, {
                    kind = "KeyValuePair",
                    key = keys[1],
                    value = node_val,
                    trailing_comment = trail,
                    range = mkr(sr, sc, er, ec),
                })
                expand_value(kvp_id, node_val)
                if bounds() and is_nl() then skip_nl() end
            end
        end
    end

    local function pos_in_range(r, c, range)
        local sr, sc, er, ec = range[1], range[2], range[3], range[4]
        if r < sr or r > er then return false end
        if r == sr and c < sc then return false end
        if r == er and c > ec then return false end
        return true
    end

    local function node_at(r, c)
        local result = nil
        ast:walk_tree(function(id, data, _)
            if data and data.range and pos_in_range(r, c, data.range) then
                result = { id = id, node = data }
            end
            return true
        end)
        return result
    end

    return { ok = #errors == 0, ast = ast, errors = errors, node_at = node_at }
end

return M
