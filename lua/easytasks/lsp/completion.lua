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
-- Container resolution
-- Combines AST section detection (reliable for [table]/[[aot]] headers) with
-- decode_tree lookup (required for inline tables whose structure is invisible
-- to the section scanner).
--------------------------------------------------------------------------------

-- Return the keys already present at `container_path` in the decoded data.
-- Works for both section-based and inline-table containers.
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

-- Resolve the container object path for the cursor.
--
-- Algorithm:
--   1. AST gives the enclosing [table]/[[aot]] section path (`spath`).
--      This is correct for top-level sections but misses inline tables.
--   2. decode_tree gives the deepest decoded node at (row, col) (`dt_path`).
--      This captures inline table fields that the AST scan cannot see.
--   3. If dt_path has more path segments than spath, it means the cursor is
--      inside an inline table (or deeper nesting).  We then walk up dt_path
--      until we land on an object in the schema, which becomes the container.
---@param context easytasks.LspBufferContext
---@param row     integer
---@param col     integer
---@return string  JSON Pointer to the container object
local function resolve_container(context, row, col)
  local sec_id, sec_node = section_at_row(context.ast, row)
  local spath            = section_path(context.ast, sec_id, sec_node)

  local dt               = context.decode_tree
  if not dt then return spath end
  local dt_path = dt:pos_to_path(row, col)
  if not dt_path then return spath end

  local dt_parts = utils.split_path(dt_path)
  local s_parts  = utils.split_path(spath)

  -- decode_tree path not deeper than the AST section — no new information.
  if #dt_parts <= #s_parts then return spath end

  -- dt_path is deeper; resolve upward to the nearest object/container.
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
      local default = s_util.get_default_toml(prop.schema)
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
---@param prefix string  text after `=`, may begin with `"`
---@return lsp.CompletionItem[]
local function value_items(flat, prefix)
  if not flat then return {} end
  local items      = {}
  local enum_descs = flat["x-enumDescriptions"]
  -- strip leading quote so the user can type with or without it
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
-- Completion Request Dispatcher
--------------------------------------------------------------------------------

---@param context easytasks.LspBufferContext buffer context
---@param params lsp.CompletionParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.CompletionList)
function M.handler(context, params, callback)
  callback = vim.schedule_wrap(callback) -- this is important for neovim to accept changes
  local empty = { isIncomplete = false, items = {} }
  if not context.schema then
    callback(nil, empty); return
  end

  local row    = params.position.line
  local col    = params.position.character
  local line   = vim.api.nvim_buf_get_lines(context.bufnr, row, row + 1, false)[1] or ""
  local before = line:sub(1, col)

  -- ── Section header: line starts with `[` or `[[` ────────────────────────
  if before:match("^%s*%[") then
    local is_aot  = before:match("^%s*%[%[") ~= nil
    local inner   = (is_aot and before:match("%[%[(.*)$") or before:match("%[(.*)$")) or ""
    local prefix  = inner:gsub("%s", "")

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

  local container = resolve_container(context, row, col)

  -- ── Value context: AST-based detection ───────────────────────────────────
  -- Using node_at avoids false triggers (e.g. `=` inside a string value).
  do
    local hit  = context.ast and context.ast:node_at(row, col)
    local node = hit and hit.node

    if node and node.kind == NodeKind.KeyValuePair and col > node.key.range[4] then
      -- Cursor is after the `=` of a key-value pair.
      -- Key extraction is safe here: we know `=` is the assignment operator.
      local raw_key = before:match("^%s*(.-)%s*=") or ""
      raw_key       = raw_key:gsub("[\"']", "")
      local kpath   = container
      for _, seg in ipairs(vim.split(raw_key, ".", { plain = true })) do
        local s = seg:match("^%s*(.-)%s*$") or seg
        if s ~= "" then kpath = utils.join_path(kpath, s) end
      end
      -- Prefix: text after `=` up to cursor (covers both nil value and partial bare value).
      local after_eq = before:match("=(.*)$") or ""
      local prefix   = after_eq:match("^%s*(.*)$") or ""
      local flat     = schema_nav.schema_at(context.schema, context.data, kpath)
      callback(nil, { isIncomplete = false, items = value_items(flat, prefix) })
      return
    elseif node and node.kind == NodeKind.Literal then
      -- Cursor is inside an existing literal value.
      -- Use decode_tree for the full path (handles dotted keys, inline tables, etc.).
      local dt_path = context.decode_tree and context.decode_tree:pos_to_path(row, col)
      if dt_path then
        local prefix = before:sub(node.range[2] + 1)
        local flat   = schema_nav.schema_at(context.schema, context.data, dt_path)
        callback(nil, { isIncomplete = false, items = value_items(flat, prefix) })
        return
      end
      callback(nil, empty); return
    end
  end

  -- ── Key context ───────────────────────────────────────────────────────────
  local prefix   = before:match("^%s*(.-)%s*$") or ""
  local flat     = schema_nav.schema_at(context.schema, context.data, container)
  local existing = defined_keys_at(context, container)
  local items    = key_items(flat, existing, prefix)
  callback(nil, { isIncomplete = false, items = items })
end

return M
