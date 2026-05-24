-- easytasks/toml/schema_nav.lua
-- Shared schema navigation: flatten, schema_at, and cursor resolution via DecodeTree.
local M = {}

local vu        = require("easytasks.toml.validator_util")
local validator = require("easytasks.toml.validator")

-- Merge allOf, resolve if/then/else and oneOf branches against data.
-- Returns a new flat schema table with conditional keys removed.
---@param s table
---@param d any
---@return table
function M.flatten(s, d)
  local out = {}
  vu.deep_merge_tables(out, s)

  if s.allOf then
    for _, sub in ipairs(s.allOf) do
      vu.deep_merge_tables(out, M.flatten(sub, d))
    end
  end

  if s["if"] then
    local ok = validator.validate(s["if"], d)
    if ok and s["then"] then
      vu.deep_merge_tables(out, M.flatten(s["then"], d))
    elseif not ok and s["else"] then
      vu.deep_merge_tables(out, M.flatten(s["else"], d))
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
    if best then vu.deep_merge_tables(out, M.flatten(best, d)) end
  end

  out["if"] = nil; out["then"] = nil; out["else"] = nil
  out.allOf  = nil; out.oneOf  = nil
  return out
end

-- Navigate root_schema+root_data to the schema owned by a DecodeTree node.
-- Walks the key segments from root to `id`, navigating schema and data in
-- parallel. Handles tables, arrays (numeric segments → items),
-- additionalProperties, and conditional keywords via flatten.
-- Returns a flattened schema table, or nil if the path is not navigable.
---@param root_schema table
---@param root_data   any
---@param dt          easytasks.toml.DecodeTree
---@param id          integer
---@return table?
function M.schema_at(root_schema, root_data, dt, id)
  local parts = dt:key_parts_of(id)
  local s, d  = root_schema, root_data

  for _, seg in ipairs(parts) do
    local flat = M.flatten(s, d)
    local idx  = tonumber(seg)

    if idx and flat.items then
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
-- Returns (node_id, schema) where node_id is the DecodeTree node at (row, col).
---@param data        any
---@param decode_tree easytasks.toml.DecodeTree
---@param row         integer
---@param col         integer
---@param schema      table
---@return integer? node_id
---@return table?   schema
function M.resolve_at(data, decode_tree, row, col, schema)
  if not decode_tree or not schema then return nil, nil end
  local id = decode_tree:pos_to_id(row, col)
  if not id then return nil, nil end
  return id, M.schema_at(schema, data, decode_tree, id)
end

return M
