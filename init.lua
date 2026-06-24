local parser    = require("tomltools.parser")
local decoder   = require("tomltools.decoder")
local validator = require("tomltools.validator")
local formatter = require("tomltools.formatter")
local inspect   = require("tomltools.inspect")
local encoder   = require("tomltools.encoder")
local std       = require("tomltools.std")

local M         = {}

---@class tomltools.Error
---@field range   integer[]?  { r1, c1, r2, c2 } 0-indexed; nil when location is unknown
---@field message string

---@class tomltools.ParseResult
---@field data   table?
---@field errors tomltools.Error[]
---@field ok     boolean

--- Parse, decode, and optionally validate a TOML string.
--- All error types (parse, decode, schema) are normalised to { range, message }.
---@param text   string
---@param schema table?  JSON Schema; validation is skipped when nil
---@return tomltools.ParseResult
function M.parse(text, schema)
    ---@type tomltools.Error[]
    local errors = {}

    local parsed = parser.parse(text)
    for _, e in ipairs(parsed.errors or {}) do
        errors[#errors + 1] = { range = e.range, message = e.message }
    end
    if not parsed.cst then
        return { ok = false, errors = errors }
    end

    local decoded = decoder.decode(parsed.cst)
    for _, e in ipairs(decoded.errors or {}) do
        errors[#errors + 1] = { range = e.range, message = e.message }
    end
    if not decoded.data then
        return { ok = false, errors = errors }
    end

    if schema then
        local valid, v_errors = validator.validate(schema, decoded.data, decoded.decode_tree)
        if not valid then
            for _, e in ipairs(v_errors) do
                local range = e.node_id and decoded.decode_tree
                    and decoded.decode_tree:range_of_id(e.node_id) or nil
                errors[#errors + 1] = { range = range, message = e.err_msg }
            end
        end
    end

    return {
        ok     = #errors == 0,
        data   = decoded.data,
        errors = errors,
    }
end

--- Decode a TOML string into a Lua table.
--- Returns the decoded table on success, or `nil` plus the list of errors.
---@param text string
---@return table?            data
---@return tomltools.Error[]? errors
function M.decode(text)
    local result = M.parse(text)
    if not result.ok then
        return nil, result.errors
    end
    return result.data
end

--- Reformat a TOML document, normalising whitespace and layout while preserving
--- comments. Returns the formatted text on success, or `nil` plus the parse
--- errors when the input is not valid TOML.
---@param text string
---@return string?           formatted
---@return tomltools.Error[]? errors
function M.format(text)
    local parsed = parser.parse(text)
    if not parsed.cst or (parsed.errors and #parsed.errors > 0) then
        local errors = {}
        for _, e in ipairs(parsed.errors or {}) do
            errors[#errors + 1] = { range = e.range, message = e.message }
        end
        return nil, errors
    end
    return formatter.format(parsed.cst)
end

--- Validate an already-decoded Lua value against a JSON Schema.
--- (To validate raw TOML text, use `parse(text, schema)` instead, which also
--- attaches source ranges to each error.)
---@param data   any
---@param schema table  JSON Schema (Draft 2020-12 subset)
---@return boolean           ok
---@return tomltools.Error[] errors
function M.validate(data, schema)
    local ok, v_errors = validator.validate(schema, data)
    local errors = {}
    for _, e in ipairs(v_errors) do
        errors[#errors + 1] = { message = e.err_msg }
    end
    return ok, errors
end

--- Find the TOML structural path at the cursor position.
--- Returns a list of PathNodes (outermost first), `{}` at document root,
--- or nil when parsing fails or cursor is not at an addressable position.
---@param text string
---@param row  integer  0-indexed
---@param col  integer  0-indexed
---@return tomltools.PathNode[]?
function M.find_path(text, row, col)
    return inspect.find_path(text, row, col)
end

--- Encode a Lua table as a complete TOML document string.
---@param value table
---@return string
function M.encode(value)
    return encoder.encode(value)
end

--- Encode a Lua table as TOML text *lines* for a single snippet, in the given
--- style. Useful for inserting a fragment into an existing document; `encode`
--- is the right choice for whole documents.
---@param t    table
---@param opts { style: "inline"|"aot"|"table", key: string?, indent: string? }?
---@return string[]
function M.encode_entry(t, opts)
    local text
    if not opts or opts.style == "inline" then
        text = encoder.encode_inline(t, { multiline = true, indent = opts and opts.indent or "" })
    elseif opts.style == "table" then
        text = encoder.encode_table_entry(
            assert(opts.key, "encode_entry: key required for table style"),
            t)
    else
        text = encoder.encode_aot_entry(assert(opts.key, "encode_entry: key required for aot style"), t)
    end
    return std.split(text, "\n", { plain = true })
end

return M
