---@class easytasks.LspBufferContext
---@field bufnr         number
---@field ast           easytasks.toml.Ast
---@field parse_errors  table
---@field data          any
---@field decode_errors table
---@field decode_tree   easytasks.toml.DecodeTree
---@field schema        table|nil   JSON schema assigned to this buffer
---@field parse_results table|nil   Last known output (data, errors)
---@field last_updated  integer|nil Timestamp or btick when the cache was updated
---@field config        table|nil   Optional buffer-local configuration overrides
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
