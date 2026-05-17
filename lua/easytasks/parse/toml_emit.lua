local tinytoml = require("easytasks.parse.tinytoml")

local M = {}

---@param data table
---@return string
function M.format_data(data)
  return tinytoml.encode(data, { allow_multiline_strings = true })
end

return M
