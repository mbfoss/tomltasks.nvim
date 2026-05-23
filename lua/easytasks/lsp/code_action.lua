-- easytasks/lsp/code_actions.lua
local M = {}

local s_util = require("easytasks.toml.schema_util")

--------------------------------------------------------------------------------
-- LSP Range & Item Mapping Formatter Helpers
--------------------------------------------------------------------------------

--- Serializes the bidirectional tree node layout into a readable comment string format
---@param ast table The Tree AST instance
---@return string
local function dump_ast_to_string(ast)
  local lines = { "# --- Easytasks TOML AST Dump ---", "#" }

  if not ast or type(ast.walk_tree) ~= "function" then
    table.insert(lines, "# No valid Tree AST instance found.")
  else
    ast:walk_tree(function(id, node, depth)
      local indent = string.rep("  ", depth or 0)
      local info = string.format("# %s* [%s] id: %s", indent, node.kind, id)

      if node.range then
        info = info ..
            string.format(" range: (%d,%d)->(%d,%d)", node.range[1], node.range[2], node.range[3], node.range[4])
      end

      if node.key then
        info = info .. string.format(" key: %q", tostring(node.key.value))
      elseif node.keys then
        local section_keys = {}
        for _, k in ipairs(node.keys) do table.insert(section_keys, k.value) end
        info = info .. string.format(" keys: [%s]", table.concat(section_keys, "."))
      end

      if node.kind == "Literal" and node.token then
        info = info .. string.format(" val: %s (%s)", tostring(node.token.value), node.token.type)
      end

      table.insert(lines, info)
      return true
    end)
  end

  return table.concat(lines, "\n") .. "\n"
end

--- Serializes a Lua table recursively into a comment block representation
---@param val any The table value value data object
---@param depth integer? Indentation depth tracking
---@return string
local function serialize_decoder_val(val, depth)
  depth = depth or 0
  local indent = string.rep("  ", depth)

  if type(val) == "table" then
    local parts = { "{\n" }
    for k, v in pairs(val) do
      local key_str = type(k) == "string" and string.format("[%q]", k) or string.format("[%s]", tostring(k))
      table.insert(parts, string.format("%s  %s = %s,\n", indent, key_str, serialize_decoder_val(v, depth + 1)))
    end
    table.insert(parts, indent .. "}")
    return table.concat(parts)
  elseif type(val) == "string" then
    return string.format("%q", val)
  else
    return tostring(val)
  end
end

--- Serializes evaluated decoder workspace maps into text comments
---@param data table|nil Extracted workspace variables map
---@return string
local function dump_decoder_to_string(data)
  local lines = { "# --- Easytasks TOML Decoder Data Dump ---", "#" }

  if not data then
    table.insert(lines, "# No successfully decoded data context available.")
  else
    local serialized = serialize_decoder_val(data)
    for line in serialized:gmatch("[^\r\n]+") do
      table.insert(lines, "# " .. line)
    end
  end

  return table.concat(lines, "\n") .. "\n"
end

--- Serializes the DecodeTree node layout (paths, ranges, schema presence, errors) into comment text
---@param decode_tree easytasks.toml.DecodeTree|nil
---@return string
local function dump_decode_tree_to_string(decode_tree)
  local lines = { "# --- Easytasks TOML DecodeTree Dump ---", "#" }

  if not decode_tree or type(decode_tree._tree) ~= "table" or type(decode_tree._tree.walk_tree) ~= "function" then
    table.insert(lines, "# No valid DecodeTree instance found.")
  else
    decode_tree._tree:walk_tree(function(id, data, depth)
      local indent = string.rep("  ", depth or 0)
      local info = string.format("# %s* [id:%s] key: %q", indent, tostring(id), tostring(data.key))

      if data.range then
        info = info .. string.format(" range: (%d,%d)->(%d,%d)", data.range[1], data.range[2], data.range[3], data.range[4])
      else
        info = info .. " range: nil"
      end

      if data.schema then
        local schema_type = data.schema.type and tostring(data.schema.type) or "?"
        info = info .. string.format(" schema: {type=%s}", schema_type)
      end

      if data.errors and #data.errors > 0 then
        info = info .. string.format(" errors: [%s]", table.concat(data.errors, "; "))
      end

      table.insert(lines, info)
      return true
    end)
  end

  return table.concat(lines, "\n") .. "\n"
end

--- Serializes cached active pipeline workspace runtime errors into text comments
---@param parse_results table|nil Current context cached validation metadata maps
---@return string
local function dump_errors_to_string(parse_results)
  local lines = { "# --- Easytasks Active Diagnostics Error Dump ---", "#" }

  local errors = parse_results and parse_results.errors or {}
  if #errors == 0 then
    table.insert(lines, "# No active parsing, semantic, or validation errors found.")
  else
    for i, err in ipairs(errors) do
      local range_str = ""
      if err.range then
        range_str = string.format(" (%d,%d)->(%d,%d)", err.range[1], err.range[2], err.range[3], err.range[4])
      end
      table.insert(lines, string.format("# [%d] Error%s: %s", i, range_str, err.message or err.err_msg or tostring(err)))
    end
  end

  return table.concat(lines, "\n") .. "\n"
end

--------------------------------------------------------------------------------
-- AST Navigation Helpers
--------------------------------------------------------------------------------

--- Traces the active structural table path segments by walking the Tree up to the row position
---@param ast table The Tree AST instance
---@param target_row integer
---@return string[] path_segments
local function find_active_table_path_from_tree(ast, target_row)
  local active_segments = {}
  if not ast or type(ast.walk_tree) ~= "function" then return active_segments end

  local highest_table_row = -1

  ast:walk_tree(function(_, node, _)
    if node.kind == "TableSection" and node.range then
      local start_row = node.range[1]
      if start_row <= target_row and start_row > highest_table_row then
        highest_table_row = start_row
        active_segments = {}
        if node.keys then
          for _, key_tok in ipairs(node.keys) do
            table.insert(active_segments, key_tok.value)
          end
        end
      end
    end
    return true
  end)

  return active_segments
end

--- Collects any sibling keys defined within the active table block context via Tree traversal
---@param ast table The Tree AST instance
---@param target_row integer
---@return table<string, boolean> existing_keys
local function get_sibling_keys_from_tree(ast, target_row)
  local existing_keys = {}
  if not ast or type(ast.walk_tree) ~= "function" then return existing_keys end

  local active_table_start_row = -1

  ast:walk_tree(function(_, node, _)
    if (node.kind == "TableSection" or node.kind == "PartialTableSection") and node.range then
      if node.range[1] <= target_row and node.range[1] > active_table_start_row then
        active_table_start_row = node.range[1]
      end
    end
    return true
  end)

  local within_active_block = (active_table_start_row == -1)
  ast:walk_tree(function(_, node, _)
    if (node.kind == "TableSection" or node.kind == "PartialTableSection") and node.range then
      within_active_block = (node.range[1] == active_table_start_row)
    elseif node.kind == "KeyValuePair" or node.kind == "PartialKeyValuePair" then
      if within_active_block and node.range and node.range[1] <= target_row then
        if node.key and node.key.value then
          existing_keys[node.key.value] = true
        end
      end
    end
    return true
  end)

  return existing_keys
end

--------------------------------------------------------------------------------
-- Code Actions Request Dispatcher
--------------------------------------------------------------------------------

---@param context easytasks.LspBufferContext buffer context tracking
---@param params lsp.CodeActionParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.CodeAction[])
function M.handler(context, params, callback)
  local actions = {}
  local bufnr = context.bufnr or vim.uri_to_bufnr(params.textDocument.uri)
  local row = params.range.start.line

  if not context.ast then
    callback(nil, actions)
    return
  end

  -- Action 1: Dump structural Tree AST text directly into the file buffer as comments
  local ast_comments = dump_ast_to_string(context.ast)
  table.insert(actions, {
    title = "🔍 Dump Easytasks TOML AST Graph",
    kind = vim.lsp.protocol.CodeActionKind.RefactorExtract,
    edit = {
      changes = {
        [params.textDocument.uri] = {
          {
            range = {
              start = { line = row + 1, character = 0 },
              ["end"] = { line = row + 1, character = 0 },
            },
            newText = ast_comments,
          }
        }
      }
    }
  })

  -- Action 2: Dump runtime structural evaluation dictionary maps directly into the file buffer as comments
  local decoded_data = context.parse_results and context.parse_results.data
  local decoder_comments = dump_decoder_to_string(decoded_data)
  table.insert(actions, {
    title = "📋 Dump Easytasks Decoded Data Object",
    kind = vim.lsp.protocol.CodeActionKind.RefactorExtract,
    edit = {
      changes = {
        [params.textDocument.uri] = {
          {
            range = {
              start = { line = row + 1, character = 0 },
              ["end"] = { line = row + 1, character = 0 },
            },
            newText = decoder_comments,
          }
        }
      }
    }
  })

  -- Action 3: Dump DecodeTree node layout into the file buffer as comments
  local decode_tree_comments = dump_decode_tree_to_string(context.decode_tree)
  table.insert(actions, {
    title = "🌲 Dump Easytasks DecodeTree",
    kind = vim.lsp.protocol.CodeActionKind.RefactorExtract,
    edit = {
      changes = {
        [params.textDocument.uri] = {
          {
            range = {
              start = { line = row + 1, character = 0 },
              ["end"] = { line = row + 1, character = 0 },
            },
            newText = decode_tree_comments,
          }
        }
      }
    }
  })

  -- Action 5: Dump tracking diagnostics array state errors directly into the file buffer as comments
  local error_comments = dump_errors_to_string(context.parse_results)
  table.insert(actions, {
    title = "❌ Dump Active Diagnostics Pipeline Errors",
    kind = vim.lsp.protocol.CodeActionKind.RefactorExtract,
    edit = {
      changes = {
        [params.textDocument.uri] = {
          {
            range = {
              start = { line = row + 1, character = 0 },
              ["end"] = { line = row + 1, character = 0 },
            },
            newText = error_comments,
          }
        }
      }
    }
  })

  -- Action 6: Autofill missing configuration elements matching core scheme requirements
  if context.schema then
    local active_segments = find_active_table_path_from_tree(context.ast, row)

    local schema_node = context.schema
    for _, segment in ipairs(active_segments) do
      if schema_node and schema_node.properties and schema_node.properties[segment] then
        schema_node = schema_node.properties[segment]
      end
    end

    if schema_node and schema_node.properties then
      local existing_keys = get_sibling_keys_from_tree(context.ast, row)
      local missing_required = {}

      for _, entry in ipairs(s_util.get_ordered_properties(schema_node)) do
        if not existing_keys[entry.key] and s_util.is_required(schema_node, entry.key) then
          local default_val = s_util.get_default_toml(entry.schema)
          if default_val == "" then default_val = '""' end
          table.insert(missing_required, string.format("%s = %s", entry.key, default_val))
        end
      end

      if #missing_required > 0 then
        local text_to_insert = table.concat(missing_required, "\n") .. "\n"

        table.insert(actions, {
          title = "💡 Autofill Missing Required Fields",
          kind = vim.lsp.protocol.CodeActionKind.QuickFix,
          edit = {
            changes = {
              [params.textDocument.uri] = {
                {
                  range = {
                    start = { line = row + 1, character = 0 },
                    ["end"] = { line = row + 1, character = 0 },
                  },
                  newText = text_to_insert,
                }
              }
            }
          }
        })
      end
    end
  end

  callback(nil, actions)
end

return M
