local M          = {}

local s_util     = require("easytasks.toml.schema_util")
local utils      = require("easytasks.toml.validator_util")
local schema_nav = require("easytasks.toml.schema_nav")
local Ast        = require("easytasks.toml.Ast")

local NodeKind   = Ast.NodeKind
local CK         = vim.lsp.protocol.CompletionItemKind

--------------------------------------------------------------------------------
-- AST helpers  (section-level context)
--------------------------------------------------------------------------------

-- Count 1-based position of section_id among same-path [[array-of-tables]] headers.
---@param ast          easytasks.toml.Ast
---@param section_id   any
---@param section_node easytasks.toml.ArrayOfTablesSectionNode
---@return integer
local function aot_index(ast, section_id, section_node)
  local target = table.concat(vim.tbl_map(function(k) return k.value end, section_node.keys), ".")
  local idx = 0
  for id, node in ast:iter_roots() do
    if node.kind == NodeKind.ArrayOfTablesSection
        or node.kind == NodeKind.PartialArrayOfTablesSection then
      local p = table.concat(vim.tbl_map(function(k) return k.value end, node.keys), ".")
      if p == target then
        idx = idx + 1
        if id == section_id then return idx end
      end
    end
  end
  return idx
end

-- Build JSON Pointer path for a section node, or "" for the root scope.
---@param ast        easytasks.toml.Ast
---@param section_id any
---@param node       easytasks.toml.AstNode?
---@return string
local function section_path(ast, section_id, node)
  if not node then return "" end
  local segs = {}
  if node.kind == NodeKind.ArrayOfTablesSection
      or node.kind == NodeKind.PartialArrayOfTablesSection then
    ---@cast node easytasks.toml.ArrayOfTablesSectionNode
    for _, k in ipairs(node.keys) do table.insert(segs, k.value) end
    table.insert(segs, tostring(aot_index(ast, section_id, node)))
  else
    ---@cast node easytasks.toml.TableSectionNode
    for _, k in ipairs(node.keys) do table.insert(segs, k.value) end
  end
  if #segs == 0 then return "" end
  return utils.join_path_parts(segs)
end

-- Find the section node that contains `row` (last section header before/at that row).
---@param ast easytasks.toml.Ast
---@param row integer
---@return any, easytasks.toml.AstNode?
local function section_at_row(ast, row)
  local sec_id, sec_node = nil, nil
  for id, node in ast:iter_roots() do
    if node.range and node.range[1] <= row then
      if node.kind == NodeKind.TableSection
          or node.kind == NodeKind.ArrayOfTablesSection
          or node.kind == NodeKind.PartialTableSection
          or node.kind == NodeKind.PartialArrayOfTablesSection then
        sec_id   = id
        sec_node = node
      end
    end
  end
  return sec_id, sec_node
end

--------------------------------------------------------------------------------
-- Container resolution (section + decode_tree combined)
--------------------------------------------------------------------------------

-- Return the keys already present at `container_path` in the decoded data.
---@param context        easytasks.LspBufferContext
---@param container_path string
---@return table<string, boolean>
local function defined_keys_at(context, container_path)
  if not context.data then return {} end
  local data = utils.get_at_path(context.data, container_path)
  if type(data) ~= "table" or vim.islist(data) then return {} end
  local keys = {}
  for k in pairs(data) do keys[k] = true end
  return keys
end

---@param context easytasks.LspBufferContext
---@param row     integer
---@param col     integer
---@return string
local function resolve_container(context, row, col)
  local sec_id, sec_node = section_at_row(context.ast, row)
  local spath            = section_path(context.ast, sec_id, sec_node)

  local dt               = context.decode_tree
  if not dt then return spath end
  local dt_path = dt:pos_to_path(row, col)
  if not dt_path then return spath end

  local dt_parts = utils.split_path(dt_path)
  local s_parts  = utils.split_path(spath)

  if #dt_parts <= #s_parts then return spath end

  local parts = dt_parts
  while #parts > #s_parts do
    local path = utils.join_path_parts(parts)
    local s    = schema_nav.schema_at(context.schema, context.data, path)
    if s and (s.properties ~= nil or s.additionalProperties ~= nil
          or s.type == "object"
          or (type(s.type) == "table" and vim.tbl_contains(s.type, "object"))) then
      return path
    end
    table.remove(parts)
  end

  return spath
end

--------------------------------------------------------------------------------
-- Completion item builders
--------------------------------------------------------------------------------

---@param flat     table?
---@param existing table<string, boolean>
---@param prefix   string
---@return lsp.CompletionItem[]
local function key_items(flat, existing, prefix)
  if not flat then return {} end
  local items = {}
  for _, prop in ipairs(s_util.get_ordered_properties(flat)) do
    if not existing[prop.key] and s_util.matches_filter(prefix, prop.key) then
      table.insert(items, {
        label            = prop.key,
        kind             = CK.Field,
        detail           = s_util.get_type_label(prop.schema),
        documentation    = { kind = "markdown", value = s_util.get_description(prop.schema) },
        insertText       = prop.key .. " = ",
        insertTextFormat = 1,
      })
    end
  end
  return items
end

---@param flat   table?
---@param prefix string
---@return lsp.CompletionItem[]
local function value_items(flat, prefix)
  if not flat then return {} end
  local items      = {}
  local enum_descs = flat["x-enumDescriptions"]
  local match_pfx  = prefix:match('^["\']?(.*)$') or prefix

  if flat.enum then
    for i, v in ipairs(flat.enum) do
      local label = type(v) == "string" and ('"' .. v .. '"') or tostring(v)
      local raw   = type(v) == "string" and v or label
      if s_util.matches_filter(match_pfx, raw) then
        local doc = enum_descs and enum_descs[i]
        table.insert(items, {
          label         = label,
          kind          = CK.EnumMember,
          documentation = doc and { kind = "markdown", value = doc } or nil,
        })
      end
    end
  end

  if flat.const ~= nil then
    local label = type(flat.const) == "string" and ('"' .. flat.const .. '"') or tostring(flat.const)
    local raw   = type(flat.const) == "string" and flat.const or label
    if s_util.matches_filter(match_pfx, raw) then
      table.insert(items, { label = label, kind = CK.Value })
    end
  end

  local types = utils.get_schema_allowed_types(flat)
  if vim.tbl_contains(types, "boolean") then
    for _, v in ipairs({ "true", "false" }) do
      if s_util.matches_filter(match_pfx, v) then
        table.insert(items, { label = v, kind = CK.Value })
      end
    end
  end
  return items
end

--------------------------------------------------------------------------------
-- Position-based prefix helpers (byte scanning)
--------------------------------------------------------------------------------

-- Bare TOML key chars at the rightmost end of s (the partial key being typed).
local function key_prefix_at(s)
  local i = #s
  while i >= 1 do
    local b = s:byte(i)
    if (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
        or (b >= 48 and b <= 57) or b == 45 or b == 95 then
      i = i - 1
    else break end
  end
  return s:sub(i + 1)
end

-- Text after the last `=` in s, with leading whitespace stripped.
local function value_prefix_after_eq(s)
  for i = #s, 1, -1 do
    if s:byte(i) == 61 then
      local rest = s:sub(i + 1)
      local j    = 1
      while j <= #rest and (rest:byte(j) == 32 or rest:byte(j) == 9) do j = j + 1 end
      return rest:sub(j)
    end
  end
  return ""
end

--------------------------------------------------------------------------------
-- AST cursor analysis
--------------------------------------------------------------------------------

-- Walk AST children of kvp_id looking for the innermost KVP whose key precedes
-- (row, col) and whose value range has not yet been passed.
-- Returns that KVP's key string, or nil (cursor is in key context at this level).
local function find_leaf_key_segment(ast, kvp_id, row, col)
  for _, child in ipairs(ast:get_children(kvp_id)) do
    local c = child.data
    if c.kind == NodeKind.KeyValuePair then
      local k = c.key
      if k.range[1] < row or (k.range[1] == row and col > k.range[4]) then
        local v    = c.value
        local past = v and v.range
            and (row > v.range[3] or (row == v.range[3] and col > v.range[4]))
        if not past then
          return find_leaf_key_segment(ast, child.id, row, col) or k.value
        end
      end
    end
  end
  return nil
end

-- Build a JSON Pointer by prepending kvp_node's key to base, then descending
-- through dotted-key KVP children whose key precedes (row, col).
local function build_kpath_from_kvp(ast, kvp_id, kvp_node, row, col, base)
  local kpath = utils.join_path(base, kvp_node.key.value)
  for _, child in ipairs(ast:get_children(kvp_id)) do
    local c = child.data
    if c.kind == NodeKind.KeyValuePair then
      local k = c.key
      if k.range[1] < row or (k.range[1] == row and col > k.range[4]) then
        local v    = c.value
        local past = v and v.range
            and (row > v.range[3] or (row == v.range[3] and col > v.range[4]))
        if not past then
          kpath = build_kpath_from_kvp(ast, child.id, c, row, col, kpath)
        end
        break
      end
    end
  end
  return kpath
end

--------------------------------------------------------------------------------
-- Completion Request Dispatcher
--------------------------------------------------------------------------------

---@param context easytasks.LspBufferContext
---@param params lsp.CompletionParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.CompletionList)
function M.handler(context, params, callback)
  callback = vim.schedule_wrap(callback)
  local empty = { isIncomplete = false, items = {} }
  if not context.schema then callback(nil, empty); return end

  local row    = params.position.line
  local col    = params.position.character
  local line   = vim.api.nvim_buf_get_lines(context.bufnr, row, row + 1, false)[1] or ""
  local before = line:sub(1, col)

  -- ── Section header ────────────────────────────────────────────────────────
  if before:match("^%s*%[") then
    local is_aot = before:match("^%s*%[%[") ~= nil
    local inner  = (is_aot and before:match("%[%[(.*)$") or before:match("%[(.*)$")) or ""
    local prefix = inner:gsub("%s", "")
    local results = {}
    if is_aot then
      s_util.gather_array_table_paths(context.schema, "", results)
    else
      s_util.gather_table_paths(context.schema, "", results)
    end
    local items = {}
    for _, r in ipairs(results) do
      if s_util.matches_filter(prefix, r.path) then
        table.insert(items, {
          label         = r.path,
          kind          = CK.Module,
          documentation = { kind = "markdown", value = s_util.get_description(r.node) },
        })
      end
    end
    callback(nil, { isIncomplete = false, items = items })
    return
  end

  local dt  = context.decode_tree
  local ast = context.ast
  local hit  = ast and ast:node_at(row, col)
  local node = hit and hit.node

  -- ── Cursor inside an existing literal value ───────────────────────────────
  if node and node.kind == NodeKind.Literal then
    local dt_path = dt and dt:pos_to_path(row, col)
    if dt_path then
      local prefix = before:sub(node.range[2] + 1)
      local flat   = schema_nav.schema_at(context.schema, context.data, dt_path)
      callback(nil, { isIncomplete = false, items = value_items(flat, prefix) })
      return
    end
    callback(nil, empty); return
  end

  -- ── Cursor past a KVP's key ───────────────────────────────────────────────
  -- Covers both value context (after `=`) and key context inside an inline table.
  if node and node.kind == NodeKind.KeyValuePair and col > node.key.range[4] then
    local dt_path = dt and dt:pos_to_path(row, col)
    local dt_data = dt_path and utils.get_at_path(context.data, dt_path)

    if type(dt_data) == "table" and not vim.islist(dt_data) then
      -- Cursor is geometrically inside an inline-table object (dt_path is its container).
      -- find_leaf_key_segment disambiguates: returns the key if in value position, nil if key position.
      local leaf = find_leaf_key_segment(ast, hit.id, row, col)
      if leaf then
        local kpath = utils.join_path(dt_path, leaf)
        local flat  = schema_nav.schema_at(context.schema, context.data, kpath)
        callback(nil, { isIncomplete = false, items = value_items(flat, value_prefix_after_eq(before)) })
      else
        local flat     = schema_nav.schema_at(context.schema, context.data, dt_path)
        local existing = defined_keys_at(context, dt_path)
        callback(nil, { isIncomplete = false, items = key_items(flat, existing, key_prefix_at(before)) })
      end
      return
    end

    -- No inline-table container from decode tree: plain value context.
    local container = resolve_container(context, row, col)
    local kpath     = build_kpath_from_kvp(ast, hit.id, node, row, col, container)
    local flat      = schema_nav.schema_at(context.schema, context.data, kpath)
    callback(nil, { isIncomplete = false, items = value_items(flat, value_prefix_after_eq(before)) })
    return
  end

  -- ── Key context (section / root level) ───────────────────────────────────
  local container = resolve_container(context, row, col)
  local flat      = schema_nav.schema_at(context.schema, context.data, container)
  local existing  = defined_keys_at(context, container)
  callback(nil, { isIncomplete = false, items = key_items(flat, existing, key_prefix_at(before)) })
end

return M
