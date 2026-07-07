local M = {}

---@param str string
---@param len number
---@return string
function M.pad_right(str, len)
	return str .. string.rep(" ", math.max(0, len - #str))
end

---@param lines string[] list of strings (may contain newlines)
---@return string[] flattened list of strings (no embedded newlines)
function M.prepare_buffer_lines(lines)
	local out = {}
	for _, line in ipairs(lines) do
		vim.list_extend(out, vim.fn.split(line, "\n", true))
	end
	return out
end

---@param str string
---@param max_len number
---@param right? boolean  crop from the left, keeping the end of the string
---@return string preview
---@return boolean is_different
function M.crop_for_ui(str, max_len, right)
    assert(type(str) == 'string', str)
    max_len = max_len > 2 and max_len or 2
    if #str <= max_len then return str, false end
    if right then
        return "…" .. str:sub(#str - max_len + 2), true
    end
    return str:sub(1, max_len - 1) .. "…", true
end

---@param path string
---@param patterns string[]
---@return boolean
function M.matches_any(path, patterns)
	for _, pattern in ipairs(patterns) do
		local regex = vim.fn.glob2regpat(pattern)
		if vim.fn.match(path, regex) ~= -1 then
			return true
		end
	end
	return false
end

---@param str string
---@return string
function M.human_case(str)
	str = str:gsub("_", " ")
	str = str:gsub("(%l)(%u)", "%1 %2")
	str = str:gsub("(%a)([%w']*)", function(first, rest)
		return first:upper() .. rest:lower()
	end)

	return str
end

local function _escape_shell_arg(arg)
	arg = arg or ""
	if arg:match('[%s;&|$`"\'<>]') then
		arg = "'" .. (arg:gsub("'", "'\\''")) .. "'"
	end
	return arg
end

---@param cmd_and_args string[]
---@return string
function M.get_shell_command(cmd_and_args)
	local parts = {}
	for i, str in ipairs(cmd_and_args) do
		table.insert(parts, _escape_shell_arg(str))
	end
	return table.concat(parts, " ")
end

---@param errors string[]|nil
---@return string[]
function M.indent_errors(errors, parent_msg)
	errors = errors or {}
	errors = vim.tbl_map(function(v)
		if type(v) == 'string' then
			return '  ' .. v
		else
			return '  ' .. vim.inspect(v)
		end
	end, errors or {})
	table.insert(errors, 1, parent_msg)
	return errors
end

---@param str string
---@return string[]
function M.split_shell_args(str)
	local args = {}
	local i = 1
	local len = #str

	local function skip_ws()
		while i <= len and str:sub(i, i):match("%s") do
			i = i + 1
		end
	end

	local function add(part)
		if part ~= "" then table.insert(args, part) end
	end

	while i <= len do
		skip_ws()
		if i > len then break end

		local part = {}
		local in_quote = nil

		while i <= len do
			local c = str:sub(i, i)
			local nxt = str:sub(i + 1, i + 1)
			if not in_quote and c:match("%s") then break end
			if not in_quote and (c == '"' or c == "'") then
				in_quote = c
				i = i + 1
				goto continue
			end
			if in_quote and c == in_quote then
				in_quote = nil
				i = i + 1
				goto continue
			end
			if c == "\\" and i + 1 <= len then
				local esc = nxt
				if esc == "\n" then
					i = i + 2 -- line continuation
				else
					table.insert(part, esc)
					i = i + 2
				end
				goto continue
			end

			table.insert(part, c)
			i = i + 1
			::continue::
		end
		if in_quote then
			table.insert(part, 1, in_quote)
		end

		add(table.concat(part))
	end

	return args
end

---@param cmd string|string[]
---@return string[]
function M.cmd_to_string_array(cmd)
	if type(cmd) == "string" then
		local arr = M.split_shell_args(cmd)
		assert(type(arr) == "table")
		return arr
	elseif type(cmd) == "table" then
		return cmd
	end
	return {}
end

function M.clean_and_split_lines(lines)
	local result = {}
	for _, line in ipairs(lines) do
		line = line:gsub("\r", "")
		for part in line:gmatch("([^\n]*)\n?") do
			if part ~= "" then
				table.insert(result, part)
			end
		end
	end
	return result
end

---@param callback fun(lines: string[]) The function to call for complete lines.
---@return fun(chunk: string) feed The function to call whenever new data arrives.
function M.create_line_buffered_feed(callback)
	local residue = ""
	return function(chunk)
		if not chunk or chunk == "" then
			return
		end

		local data = residue .. chunk
		local start = 1
		local lines = {}

		while true do
			local newline_start, newline_end = data:find("\r?\n", start)
			if not newline_start then
				break
			end

			lines[#lines + 1] = data:sub(start, newline_start - 1)
			start = newline_end + 1
		end

		residue = data:sub(start)

		if #lines > 0 then
			callback(lines)
		end
	end
end

---@param globs string[]
---@return vim.regex[]
function M.compile_globs(globs)
	local compiled = {}
	for _, g in ipairs(globs) do
		table.insert(compiled, vim.regex(vim.fn.glob2regpat(g)))
	end
	return compiled
end

---@param str string
---@param regex_list vim.regex[]
---@return boolean
function M.any_match(str, regex_list)
	for _, pat in ipairs(regex_list) do
		if pat:match_str(str) then
			return true
		end
	end
	return false
end

---@param path string
---@param is_dir boolean
---@param include_regex vim.regex[]?
---@param exclude_regex vim.regex[]?
---@return boolean
function M.check_path_pattern(path, is_dir, include_regex, exclude_regex)
	if is_dir and path:sub(-1) == "/" then
		path = path:sub(1, #path - 1)
	end
	if exclude_regex then
		if M.any_match(path, exclude_regex) then
			return false
		end
		if is_dir and M.any_match(path .. '/', exclude_regex) then
			return false
		end
	end
	if include_regex then
		return M.any_match(path, include_regex)
	end
	return true
end

return M
