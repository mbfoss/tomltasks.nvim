local parser    = require("easytasks.toml.parser")
local decoder   = require("easytasks.toml.decoder")
local validator = require("easytasks.toml.validator")
local inspect   = require("easytasks.toml.inspect")
local encoder   = require("easytasks.toml.encoder")

local M         = {}

---@class easytasks.toml.Error
---@field range   integer[]?  { r1, c1, r2, c2 } 0-indexed; nil when location is unknown
---@field message string

--- Parse, decode, and optionally validate a TOML string.
--- All error types (parse, decode, schema) are normalised to { range, message }.
---@param text   string
---@param schema table?  JSON Schema; validation is skipped when nil
---@return easytasks.toml.ParseResult
function M.parse(text, schema)
    ---@type easytasks.toml.Error[]
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

--- Find the TOML structural path at the cursor position.
--- Returns a list of PathNodes (outermost first), `{}` at document root,
--- or nil when parsing fails or cursor is not at an addressable position.
---@param text string
---@param row  integer  0-indexed
---@param col  integer  0-indexed
---@return easytasks.PathNode[]?
function M.find_path(text, row, col)
    return inspect.find_path(text, row, col)
end

--- Encode a Lua table as TOML text lines.
---@param t    table
---@param opts { style: "inline"|"aot"|"table", key: string?, indent: string? }?
---@return string[]
function M.encode(t, opts)
    local text
    if not opts or opts.style == "inline" then
        text = encoder.encode_inline(t, { multiline = true, indent = opts and opts.indent or "" })
    elseif opts.style == "table" then
        text = encoder.encode_table_entry(
            assert(opts.key, "encode: key required for table style"),
            t)
    else
        text = encoder.encode_aot_entry(assert(opts.key, "encode: key required for aot style"), t)
    end
    return vim.split(text, "\n", { plain = true })
end

return M
