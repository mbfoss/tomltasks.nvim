---@class easytasks.LspBufferContext
---@field bufnr number
---@field ast easytasks.util.Tree
---@field parse_errors table
---@field node_at fun(r: integer, c: integer): easytasks.toml.NodeAtResult?
---@field data any
---@field decode_errors table
---@field location_tree easytasks.util.Tree
---@field pos_to_location fun(row: integer, col: integer): string?
---@field location_to_pos fun(path: string): integer[]?
---@field schema table|nil The JSON schema assigned to this buffer
---@field parse_results table|nil Last known output from parser.parse(bufnr) (data, errors)
---@field last_updated integer|nil Timestamp or btick when the cache was updated
---@field config table|nil Optional buffer-local custom configuration overrides
---@field debounce_timer number?
local BufferContext = {}
BufferContext.__index = BufferContext

function BufferContext.new(...)
	local obj = setmetatable({}, BufferContext)
	obj:_init(...)
	return obj
end

---@private
function BufferContext:_init(bufnr)
	vim.validate("bufnr", bufnr, "number")
	self.bufnr = bufnr
end

return BufferContext
