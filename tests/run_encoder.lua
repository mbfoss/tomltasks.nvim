-- tests/run_encoder.lua
-- Run with: nvim -l tests/run_encoder.lua
-- Reads toml-test tagged JSON from stdin, writes TOML to stdout.
-- Exits non-zero on error.

local cwd = vim.fn.getcwd()
vim.opt.rtp:append(vim.fs.joinpath(vim.fn.fnamemodify(cwd, ":h")))

local encoder = require("easytasks.toml.encoder")

local datetime_types = {
    ["datetime"]       = true,
    ["datetime-local"] = true,
    ["date-local"]     = true,
    ["time-local"]     = true,
}

-- Convert a toml-test tagged JSON value into a plain Lua value the encoder understands.
-- Scalars come in as {type=..., value=...}; tables/arrays are plain Lua structures.
local function untag(v)
    if type(v) ~= "table" then return v end

    -- Tagged scalar: {type = "...", value = "..."}
    local typ = v.type
    local val = v.value
    if type(typ) == "string" and val ~= nil then
        if typ == "string" then
            return tostring(val)
        elseif typ == "integer" then
            return math.floor(tonumber(val) or 0)
        elseif typ == "float" then
            local s = tostring(val)
            if s == "nan"  then return 0/0 end
            if s == "inf"  then return math.huge end
            if s == "-inf" then return -math.huge end
            return tonumber(s)
        elseif typ == "bool" then
            return val == "true" or val == true
        elseif datetime_types[typ] then
            -- Emit verbatim — no quotes
            return { __toml_raw = tostring(val) }
        end
    end

    -- Array: consecutive integer keys 1..n (toml-test arrays are Lua arrays after json.decode)
    local is_seq = true
    local max = 0
    for k in pairs(v) do
        if type(k) ~= "number" then is_seq = false; break end
        if k > max then max = k end
    end
    if is_seq and max == #v then
        local arr = {}
        for i = 1, #v do arr[i] = untag(v[i]) end
        return arr
    end

    -- Table
    local tbl = vim.empty_dict()
    for k, child in pairs(v) do
        tbl[k] = untag(child)
    end
    return tbl
end

local raw = io.read("*a")
local ok, tagged = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
if not ok then
    io.stderr:write("run_encoder: JSON parse error: " .. tostring(tagged) .. "\n")
    os.exit(1)
end

local data = untag(tagged)

local toml_ok, result = pcall(encoder.encode, data)
if not toml_ok then
    io.stderr:write("run_encoder: encode error: " .. tostring(result) .. "\n")
    os.exit(1)
end

io.write(result)
