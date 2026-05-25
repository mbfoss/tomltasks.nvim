local M = {}

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

-- Control chars (except tab 0x09) or single-quote → cannot use literal string.
local UNSAFE_FOR_LITERAL = "[\0-\8\10-\31\127']"

---@param s string
---@return string
local function encode_string(s)
    if not s:find(UNSAFE_FOR_LITERAL) then
        return "'" .. s .. "'"
    end
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

-- Returns true if t is a sequence: consecutive integer keys 1..#t with no gaps.
-- An empty table without the JSON-object metatable is treated as an empty array.
-- vim.empty_dict() (and any table with mt.__jsontype == "object") is NOT an array.
---@param t table
---@return boolean
local function is_array(t)
    local mt = getmetatable(t)
    if mt and mt.__jsontype == "object" then return false end
    local max, count = 0, 0
    for k in pairs(t) do
        if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
            return false
        end
        if k > max then max = k end
        count = count + 1
    end
    return count == max
end

---@param t table
---@return any[]
local function sorted_keys(t)
    local ks = {}
    for k in pairs(t) do ks[#ks+1] = k end
    table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
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
    for _, k in ipairs(sorted_keys(tbl)) do
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
        -- {__toml_raw = "..."} emits the string verbatim (datetimes, pre-formatted floats).
        if type(v.__toml_raw) == "string" then return v.__toml_raw end
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

    for _, k in ipairs(sorted_keys(data)) do
        local v = data[k]
        -- A non-array dict table at section scope becomes a [header]. Everything
        -- else (scalars, arrays, __toml_raw wrappers) is a simple inline KVP.
        if type(v) == "table" and not is_array(v) and type(v.__toml_raw) ~= "string" then
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
