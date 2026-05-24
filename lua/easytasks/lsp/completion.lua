local M          = {}

local s_util     = require("easytasks.toml.schema_util")
local utils      = require("easytasks.toml.validatorutils")
local schema_nav = require("easytasks.lsp.schema_nav")
local NodeKind   = require("easytasks.toml.parser_util").NodeKind

local CK         = vim.lsp.protocol.CompletionItemKind

--------------------------------------------------------------------------------
-- AST helpers
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

-- Collect key names already defined in a section (nil → root scope).
---@param ast        easytasks.toml.Ast
---@param section_id any
---@return table<string, boolean>
local function defined_keys(ast, section_id)
  local keys  = {}
  local iter = section_id and ast:iter_children(section_id) or ast:iter_roots()
  for _, data in iter do
    if data and data.kind == NodeKind.KeyValuePair then
      keys[data.key.value] = true
    end
  end
  return keys
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
        insertText       = prop.key .. " = " .. (default ~= "" and default or ""),
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
  -- strip leading `"` so the user can type without it and still get matches
  local match_pfx  = prefix:match('^"?(.*)$') or prefix

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
  if vim.tbl_contains(types, "null") then
    if s_util.matches_filter(match_pfx, "null") then
      table.insert(items, { label = "null", kind = CK.Value })
    end
  end
  if vim.tbl_contains(types, "string") then
    if s_util.matches_filter(match_pfx, '""') then
      table.insert(items, {
        label = '""',
        kind = CK.Value,
        insertTextFormat = vim.lsp.protocol.InsertTextFormat.Snippet,
        insertText = '"$1"',
      })
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

  local sec_id, sec_node = section_at_row(context.ast, row)
  local spath = section_path(context.ast, sec_id, sec_node)

  -- ── Value context: `=` is present on the line before the cursor ──────────
  if before:match("=") then
    local raw_key = before:match("^%s*(.-)%s*=") or ""
    raw_key       = raw_key:gsub("[\"']", ""):match("^%s*(.-)%s*$") or ""

    -- Support dotted keys (e.g. `foo.bar = ...`)
    local kpath   = spath
    for _, seg in ipairs(vim.split(raw_key, ".", { plain = true })) do
      if seg ~= "" then kpath = utils.join_path(kpath, seg) end
    end

    local after  = before:match("=(.*)$") or ""
    local prefix = after:match("^%s*(.-)%s*$") or ""

    local flat   = schema_nav.schema_at(context.schema, context.data, kpath)
    local items  = value_items(flat, prefix)
    callback(nil, { isIncomplete = false, items = items })
    return
  end

  -- ── Key context ───────────────────────────────────────────────────────────
  local prefix   = before:match("^%s*(.-)%s*$") or ""
  local flat     = schema_nav.schema_at(context.schema, context.data, spath)
  local existing = defined_keys(context.ast, sec_id)
  local items    = key_items(flat, existing, prefix)
  callback(nil, { isIncomplete = false, items = items })
end

return M
