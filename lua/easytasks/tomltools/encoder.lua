local table_util = require("tomltools.table_util")
local std        = require("tomltools.std")

local M = {}

M.ordered = table_util.ordered

--- Wrap a pre-formatted TOML scalar so the encoder emits it verbatim.
---@param s string
---@return table
function M.raw(s)
    return setmetatable({}, { _toml_raw = s })
end

--- Returns the verbatim string if v was created with M.raw(), otherwise nil.
---@param v any
---@return string?
local function raw_value(v)
    if type(v) ~= "table" then return nil end
    local mt = getmetatable(v)
    return mt and type(mt._toml_raw) == "string" and mt._toml_raw or nil
end


---@param key string
---@return boolean
local function needs_quotes(key)
    return not key:match("^[A-Za-z0-9_%-]+$")
end

-- Escape a string's content for use inside a TOML basic string (double-quoted).
---@param s string
---@return string
local function escape_basic(s)
    local parts = {}
    for i = 1, #s do
        local b = s:byte(i)
        if     b == 0x22 then parts[#parts+1] = '\\"'
        elseif b == 0x5c then parts[#parts+1] = '\\\\'
        elseif b == 0x08 then parts[#parts+1] = '\\b'
        elseif b == 0x09 then parts[#parts+1] = '\\t'
        elseif b == 0x0a then parts[#parts+1] = '\\n'
        elseif b == 0x0c then parts[#parts+1] = '\\f'
        elseif b == 0x0d then parts[#parts+1] = '\\r'
        elseif b < 0x20 or b == 0x7f then
            parts[#parts+1] = string.format('\\u%04X', b)
        else
            parts[#parts+1] = s:sub(i, i)
        end
    end
    return table.concat(parts)
end

---@param key string
---@return string
local function quote_key(key)
    if needs_quotes(key) then
        return '"' .. escape_basic(key) .. '"'
    end
    return key
end

---@param s string
---@return string
local function encode_string(s)
    return '"' .. escape_basic(s) .. '"'
end

---@param n number
---@return string
local function encode_number(n)
    if n ~= n then return "nan"
    elseif n == math.huge then return "inf"
    elseif n == -math.huge then return "-inf"
    elseif math.floor(n) == n and math.abs(n) < 2^53 then
        return string.format("%.0f", n)
    end
    local s = string.format("%.17g", n)
    if not s:find("[%.eE]") then s = s .. ".0" end
    return s
end

---@param t table
---@return boolean
local function is_array(t)
    return std.islist(t)
end

---@param t table
---@return any[]
local function sorted_keys(t)
    local ks = {}
    for k in pairs(t) do ks[#ks+1] = k end
    table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
    return ks
end

--- Like sorted_keys but honours M.ordered() metadata: listed keys come first
--- in order, remaining keys are appended sorted.
---@param t table
---@return any[]
local function ordered_or_sorted_keys(t)
    local order = table_util.ordered_keys_of(t)
    if not order then return sorted_keys(t) end
    local seen, ks = {}, {}
    for _, k in ipairs(order) do
        if t[k] ~= nil then ks[#ks+1] = k; seen[k] = true end
    end
    local rest = {}
    for k in pairs(t) do if not seen[k] then rest[#rest+1] = k end end
    table.sort(rest, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(rest) do ks[#ks+1] = k end
    return ks
end

local encode_value  -- forward decl

---@param arr table
---@return string
local function encode_array(arr)
    if #arr == 0 then return "[]" end
    local items = {}
    for _, v in ipairs(arr) do
        items[#items+1] = encode_value(v)
    end
    local single = "[ " .. table.concat(items, ", ") .. " ]"
    if #single <= 80 then return single end
    return "[\n  " .. table.concat(items, ",\n  ") .. ",\n]"
end

---@param tbl table
---@return string
local function encode_inline_table(tbl)
    local parts = {}
    for _, k in ipairs(ordered_or_sorted_keys(tbl)) do
        parts[#parts+1] = quote_key(tostring(k)) .. " = " .. encode_value(tbl[k])
    end
    if #parts == 0 then return "{}" end
    return "{ " .. table.concat(parts, ", ") .. " }"
end

---@param v any
---@return string
encode_value = function(v)
    local t = type(v)
    if t == "string"  then return encode_string(v) end
    if t == "number"  then return encode_number(v) end
    if t == "boolean" then return tostring(v) end
    if t == "table" then
        local raw = raw_value(v)
        if raw then return raw end
        if is_array(v) then return encode_array(v) end
        return encode_inline_table(v)
    end
    error("encode: unsupported value type: " .. t)
end

-- Emit TOML lines for a table at section scope.
-- All arrays (including arrays of tables) are encoded inline — [[aot]] is never used
-- because inline arrays are always valid and avoid a class of nesting ambiguities.
---@param path    string[]
---@param data    table
---@param out     string[]
local function emit_section(path, data, out)
    local simple_keys = {}
    local subtbl_keys = {}

    for _, k in ipairs(ordered_or_sorted_keys(data)) do
        local v = data[k]
        -- A non-array dict table at section scope becomes a [header]. Everything
        -- else (scalars, arrays, raw wrappers) is a simple inline KVP.
        if type(v) == "table" and not is_array(v) and not raw_value(v) then
            subtbl_keys[#subtbl_keys+1] = k
        else
            simple_keys[#simple_keys+1] = k
        end
    end

    for _, k in ipairs(simple_keys) do
        out[#out+1] = quote_key(tostring(k)) .. " = " .. encode_value(data[k])
    end

    for _, k in ipairs(subtbl_keys) do
        local sub_path = {}
        for _, p in ipairs(path) do sub_path[#sub_path+1] = p end
        sub_path[#sub_path+1] = tostring(k)

        local header_parts = {}
        for _, p in ipairs(sub_path) do header_parts[#header_parts+1] = quote_key(p) end

        out[#out+1] = ""
        out[#out+1] = "[" .. table.concat(header_parts, ".") .. "]"
        emit_section(sub_path, data[k], out)
    end
end

---@param tbl    table
---@param indent string  outer indentation; inner items get two extra spaces
---@return string        newline-joined block, all lines self-indented
local function encode_inline_table_multiline(tbl, indent)
    local inner = indent .. "  "
    local parts = { indent .. "{" }
    for _, k in ipairs(ordered_or_sorted_keys(tbl)) do
        parts[#parts + 1] = inner .. quote_key(tostring(k)) .. " = " .. encode_value(tbl[k]) .. ","
    end
    parts[#parts + 1] = indent .. "}"
    return table.concat(parts, "\n")
end

---@class tomltools.EncodeInlineOpts
---@field multiline boolean?  emit as a multiline inline table
---@field indent    string?   outer indentation prefix (used when multiline = true)

--- Encode a Lua table as a TOML inline table string: { key = val, ... }.
--- Pass opts.multiline = true for a multiline block; all lines carry their own
--- indentation so the caller can split("\n") and insert directly.
---@param t    table
---@param opts tomltools.EncodeInlineOpts?
---@return string
function M.encode_inline(t, opts)
    if opts and opts.multiline then
        return encode_inline_table_multiline(t, opts.indent or "")
    end
    return encode_inline_table(t)
end

--- Encode a Lua table as a [[key]] AoT entry block.
--- Returns "[[key]]\nfield = val\n..." using sorted keys.
---@param aot_key string
---@param item    table
---@return string
function M.encode_aot_entry(aot_key, item)
    local out = { "[[" .. quote_key(aot_key) .. "]]" }
    emit_section({ aot_key }, item, out)
    return table.concat(out, "\n")
end

--- Encode a Lua table as a [key] table block.
--- Returns "[key]\nfield = val\n..." using ordered/sorted keys.
---@param key string
---@param item       table
---@return string
function M.encode_table_entry(key, item)
    local header = "[" .. quote_key(key) .. "]"
    local out    = { header }
    emit_section({ key }, item, out)
    return table.concat(out, "\n")
end

--- Encode a Lua table as a TOML string.
---@param data table
---@return string
function M.encode(data)
    if type(data) ~= "table" then
        error("toml encode: root value must be a table, got " .. type(data))
    end
    local out = {}
    emit_section({}, data, out)
    while out[1] == "" do table.remove(out, 1) end
    if #out == 0 then return "" end
    return table.concat(out, "\n") .. "\n"
end

return M
