-- easytasks/toml/parser.lua
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
      if t.zone == 0 then s = s .. "Z"
      elseif t.zone > 0 then s = s .. string.format("+%02d:00", t.zone)
      else s = s .. string.format("-%02d:00", -t.zone) end
    end
    return s
  end,
}

M._date_mt = date_mt

local function make_date(t) return setmetatable(t, date_mt) end
M.is_date = function(v) return type(v) == "table" and getmetatable(v) == date_mt end

local function utf8_encode(cp)
  if cp < 0x80 then return string.char(cp)
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

function M.parse(text)
  local errors = {}
  local ast = Tree:new()
  local cursor = 1
  local row, col = 0, 0
  local nid = 0

  local function next_id() nid = nid + 1; return nid end

  local function add_err(msg, r)
    table.insert(errors, { message = msg, range = r or { row, col, row, col } })
  end

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
        local c = text:sub(cursor, cursor)
        if c == "\n" then row = row + 1; col = 0
        elseif c ~= "\r" then col = col + 1 end
      end
      cursor = cursor + 1
    end
  end

  local function is_ws() local c = char(); return c == " " or c == "\t" end
  local function is_nl() return char() == "\n" or (char() == "\r" and char(1) == "\n") end

  local function skip_ws() while bounds() and is_ws() do step() end end

  local function skip_nl()
    if char() == "\r" then step() end
    if char() == "\n" then step() end
  end

  local function trim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end

  -- ===== value parsers =====

  local parse_value

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
          if char(1) == q and char(2) == q then step(3); closed = true; break end
        else
          step(); closed = true; break
        end
      end

      if not ml and is_nl() then add_err("Newline in single-line string"); break end

      if q == '"' and char() == "\\" then
        local nc = char(1)
        if ml and (nc == "\n" or (nc == "\r" and char(2) == "\n")) then
          step(); skip_nl()
          while bounds() and is_ws() do step() end
        else
          local esc = { b="\b", t="\t", n="\n", f="\f", r="\r", ['"']='"', ["\\"]="\\" }
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

  local function is_datetime_start() return ahead(10):match("^%d%d%d%d%-%d%d%-%d%d") ~= nil end
  local function is_time_start() return ahead(8):match("^%d%d:%d%d:%d%d") ~= nil end

  local function parse_datetime()
    local sr, sc = row, col
    local y = tonumber(ahead(4)); step(4); step() -- year, -
    local mo = tonumber(ahead(2)); step(2); step() -- month, -
    local d = tonumber(ahead(2)); step(2) -- day
    local h, mi, sec, zone

    if bounds() and (char() == "T" or char() == " ") then
      step()
      h = tonumber(ahead(2)); step(2); step() -- hour, :
      mi = tonumber(ahead(2)); step(2); step() -- min, :
      local ss = ""
      while bounds() and char():match("[%d%.]") do ss = ss .. char(); step() end
      sec = tonumber(ss) or 0

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

  local function parse_time()
    local sr, sc = row, col
    local h = tonumber(ahead(2)); step(2); step()
    local mi = tonumber(ahead(2)); step(2); step()
    local ss = ""
    while bounds() and char():match("[%d%.]") do ss = ss .. char(); step() end
    local er, ec = row, col
    local dv = make_date({ hour = h, min = mi, sec = tonumber(ss) or 0 })
    return { kind = "Literal", token = { value = dv, range = mkr(sr, sc, er, ec) }, range = mkr(sr, sc, er, ec) }
  end

  local function is_num_term()
    return not bounds() or is_ws() or is_nl()
      or char() == "#" or char() == "," or char() == "]" or char() == "}"
  end

  local function parse_number()
    local sr, sc = row, col
    local s = ""

    if char() == "+" or char() == "-" then s = s .. char(); step() end

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
      if c == "." then s = s .. c; step()
      elseif c:lower() == "e" then
        s = s .. c; step()
        if bounds() and (char() == "+" or char() == "-") then s = s .. char(); step() end
      elseif c == "_" then step()
      elseif c:match("[%d]") then s = s .. c; step()
      else break end
    end

    local er, ec = row, col
    local v = tonumber(s)
    if not v then add_err("Invalid number: " .. s); v = 0 end
    return { kind = "Literal", token = { value = v, range = mkr(sr, sc, er, ec) }, range = mkr(sr, sc, er, ec) }
  end

  local function parse_bool_special()
    local sr, sc = row, col
    local val, len
    if     ahead(5) == "false" then val = false;       len = 5
    elseif ahead(4) == "true"  then val = true;        len = 4
    elseif ahead(4) == "+inf"  then val = math.huge;   len = 4
    elseif ahead(4) == "-inf"  then val = -math.huge;  len = 4
    elseif ahead(3) == "inf"   then val = math.huge;   len = 3
    elseif ahead(4) == "+nan"  then val = 0 / 0;       len = 4
    elseif ahead(4) == "-nan"  then val = 0 / 0;       len = 4
    elseif ahead(3) == "nan"   then val = 0 / 0;       len = 3
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

  local function parse_array()
    local sr, sc = row, col
    step() -- [
    local items = {}

    while bounds() do
      skip_ws()
      if is_nl() then skip_nl()
      elseif char() == "#" then while bounds() and not is_nl() do step() end
      elseif char() == "]" then break
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

  local function parse_inline_table()
    local sr, sc = row, col
    step() -- {
    local pairs_list = {}
    skip_ws()

    while bounds() and char() ~= "}" do
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

      if char() ~= "=" then add_err("Expected = in inline table"); break end
      step(); skip_ws()
      if is_nl() then add_err("Newline in inline table"); break end

      local val = parse_value()
      table.insert(pairs_list, {
        key = { value = key_str, range = mkr(ks_r, ks_c, ke_r, ke_c) },
        value = val,
      })
      skip_ws()
      if char() == "," then step(); skip_ws() end
    end

    if char() ~= "}" then add_err("Missing } in inline table") else step() end
    local er, ec = row, col
    return { kind = "InlineTable", pairs = pairs_list, range = mkr(sr, sc, er, ec) }
  end

  function parse_value()
    if not bounds() then return nil end
    local c = char()
    if c == '"' or c == "'" then return parse_string()
    elseif is_datetime_start() then return parse_datetime()
    elseif is_time_start() then return parse_time()
    elseif c == "[" then return parse_array()
    elseif c == "{" then return parse_inline_table()
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

  local function parse_bare_key()
    local sr, sc = row, col
    local k = ""
    while bounds() and char():match("[A-Za-z0-9_%-]") do k = k .. char(); step() end
    local er, ec = row, col
    return { value = k, range = mkr(sr, sc, er, ec) }
  end

  local function parse_key_token()
    if char() == '"' or char() == "'" then
      local n = parse_string()
      return { value = n.token.value, range = n.range }
    end
    return parse_bare_key()
  end

  local function parse_key_list()
    local keys = {}
    while bounds() do
      skip_ws()
      local kt = parse_key_token()
      if kt.value == "" then add_err("Empty key segment"); break end
      table.insert(keys, kt)
      skip_ws()
      if char() == "." then step() else break end
    end
    return keys
  end

  -- ===== document-level loop =====

  local function read_trailing_comment()
    skip_ws()
    if char() ~= "#" then return nil end
    local text = ""
    while bounds() and not is_nl() do text = text .. char(); step() end
    return text
  end

  while bounds() do
    skip_ws()
    if not bounds() then break end

    if is_nl() then
      skip_nl()

    elseif char() == "#" then
      local sr, sc = row, col
      local ctext = ""
      while bounds() and not is_nl() do ctext = ctext .. char(); step() end
      local er, ec = row, col
      ast:add_item(nil, next_id(), { kind = "Comment", text = ctext, range = mkr(sr, sc, er, ec) })

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

      if char() ~= "]" then add_err("Missing ] in section header"); valid = false
      else step() end

      if is_aot then
        if char() ~= "]" then add_err("Missing ]] in array-of-tables header"); valid = false
        else step() end
      end

      local er, ec = row, col
      local kind
      if valid then
        kind = is_aot and "ArrayOfTablesSection" or "TableSection"
      else
        kind = is_aot and "PartialArrayOfTablesSection" or "PartialTableSection"
      end

      local trail = read_trailing_comment()
      ast:add_item(nil, next_id(), {
        kind = kind,
        keys = keys,
        trailing_comment = trail,
        range = mkr(sr, sc, er, ec),
      })
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
              pairs = {{ key = k, value = node_val }},
              range = node_val and node_val.range or mkr(sr, sc, er, ec),
            }
          end
        end

        local trail = read_trailing_comment()
        ast:add_item(nil, next_id(), {
          kind = "KeyValuePair",
          key = keys[1],
          value = node_val,
          trailing_comment = trail,
          range = mkr(sr, sc, er, ec),
        })
        if bounds() and is_nl() then skip_nl() end
      end
    end
  end

  return { ok = #errors == 0, ast = ast, errors = errors }
end

return M
