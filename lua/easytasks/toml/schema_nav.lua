-- easytasks/toml/schema_nav.lua
-- Shared schema navigation: flatten, schema_at, and cursor resolution via DecodeTree.
local M = {}

local vu        = require("easytasks.toml.validator_util")
local validator = require("easytasks.toml.validator")

-- Merge allOf, anyOf, oneOf, dependentSchemas; resolve if/then/else against data.
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

  if s.anyOf then
    local any_passed = false
    local best, best_n = nil, math.huge
    for _, sub in ipairs(s.anyOf) do
      local ok, errs = validator.validate(sub, d)
      if ok then
        any_passed = true
        vu.deep_merge_tables(out, M.flatten(sub, d))
      elseif #errs < best_n then
        best_n = #errs; best = sub
      end
    end
    if not any_passed and best then
      vu.deep_merge_tables(out, M.flatten(best, d))
    end
  end

  if s.dependentSchemas and type(d) == "table" and not vim.islist(d) then
    for prop, subschema in pairs(s.dependentSchemas) do
      if d[prop] ~= nil then
        vu.deep_merge_tables(out, M.flatten(subschema, d))
      end
    end
  end

  out["if"] = nil; out["then"] = nil; out["else"] = nil
  out.allOf = nil; out.oneOf = nil; out.anyOf = nil
  out.dependentSchemas = nil
  return out
end

-- Navigate root_schema+root_data to the schema owned by a DecodeTree node.
-- Walks the key segments from root to `id`, navigating schema and data in
-- parallel. Handles arrays (numeric segments → prefixItems then items),
-- objects (→ properties, patternProperties, additionalProperties),
-- and conditional keywords via flatten.
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

    if idx then
      if flat.prefixItems and flat.prefixItems[idx] then
        d = type(d) == "table" and d[idx] or nil
        s = flat.prefixItems[idx]
      elseif flat.items then
        d = type(d) == "table" and d[idx] or nil
        s = flat.items
      else
        return nil
      end
    elseif flat.properties and flat.properties[seg] then
      d = type(d) == "table" and d[seg] or nil
      s = flat.properties[seg]
    else
      local matched = false
      if flat.patternProperties then
        for pattern, subschema in pairs(flat.patternProperties) do
          if type(seg) == "string" and seg:match(pattern) then
            d = type(d) == "table" and d[seg] or nil
            s = subschema
            matched = true
            break
          end
        end
      end
      if not matched then
        if type(flat.additionalProperties) == "table" then
          d = type(d) == "table" and d[seg] or nil
          s = flat.additionalProperties
        else
          return nil
        end
      end
    end
  end

  return M.flatten(s, d)
end

-- Like schema_at but returns the field's schema without the final flatten,
-- preserving oneOf/allOf on the target node. Used by completion to offer
-- completions from all oneOf branches rather than just the best-matching one.
---@param root_schema table
---@param root_data   any
---@param dt          easytasks.toml.DecodeTree
---@param id          integer
---@return table?
function M.raw_schema_at(root_schema, root_data, dt, id)
  local parts = dt:key_parts_of(id)
  local s, d  = root_schema, root_data

  for _, seg in ipairs(parts) do
    local flat = M.flatten(s, d)
    local idx  = tonumber(seg)

    if idx then
      if flat.prefixItems and flat.prefixItems[idx] then
        d = type(d) == "table" and d[idx] or nil
        s = flat.prefixItems[idx]
      elseif flat.items then
        d = type(d) == "table" and d[idx] or nil
        s = flat.items
      else
        return nil
      end
    elseif flat.properties and flat.properties[seg] then
      d = type(d) == "table" and d[seg] or nil
      s = flat.properties[seg]
    else
      local matched = false
      if flat.patternProperties then
        for pattern, subschema in pairs(flat.patternProperties) do
          if type(seg) == "string" and seg:match(pattern) then
            d = type(d) == "table" and d[seg] or nil
            s = subschema
            matched = true
            break
          end
        end
      end
      if not matched then
        if type(flat.additionalProperties) == "table" then
          d = type(d) == "table" and d[seg] or nil
          s = flat.additionalProperties
        else
          return nil
        end
      end
    end
  end

  return s  -- intentionally not flattened
end

return M
