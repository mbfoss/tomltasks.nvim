local M = {}

---@param key string
---@return boolean
local function needs_quotes(key)
    return not key:match("^[A-Za-z0-9_%-]+$")
end

---@param key string
---@return string
local function quote_key(key)
    if needs_quotes(key) then
        return '"' .. key:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
    end
    return key
end

---@param s string
---@return string
local function encode_string(s)
    if not s:find("'") and not s:find("[\n\r\t\\]") then
        return "'" .. s .. "'"
    end
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
        :gsub("\b", "\\b"):gsub("\t", "\\t"):gsub("\n", "\\n")
        :gsub("\f", "\\f"):gsub("\r", "\\r")
    return '"' .. s .. '"'
end

---@param n number
---@return string
local function encode_number(n)
    if n ~= n then return "nan"
    elseif n == math.huge then return "inf"
    elseif n == -math.huge then return "-inf"
    elseif math.floor(n) == n and math.abs(n) < 2^53 then
        return tostring(math.floor(n))
    end
    return tostring(n)
end

-- Returns true if t is a sequence (array): keys are 1..#t with no gaps.
-- An empty table {} is considered a sequence.
---@param t table
---@return boolean
local function is_array(t)
    local max = 0
    local count = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
            return false
        end
        if k > max then max = k end
        count = count + 1
    end
    return count == max
end

-- Sorted keys from a table (string sort on tostring of key).
---@param t table
---@return any[]
local function sorted_keys(t)
    local ks = {}
    for k in pairs(t) do ks[#ks + 1] = k end
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
        items[#items + 1] = encode_value(v)
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
        parts[#parts + 1] = quote_key(tostring(k)) .. " = " .. encode_value(tbl[k])
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
        -- {__toml_raw = "..."} emits the string verbatim (for datetimes, etc.)
        if type(v.__toml_raw) == "string" then return v.__toml_raw end
        if is_array(v) then return encode_array(v) end
        return encode_inline_table(v)
    end
    error("encode: unsupported value type: " .. t)
end

-- Emit TOML lines for a table at section scope.
-- path  – list of key strings forming the current header path (empty = root)
-- data  – the Lua table to encode at this scope
-- out   – lines accumulator
---@param path    string[]
---@param data    table
---@param out     string[]
local function emit_section(path, data, out)
    -- Partition keys into three buckets:
    --   simple  – scalars / arrays of inline-safe values / inline-safe tables
    --   subtbl  – dict tables (will become [section] headers)
    --   aot     – arrays whose items are all tables (will become [[aot]] headers)
    local simple_keys = {}
    local subtbl_keys = {}
    local aot_keys    = {}

    for _, k in ipairs(sorted_keys(data)) do
        local v = data[k]
        if type(v) == "table" and not is_array(v) and type(v.__toml_raw) ~= "string" then
            subtbl_keys[#subtbl_keys + 1] = k
        elseif type(v) == "table" and is_array(v) and #v > 0 and type(v[1]) == "table" then
            aot_keys[#aot_keys + 1] = k
        else
            simple_keys[#simple_keys + 1] = k
        end
    end

    -- 1. Simple KVPs
    for _, k in ipairs(simple_keys) do
        out[#out + 1] = quote_key(tostring(k)) .. " = " .. encode_value(data[k])
    end

    -- 2. Sub-tables as [path.key] sections
    for _, k in ipairs(subtbl_keys) do
        local sub_path = {}
        for _, p in ipairs(path) do sub_path[#sub_path + 1] = p end
        sub_path[#sub_path + 1] = tostring(k)

        local header_parts = {}
        for _, p in ipairs(sub_path) do header_parts[#header_parts + 1] = quote_key(p) end

        out[#out + 1] = ""
        out[#out + 1] = "[" .. table.concat(header_parts, ".") .. "]"
        emit_section(sub_path, data[k], out)
    end

    -- 3. Arrays of tables as [[path.key]] sections
    for _, k in ipairs(aot_keys) do
        local sub_path = {}
        for _, p in ipairs(path) do sub_path[#sub_path + 1] = p end
        sub_path[#sub_path + 1] = tostring(k)

        local header_parts = {}
        for _, p in ipairs(sub_path) do header_parts[#header_parts + 1] = quote_key(p) end
        local header = "[[" .. table.concat(header_parts, ".") .. "]]"

        for _, item in ipairs(data[k]) do
            out[#out + 1] = ""
            out[#out + 1] = header
            if type(item) == "table" then
                emit_section(sub_path, item, out)
            end
        end
    end
end

--- Encode a Lua table as a TOML string.
---@param data  table           root table to encode
---@return string
function M.encode(data)
    if type(data) ~= "table" then
        error("toml encode: root value must be a table, got " .. type(data))
    end

    local out = {}
    emit_section({}, data, out)

    -- drop any leading blank line introduced by the first section header
    while out[1] == "" do table.remove(out, 1) end

    if #out == 0 then return "" end
    return table.concat(out, "\n") .. "\n"
end

return M
