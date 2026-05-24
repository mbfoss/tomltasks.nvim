-- easytasks/lsp/schema_nav.lua
-- Shared schema navigation: flatten, schema_at, and cursor resolution via DecodeTree.
local M = {}

local utils     = require("easytasks.toml.validatorutils")
local validator = require("easytasks.toml.validator")

-- Merge allOf, resolve if/then/else and oneOf branches against data.
-- Returns a new flat schema table with conditional keys removed.
---@param s table
---@param d any
---@return table
function M.flatten(s, d)
  local out = {}
  utils.deep_merge_tables(out, s)

  if s.allOf then
    for _, sub in ipairs(s.allOf) do
      utils.deep_merge_tables(out, M.flatten(sub, d))
    end
  end

  if s["if"] then
    local ok = validator.validate(s["if"], d)
    if ok and s["then"] then
      utils.deep_merge_tables(out, M.flatten(s["then"], d))
    elseif not ok and s["else"] then
      utils.deep_merge_tables(out, M.flatten(s["else"], d))
    end
  end

  if s.oneOf then
    local best, best_n = nil, math.huge
    for _, sub in ipairs(s.oneOf) do
      local _, errs = validator.validate(sub, d)
      if #errs < best_n then
        best_n = #errs; best = sub
      end
      if best_n == 0 then break end
    end
    if best then utils.deep_merge_tables(out, M.flatten(best, d)) end
  end

  out["if"] = nil; out["then"] = nil; out["else"] = nil
  out.allOf  = nil; out.oneOf  = nil
  return out
end

-- Navigate root_schema+root_data to the schema at `path` (JSON Pointer).
-- Handles nested tables, array-of-tables (numeric segments → items),
-- additionalProperties, and conditional keywords via flatten.
-- Returns a flattened schema table, or nil if the path is not navigable.
---@param root_schema table
---@param root_data   any
---@param path        string  JSON Pointer (RFC 6901), e.g. "/tasks/1/name"
---@return table?
function M.schema_at(root_schema, root_data, path)
  local parts = utils.split_path(path)
  local s, d  = root_schema, root_data

  for _, seg in ipairs(parts) do
    local flat = M.flatten(s, d)
    local idx  = tonumber(seg)

    if idx and flat.items then
      -- array segment (1-based, matching Lua tables and DecodeTree)
      d = type(d) == "table" and d[idx] or nil
      s = flat.items
    elseif flat.properties and flat.properties[seg] then
      d = type(d) == "table" and d[seg] or nil
      s = flat.properties[seg]
    elseif type(flat.additionalProperties) == "table" then
      d = type(d) == "table" and d[seg] or nil
      s = flat.additionalProperties
    else
      return nil
    end
  end

  return M.flatten(s, d)
end

-- Resolve the schema node at a cursor position using the buffer's decode_tree.
-- The decode_tree already maps every decoded value (including inline-table fields
-- and array-of-tables elements) to its source range, so this handles all TOML
-- structure kinds without re-parsing.
--
-- Returns (path, schema_node): path is the JSON Pointer of the node at (row,col),
-- schema_node is the flattened schema for that path.  Both are nil on miss.
---@param context easytasks.LspBufferContext
---@param row     integer  0-indexed
---@param col     integer  0-indexed
---@return string?  path
---@return table?   schema_node
function M.resolve_at(context, row, col)
  if not context.decode_tree or not context.schema then return nil, nil end
  local path = context.decode_tree:pos_to_path(row, col)
  if not path then return nil, nil end
  return path, M.schema_at(context.schema, context.data, path)
end

return M
