---@alias easytasks.toml.Range {[1]: integer, [2]: integer, [3]: integer, [4]: integer}

---@class easytasks.toml.ParseError
---@field message string
---@field range easytasks.toml.Range

---@class easytasks.toml.ParseResult
---@field ok boolean
---@field ast easytasks.toml.Ast
---@field errors easytasks.toml.ParseError[]

local Ast      = require("easytasks.toml.Ast")
local util    = require("easytasks.toml.parser_util")
local NodeKind = util.NodeKind

local M        = {}

local function format_date_str(y, mo, d, h, mi, sec, zone)
    local s = string.format("%04d-%02d-%02d", y, mo, d)
    if h ~= nil then
        local si = math.floor(sec or 0)
        local sf = (sec or 0) - si
        s = s .. "T" .. string.format("%02d:%02d:%02d", h, mi, si)
        if sf > 0 then s = s .. tostring(sf):sub(2) end
        if zone ~= nil then
            if zone == 0 then
                s = s .. "Z"
            else
                s = s .. string.format("%+03d:00", zone)
            end
        end
    end
    return s
end

local function format_time_str(h, mi, sec)
    local si = math.floor(sec or 0)
    local sf = (sec or 0) - si
    local s = string.format("%02d:%02d:%02d", h, mi, si)
    if sf > 0 then s = s .. tostring(sf):sub(2) end
    return s
end

local function utf8_encode(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp % 4096 / 64), 0x80 + cp % 64)
    else
        return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp % 262144 / 4096),
            0x80 + math.floor(cp % 4096 / 64), 0x80 + cp % 64)
    end
end

function M.parse(text)
    local errors   = {}
    local ast      = Ast.new()
    local cursor   = 1
    local row, col = 0, 0
    local nid      = 0

    local function next_id()
        nid = nid + 1; return nid
    end
    local function add_err(msg, r) table.insert(errors, { message = msg, range = r or { row, col, row, col } }) end
    local function mkr(sr, sc, er, ec) return { sr, sc, er, ec } end

    local function char(off)
        local i = cursor + (off or 0)
        return i <= #text and text:sub(i, i) or ""
    end

    local function ahead(n, off)
        local s = cursor + (off or 0)
        return text:sub(s, s + n - 1)
    end

    local function bounds() return cursor <= #text end

    local function step(n)
        n = n or 1
        for _ = 1, n do
            if cursor <= #text then
                local c = text:byte(cursor)
                if c == 10 then
                    row = row + 1; col = 0
                elseif c ~= 13 then
                    col = col + 1
                end
            end
            cursor = cursor + 1
        end
    end

    local function is_ws()
        local c = char(); return c == " " or c == "\t"
    end
    local function is_comment_ctrl()
        local b = char():byte()
        return b and (b < 0x09 or (b > 0x09 and b < 0x20) or b == 0x7F)
    end
    local function is_nl() return char() == "\n" or (char() == "\r" and char(1) == "\n") end
    local function skip_ws() while bounds() and is_ws() do step() end end
    local function skip_nl()
        if char() == "\r" then step() end; if char() == "\n" then step() end
    end

    local function skip_wcn()
        while bounds() do
            if is_ws() then
                step()
            elseif is_nl() then
                skip_nl()
            elseif char() == "#" then
                while bounds() and not is_nl() do
                    if is_comment_ctrl() then add_err("Control character in comment") end
                    step()
                end
            else
                break
            end
        end
    end

    -- ===== value parsers =====
    local parse_value, parse_key_token

    local function parse_string()
        local sr, sc = row, col
        local q = char()
        local ml = char(1) == q and char(2) == q
        step(ml and 3 or 1)

        local buf, closed = {}, false
        local esc = { b = "\b", t = "\t", n = "\n", f = "\f", r = "\r", e = "\x1b", ['"'] = '"', ["\\"] = "\\" }

        while bounds() do
            if ml and #buf == 0 and is_nl() then skip_nl() end
            if char() == q then
                if ml then
                    if char(1) == q and char(2) == q then
                        if char(3) == q then
                            table.insert(buf, q)
                            if char(4) == q then
                                table.insert(buf, q)
                                step(5)
                            else
                                step(4)
                            end
                        else
                            step(3)
                        end
                        closed = true; break
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
                local j = 1
                while char(j) == " " or char(j) == "\t" do j = j + 1 end
                if ml and (char(j) == "\n" or (char(j) == "\r" and char(j + 1) == "\n")) then
                    step(j); skip_nl()
                    while bounds() do
                        if is_ws() then
                            step()
                        elseif is_nl() then
                            skip_nl()
                        else
                            break
                        end
                    end
                else
                    if esc[nc] then
                        table.insert(buf, esc[nc]); step(2)
                    elseif nc == "u" or nc == "U" or nc == "x" then
                        local len = nc == "u" and 4 or (nc == "U" and 8 or 2)
                        step(2)
                        local cp = tonumber(ahead(len), 16); step(len)
                        if cp then
                            table.insert(buf, utf8_encode(cp))
                        else
                            add_err("Invalid escape sequence")
                        end
                    else
                        add_err("Invalid escape: \\" .. nc); step()
                    end
                end
            else
                local b = char():byte()
                if b ~= nil and (b == 0x7F or (b < 0x20 and b ~= 0x09 and
                        not (ml and (b == 0x0A or (b == 0x0D and char(1) == "\n"))))) then
                    add_err("Control character in string")
                end
                table.insert(buf, char()); step()
            end
        end

        if not closed then add_err("Unterminated string") end
        local er, ec = row, col
        local s = table.concat(buf)
        return {
            kind = NodeKind.Literal,
            token = { value = s, literalkind = "string", range = mkr(sr, sc, er, ec) },
            range =
                mkr(sr, sc, er, ec)
        }
    end

    local function is_datetime_start() return ahead(10):match("^%d%d%d%d%-%d%d%-%d%d") ~= nil end
    local function is_time_start() return ahead(5):match("^%d%d:%d%d") ~= nil end

    local function parse_datetime()
        local sr, sc = row, col
        local y = tonumber(ahead(4)); step(5)
        local mo = tonumber(ahead(2)); step(3)
        local d = tonumber(ahead(2)); step(2)
        local h, mi, sec, zone

        if bounds() and (char():lower() == "t" or (char() == " " and ahead(3, 1):match("^%d%d:"))) then
            step()
            h = tonumber(ahead(2)); step(3)
            mi = tonumber(ahead(2)); step(2)
            sec = 0
            if bounds() and char() == ":" then
                step()
                local ss = {}
                while bounds() and char():match("[%d%.]") do
                    table.insert(ss, char()); step()
                end
                local sec_str = table.concat(ss)
                if sec_str:match("%.$") then add_err("Invalid seconds: trailing dot") end
                sec = tonumber(sec_str) or 0
            end

            if bounds() and char():lower() == "z" then
                zone = 0; step()
            elseif bounds() and (char() == "+" or char() == "-") then
                local sign = char() == "+" and 1 or -1; step()
                if not ahead(2):match("^%d%d$") then
                    add_err("Invalid timezone offset: expected 2-digit hour"); zone = 0
                else
                    local oh = tonumber(ahead(2)); step(2)
                    if char() ~= ":" then
                        add_err("Invalid timezone offset: expected ':'"); zone = sign * oh
                    else
                        step()
                        if not ahead(2):match("^%d%d$") then
                            add_err("Invalid timezone offset: expected 2-digit minute"); zone = sign * oh
                        else
                            local om = tonumber(ahead(2)); step(2)
                            local tz_err = util.validate_offset(oh, om)
                            if tz_err then add_err(tz_err) end
                            zone = sign * oh
                        end
                    end
                end
            end
        end

        local date_err = util.validate_date(y, mo, d)
        if date_err then add_err(date_err) end
        if h ~= nil then
            local time_err = util.validate_time(h, mi, sec)
            if time_err then add_err(time_err) end
        end

        local er, ec = row, col
        local lkind = h ~= nil and (zone ~= nil and "datetime" or "datetime-local") or "date-local"
        return {
            kind = NodeKind.Literal,
            token = { value = format_date_str(y, mo, d, h, mi, sec, zone), literalkind = lkind, range = mkr(sr, sc, er, ec) },
            range =
                mkr(sr, sc, er, ec)
        }
    end

    local function parse_time()
        local sr, sc = row, col
        local h = tonumber(ahead(2)); step(3)
        local mi = tonumber(ahead(2)); step(2)
        local sec = 0
        if bounds() and char() == ":" then
            step()
            local ss = {}
            while bounds() and char():match("[%d%.]") do
                table.insert(ss, char()); step()
            end
            sec = tonumber(table.concat(ss)) or 0
        end
        local time_err = util.validate_time(h, mi, sec)
        if time_err then add_err(time_err) end

        local er, ec = row, col
        return {
            kind = NodeKind.Literal,
            token = { value = format_time_str(h, mi, sec), literalkind = "time-local", range = mkr(sr, sc, er, ec) },
            range =
                mkr(sr, sc, er, ec)
        }
    end

    local function is_num_term()
        if not bounds() then return true end
        local c = char()
        return c == " " or c == "\t" or c == "\n" or c == "\r" or c == "#" or c == "," or c == "]" or c == "}"
    end

    local function parse_number()
        local sr, sc = row, col
        local s_buf, raw_buf = {}, {}

        if char() == "+" or char() == "-" then
            table.insert(s_buf, char())
            table.insert(raw_buf, char())
            step()
        end

        if char() == "0" and (char(1) == "x" or char(1) == "o" or char(1) == "b") then
            local pfx = char(1)
            table.insert(raw_buf, ahead(2))
            step(2)
            local bases = { x = 16, o = 8, b = 2 }
            local dig_buf = {}
            while bounds() and not is_num_term() do
                table.insert(raw_buf, char())
                if char() ~= "_" then table.insert(dig_buf, char()) end
                step()
            end
            if #dig_buf == 0 then add_err("Empty based number") end
            local er, ec = row, col
            local v = tonumber(table.concat(dig_buf), bases[pfx]) or 0
            if table.concat(s_buf) == "-" and v ~= 0 then v = -v end
            return {
                kind = NodeKind.Literal,
                token = { value = v, raw = table.concat(raw_buf), literalkind = "integer", range = mkr(sr, sc, er, ec) },
                range =
                    mkr(sr, sc, er, ec)
            }
        end

        while bounds() and not is_num_term() do
            local c = char()
            table.insert(raw_buf, c)
            if c == "." or c:match("%d") then
                table.insert(s_buf, c); step()
            elseif c:lower() == "e" then
                table.insert(s_buf, c); step()
                if bounds() and (char() == "+" or char() == "-") then
                    table.insert(s_buf, char())
                    table.insert(raw_buf, char())
                    step()
                end
            elseif c == "_" then
                step()
            else
                break
            end
        end

        local er, ec = row, col
        local s = table.concat(s_buf)
        local lkind = s:find("[%.eE]") and "float" or "integer"
        local v = tonumber(s) or 0

        if lkind == "integer" then
            if v == 0 then v = 0 end
            return {
                kind = NodeKind.Literal,
                token = { value = v, raw = table.concat(raw_buf):gsub("_", ""), literalkind = lkind, range = mkr(sr, sc, er, ec) },
                range =
                    mkr(sr, sc, er, ec)
            }
        end

        return {
            kind = NodeKind.Literal,
            token = { value = v, literalkind = lkind, range = mkr(sr, sc, er, ec) },
            range =
                mkr(sr, sc, er, ec)
        }
    end

    local function parse_bool_special()
        local sr, sc = row, col
        local matches = {
            ["false"] = { false, 5, "bool" },
            ["true"] = { true, 4, "bool" },
            ["+inf"] = { math.huge, 4, "float" },
            ["-inf"] = { -math.huge, 4, "float" },
            ["inf"] = { math.huge, 3, "float" },
            ["+nan"] = { 0 / 0, 4, "float" },
            ["-nan"] = { 0 / 0, 4, "float" },
            ["nan"] = { 0 / 0, 3, "float" }
        }

        for k, v in pairs(matches) do
            if ahead(#k) == k then
                step(v[2])
                local er, ec = row, col
                return {
                    kind = NodeKind.Literal,
                    token = { value = v[1], literalkind = v[3], range = mkr(sr, sc, er, ec) },
                    range =
                        mkr(sr, sc, er, ec)
                }
            end
        end

        add_err("Unexpected value near: " .. ahead(8))
        while bounds() and not is_num_term() do step() end
        local er, ec = row, col
        return {
            kind = NodeKind.Literal,
            token = { value = nil, range = mkr(sr, sc, er, ec) },
            range = mkr(sr, sc, er,
                ec)
        }
    end

    local function parse_array()
        local sr, sc = row, col
        step() -- [
        local items = {}

        while bounds() do
            skip_wcn()
            if char() == "]" then break end
            local before = cursor
            local item = parse_value()
            if item then table.insert(items, item) end
            if cursor == before then
                add_err("Unexpected character in array: " .. char()); step()
            else
                skip_wcn()
                if char() == "," then
                    step()
                elseif char() ~= "]" then
                    add_err("Missing , between array elements")
                end
            end
        end

        local multiline = row ~= sr
        if char() ~= "]" then add_err("Missing ] in array") else step() end
        local er, ec = row, col
        return { kind = NodeKind.Array, items = items, multiline = multiline, range = mkr(sr, sc, er, ec) }
    end

    local function merge_inline_table_pairs(existing_pairs, new_key, new_value)
        for _, pair in ipairs(existing_pairs) do
            if pair.key.value == new_key.value then
                if pair.value and pair.value.kind == NodeKind.InlineTable and new_value and new_value.kind == NodeKind.InlineTable then
                    for _, incoming in ipairs(new_value.pairs) do
                        merge_inline_table_pairs(pair.value.pairs, incoming.key, incoming.value)
                    end
                    return
                end
            end
        end
        table.insert(existing_pairs, { key = new_key, value = new_value })
    end

    local function parse_inline_table()
        local sr, sc = row, col
        step() -- {
        local pairs_list = {}

        while bounds() do
            skip_wcn()
            if char() == "]" or char() == "}" then break end

            local ks_r, ks_c = row, col
            local key_parts = {}

            while bounds() do
                skip_wcn()
                local kt = parse_key_token()
                if kt.is_empty and not kt.quoted then
                    add_err("Empty key segment in inline table"); break
                end
                table.insert(key_parts, kt)
                skip_wcn()
                if char() == "." then step() else break end
            end

            if #key_parts == 0 then break end
            local ke_r, ke_c = row, col

            skip_wcn()
            if char() ~= "=" then
                add_err("Expected = in inline table"); break
            end
            step()
            skip_wcn()

            local val = parse_value()

            for i = #key_parts, 2, -1 do
                val = {
                    kind = NodeKind.InlineTable,
                    pairs = { { key = key_parts[i], value = val } },
                    multiline = false,
                    range = val and val.range or mkr(ks_r, ks_c, ke_r, ke_c),
                }
            end

            merge_inline_table_pairs(pairs_list, key_parts[1], val)

            skip_wcn()
            if char() == "," then step() elseif char() == "}" then break else break end
        end

        local multiline = row ~= sr
        if char() ~= "}" then add_err("Missing } in inline table") else step() end
        local er, ec = row, col
        return { kind = NodeKind.InlineTable, pairs = pairs_list, multiline = multiline, range = mkr(sr, sc, er, ec) }
    end

    function parse_value()
        if not bounds() then return nil end
        local c = char()
        if c == '"' or c == "'" then return parse_string() end
        if is_datetime_start() then return parse_datetime() end
        if is_time_start() then return parse_time() end
        if c == "[" then return parse_array() end
        if c == "{" then return parse_inline_table() end
        if c:match("[%+%-0-9]") then
            local a4 = ahead(4)
            if a4 == "+inf" or a4 == "-inf" or a4 == "+nan" or a4 == "-nan" then return parse_bool_special() end
            return parse_number()
        end
        return parse_bool_special()
    end

    -- ===== key parsing =====
    local function is_bare_key_char()
        return char():match("[%w%-_]") ~= nil
    end

    local function parse_bare_key()
        local sr, sc = row, col
        local buf = {}
        while bounds() and is_bare_key_char() do
            table.insert(buf, char())
            step()
        end
        local er, ec = row, col
        local s = table.concat(buf)
        return { value = s, is_empty = (s == ""), quoted = false, range = mkr(sr, sc, er, ec) }
    end

    function parse_key_token()
        local c = char()
        if c == '"' or c == "'" then
            local n = parse_string()
            return { value = n.token.value, is_empty = false, quoted = true, range = n.range }
        end
        return parse_bare_key()
    end

    local function parse_key_list()
        local keys = {}
        while bounds() do
            skip_ws()
            local kt = parse_key_token()
            if kt.is_empty and not kt.quoted then
                add_err("Empty key segment"); break
            end
            table.insert(keys, kt)
            skip_ws()
            if char() == "." then step() else break end
        end
        return keys
    end

    -- ===== document loop =====
    local function read_trailing_comment()
        skip_ws()
        if char() ~= "#" then return nil end
        local buf = {}
        while bounds() and not is_nl() do
            if is_comment_ctrl() then add_err("Control character in comment") end
            table.insert(buf, char()); step()
        end
        return table.concat(buf)
    end

    local expand_value
    expand_value = function(parent_id, value_node)
        if not value_node then return end
        if value_node.kind == NodeKind.InlineTable then
            for _, pair in ipairs(value_node.pairs) do
                local pair_id = next_id()
                ast:add_item(parent_id, pair_id,
                    { kind = NodeKind.KeyValuePair, key = pair.key, value = pair.value, range = pair.key.range })
                expand_value(pair_id, pair.value)
            end
        elseif value_node.kind == NodeKind.Array then
            for _, item in ipairs(value_node.items) do expand_value(parent_id, item) end
        end
    end

    local current_section_id = nil

    while bounds() do
        skip_ws()
        if not bounds() then break end

        if is_nl() then
            skip_nl()
        elseif char() == "#" then
            local sr, sc = row, col
            local buf = {}
            while bounds() and not is_nl() do
                if is_comment_ctrl() then add_err("Control character in comment") end
                table.insert(buf, char()); step()
            end
            ast:add_item(current_section_id, next_id(),
                { kind = NodeKind.Comment, text = table.concat(buf), range = mkr(sr, sc, row, col) })
        elseif char() == "[" then
            local sr, sc = row, col
            step()
            local is_aot = char() == "["
            if is_aot then step() end
            skip_ws()

            local keys, valid = {}, true
            while bounds() and char() ~= "]" and not is_nl() do
                skip_ws()
                if char() == "]" then break end
                local kt = parse_key_token()
                if kt.is_empty and not kt.quoted then
                    add_err("Unexpected character in section header: " .. char())
                    step()
                else
                    table.insert(keys, kt)
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

            local kind = valid and (is_aot and NodeKind.ArrayOfTablesSection or NodeKind.TableSection) or
                (is_aot and NodeKind.PartialArrayOfTablesSection or NodeKind.PartialTableSection)
            local section_id = next_id()
            ast:add_item(nil, section_id,
                { kind = kind, keys = keys, trailing_comment = read_trailing_comment(), range = mkr(sr, sc, row, col) })
            current_section_id = section_id
            if bounds() and is_nl() then skip_nl() end
        else
            local sr, sc = row, col
            local keys = parse_key_list()
            skip_ws()

            if #keys == 0 or (keys[1].is_empty and not keys[1].quoted) then
                add_err("Empty key segment")
                while bounds() and not is_nl() do step() end
                if bounds() then skip_nl() end
            elseif char() ~= "=" then
                add_err("Expected = after key")
                while bounds() and not is_nl() do step() end
                if bounds() then skip_nl() end
            else
                step()
                skip_ws()
                local val = parse_value()

                local node_val = val
                if #keys > 1 then
                    for i = #keys, 2, -1 do
                        node_val = {
                            kind = NodeKind.InlineTable,
                            pairs = { { key = keys[i], value = node_val } },
                            multiline = false,
                            range = node_val and node_val.range or mkr(sr, sc, row, col)
                        }
                    end
                end

                local kvp_id = next_id()
                ast:add_item(current_section_id, kvp_id,
                    {
                        kind = NodeKind.KeyValuePair,
                        key = keys[1],
                        value = node_val,
                        trailing_comment =
                            read_trailing_comment(),
                        range = mkr(sr, sc, row, col)
                    })
                expand_value(kvp_id, node_val)
                if bounds() and is_nl() then skip_nl() end
            end
        end
    end

    return { ok = #errors == 0, ast = ast, errors = errors }
end

return M
