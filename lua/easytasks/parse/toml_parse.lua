local tinytoml = require("easytasks.parse.tinytoml")
local utils = require("easytasks.validate.validatorutils")

local M = {}

---@class easytasks.TomlParseResult
---@field ok boolean
---@field data table|nil
---@field pointer_map table<string, easytasks.Range4>
---@field syntax_errors easytasks.TomlSyntaxError[]
---@field err string|nil

---@class easytasks.TomlSyntaxError
---@field message string
---@field range easytasks.Range4

---@alias easytasks.Range4 { [1]: integer, [2]: integer, [3]: integer, [4]: integer }

---@param row integer
---@param line string
---@return easytasks.Range4
local function line_range(row, line)
  return { row, 0, row, #line }
end

---@param message string
---@return string
local function trim_message(message)
  message = message:gsub("^%s+", ""):gsub("%s+$", "")
  if #message > 300 then
    message = message:sub(1, 300) .. "…"
  end
  return message
end

---@param err string
---@return string
function M.clean_error_message(err)
  if type(err) ~= "string" or err == "" then
    return "syntax error"
  end

  err = err:gsub("^[%w%._/-]+:%d+:%s*", "")

  local msg = err:match("|\n\n(.-)\n\nSee https://toml%.io")
  if msg then
    return trim_message(msg)
  end

  msg = err:match("\n\n([^|\n][^\n]+)\n\nSee https://toml%.io")
  if msg and not msg:match("^In '") then
    return trim_message(msg)
  end

  msg = err:gsub("^%s*In '[^']*', line %d+:%s*", "")
  msg = msg:gsub("^\n+", "")
  msg = msg:gsub("^%d+%s*|[^\n]*\n+", "")
  msg = msg:gsub("\n*See https://toml%.io[^\n]*", "")
  msg = trim_message(msg)

  if msg == "" then
    return "syntax error"
  end
  return msg
end

---@param err string
---@param lines string[]
---@return easytasks.TomlSyntaxError
local function syntax_error_from_err(err, lines)
  local line_num = tonumber(err:match("line (%d+)")) or 1
  local row = math.max(0, line_num - 1)
  local line_text = lines[row + 1] or ""

  return {
    message = M.clean_error_message(err),
    range = line_range(row, line_text),
  }
end

---@param pointer_map table<string, easytasks.Range4>
---@param path string[]
---@return integer
local function section_end_row(pointer_map, path)
  local prefix = utils.join_path_parts(path)
  local end_row = 0
  for ptr, range in pairs(pointer_map) do
    if ptr == prefix or (prefix ~= "/" and vim.startswith(ptr, prefix .. "/")) then
      end_row = math.max(end_row, range[3])
    end
  end
  return end_row
end

---@param bufnr integer
---@param path string[]
---@return integer 0-based row to insert new keys after
function M.table_end_row(bufnr, path)
  local parsed = M.parse(bufnr)
  return math.max(0, section_end_row(parsed.pointer_map, path))
end

---@param bufnr integer
---@return string
function M.buf_text(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

---@param _bufnr integer
---@param pointer string
---@param pointer_map table<string, easytasks.Range4>
---@return easytasks.Range4?
function M.range_for_pointer(_bufnr, pointer, pointer_map)
  if pointer_map[pointer] then
    return pointer_map[pointer]
  end

  local parts = utils.split_path(pointer)
  if #parts == 0 then
    return pointer_map["/"]
  end

  if #parts >= 2 then
    local key = parts[#parts]
    local table_path = vim.list_slice(parts, 1, #parts - 1)
    local ptr = utils.join_path_parts(vim.list_extend(vim.deepcopy(table_path), { key }))
    if pointer_map[ptr] then
      return pointer_map[ptr]
    end
  end

  local table_ptr = utils.join_path_parts(parts)
  if pointer_map[table_ptr] then
    return pointer_map[table_ptr]
  end

  if #parts >= 2 then
    local table_path = vim.list_slice(parts, 1, #parts - 1)
    return pointer_map[utils.join_path_parts(table_path)]
  end

  return nil
end

---@param bufnr integer
---@return easytasks.TomlParseResult
function M.parse(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = M.buf_text(bufnr)
  local empty_map = { ["/"] = { 0, 0, 0, 0 } }

  if text == "" then
    return {
      ok = true,
      data = {},
      pointer_map = empty_map,
      syntax_errors = {},
    }
  end

  local ok, result = pcall(tinytoml.parse, text, { load_from_string = true })
  if not ok then
    local err = result --[[@as string]]
    return {
      ok = false,
      data = nil,
      pointer_map = empty_map,
      syntax_errors = { syntax_error_from_err(err, lines) },
      err = err,
    }
  end

  ---@cast result { data: table, pointer_map: table<string, easytasks.Range4> }
  return {
    ok = true,
    data = result.data,
    pointer_map = result.pointer_map,
    syntax_errors = {},
  }
end

return M
