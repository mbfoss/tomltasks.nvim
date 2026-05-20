-- easytasks/lsp/hover.lua
local M = {}

local s_util = require("easytasks.toml.schema_util")

--------------------------------------------------------------------------------
-- Markdown Formatting Helpers
--------------------------------------------------------------------------------

---@param node table?
---@return string|nil
local function hover_text(node)
  if not node then
    return nil
  end

  local lines = {}
  if node.title then
    lines[#lines + 1] = "**" .. node.title .. "**"
  end
  if node.description then
    lines[#lines + 1] = node.description
  end

  local type_label = s_util.get_type_label(node)
  if type_label ~= "any" then
    lines[#lines + 1] = ("Type: `%s`"):format(type_label)
  end

  local default_val = s_util.get_default_toml(node)
  if default_val ~= "" then
    lines[#lines + 1] = ("Default: `%s`"):format(default_val)
  end

  if node.required and #node.required > 0 then
    lines[#lines + 1] = "Required keys: " .. table.concat(node.required, ", ")
  end

  if #lines == 0 then
    return nil
  end
  return table.concat(lines, "\n\n")
end

--------------------------------------------------------------------------------
-- AST Structural Fallback Tracing
--------------------------------------------------------------------------------

--- Traces down an alternative path context using the AST when pointer maps are incomplete
---@param ast table The Tree AST instance
---@param target_row integer
---@return string[] path_segments, string? active_key
local function trace_path_from_ast(ast, target_row)
  local active_segments = {}
  local active_key = nil
  if not ast or type(ast.walk_tree) ~= "function" then return active_segments, active_key end

  ast:walk_tree(function(_, node, _)
    if (node.kind == "TableSection" or node.kind == "PartialTableSection") and node.range and node.range[1] <= target_row then
      active_segments = {}
      if node.keys then
        for _, key_tok in ipairs(node.keys) do
          table.insert(active_segments, key_tok.value)
        end
      end
    end
    if node.range and node.range[1] == target_row then
      if node.kind == "KeyValuePair" or node.kind == "PartialKeyValuePair" then
        if node.key and node.key.value then
          active_key = node.key.value
        end
      end
    end
    return true
  end)

  return active_segments, active_key
end

--------------------------------------------------------------------------------
-- Hover Request Dispatcher
--------------------------------------------------------------------------------

---@param context easytasks.LspBufferContext buffer context
---@param params lsp.HoverParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.Hover)
function M.handler(context, params, callback)
  if not context.schema then
    callback(nil, nil)
    return
  end

  local row = params.position.line
  local col = params.position.character

  local pointer_map = context.parse_results and context.parse_results.pointer_map or {}
  local matched_path = nil
  local smallest_range_width = math.huge

  -- 1. Scan pointer_map to find the tightest matched structural path enclosing the cursor
  for path, range in pairs(pointer_map) do
    local s_row, s_col, e_row, e_col = range[1], range[2], range[3], range[4]

    local inside = true
    if row < s_row or row > e_row then inside = false end
    if row == s_row and col < s_col then inside = false end
    if row == e_row and col > e_col then inside = false end

    if inside then
      local width = (e_row - s_row) * 1000 + (e_col - s_col)
      if width < smallest_range_width then
        smallest_range_width = width
        matched_path = path
      end
    end
  end

  local node = context.schema

  -- 2. Traverse down the node layout resolving both dictionary properties and lists
  if matched_path and matched_path ~= "/" then
    for segment in matched_path:gmatch("[^/]+") do
      segment = segment:gsub("~1", "/"):gsub("~0", "~") -- unescape JSON-Pointer tokens

      if node and node.properties and node.properties[segment] then
        node = node.properties[segment]
      elseif node and tonumber(segment) and node.items then
        node = node.items
      else
        node = nil
        break
      end
    end
  end

  -- 3. AST Fallback parsing loop if pointer map resolving failed to lock a node target
  if (not matched_path or not node) and context.ast then
    local active_segments, active_key = trace_path_from_ast(context.ast, row)
    node = context.schema

    for _, segment in ipairs(active_segments) do
      if node and node.properties and node.properties[segment] then
        node = node.properties[segment]
      elseif node and node.items then
        node = node.items
      end
    end
    if active_key and node and node.properties and node.properties[active_key] then
      node = node.properties[active_key]
    end
  end

  -- 4. Stringify structural constraints to fulfill Markdown block protocol
  local contents = hover_text(node)
  if not contents then
    callback(nil, nil)
    return
  end

  callback(nil, {
    contents = {
      kind = "markdown",
      value = contents,
    },
  })
end

return M
