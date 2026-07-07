---@brief FFI wrapper around the PCRE2 (8-bit) regular expression library.
---
--- Patterns are compiled once with `regex.compile()` and matched many times via
--- the returned `Regex` object. A few stdlib-shaped convenience functions
--- (`regex.match`, `regex.find`, `regex.test`, `regex.gmatch`, `regex.gsub`)
--- compile-and-run against a small internal cache.
---
--- All offsets exposed to Lua are byte based. `find` returns 1-based inclusive
--- offsets like `string.find`; `compile`/`match`/`gmatch`/`gsub` mirror the
--- corresponding `string.*` semantics.
---
--- Requires LuaJIT (Neovim) and a loadable `libpcre2-8` shared library.

local ffi = require("ffi")
local bit = require("bit")
local LRU = require("easytasks.tk.LRU")

local M = {}

-- PCRE2 compile options (subset). See pcre2_compile(3).
---@enum easytasks.tk.regex.opt
M.opt = {
	CASELESS = 0x00000008,
	MULTILINE = 0x00000400,
	DOTALL = 0x00000020,
	EXTENDED = 0x00000080,
	UNGREEDY = 0x00000040,
	ANCHORED = 0x80000000,
	UTF = 0x00080000,
	UCP = 0x00020000,
	DUPNAMES = 0x00000010,
}

-- PCRE2 match-time options (subset). See pcre2_match(3).
---@enum easytasks.tk.regex.match_opt
M.match_opt = {
	NOTBOL = 0x00000001,
	NOTEOL = 0x00000002,
	NOTEMPTY = 0x00000004,
	NOTEMPTY_ATSTART = 0x00000008,
	ANCHORED = 0x80000000,
}

local _INFO_CAPTURECOUNT = 4
local _ERROR_NOMATCH = -1
local _ERRBUF_LEN = 256

-- Single-char compile flags accepted by the `flags` string argument.
local _STR_FLAGS = {
	i = M.opt.CASELESS,
	m = M.opt.MULTILINE,
	s = M.opt.DOTALL,
	x = M.opt.EXTENDED,
	U = M.opt.UNGREEDY,
	A = M.opt.ANCHORED,
	-- 'u' is handled specially below (UTF + UCP)
}

--------------------------------------------------------------------------------
-- FFI declarations + library loading
--------------------------------------------------------------------------------

-- Opaque structs are referenced only through pointers, so empty forward
-- declarations are enough. The `_8` suffix selects the 8-bit code unit build.
-- cdef is process-global; a second require (e.g. across test runs) would
-- otherwise raise "attempt to redefine", so swallow that case.
pcall(ffi.cdef, [[
		typedef struct neotoolkit_pcre2_code         pcre2_code_8;
		typedef struct neotoolkit_pcre2_match_data   pcre2_match_data_8;
		typedef struct neotoolkit_pcre2_compile_ctx  pcre2_compile_context_8;
		typedef struct neotoolkit_pcre2_match_ctx    pcre2_match_context_8;

		pcre2_code_8 *pcre2_compile_8(const char *pattern, size_t length,
			uint32_t options, int *errorcode, size_t *erroroffset,
			pcre2_compile_context_8 *ccontext);
		void pcre2_code_free_8(pcre2_code_8 *code);

		pcre2_match_data_8 *pcre2_match_data_create_from_pattern_8(
			const pcre2_code_8 *code, void *gcontext);
		void pcre2_match_data_free_8(pcre2_match_data_8 *match_data);

		int pcre2_match_8(const pcre2_code_8 *code, const char *subject,
			size_t length, size_t startoffset, uint32_t options,
			pcre2_match_data_8 *match_data, pcre2_match_context_8 *mcontext);

		size_t *pcre2_get_ovector_pointer_8(pcre2_match_data_8 *match_data);
		uint32_t pcre2_get_ovector_count_8(pcre2_match_data_8 *match_data);

		int pcre2_get_error_message_8(int errorcode, unsigned char *buffer,
			size_t bufflen);
		int pcre2_substring_number_from_name_8(const pcre2_code_8 *code,
			const char *name);
		int pcre2_pattern_info_8(const pcre2_code_8 *code, uint32_t what,
			void *where);
	]])

---@type ffi.namespace*?
local _lib = nil
---@type string?
local _load_err = nil
local _tried_load = false

local _errbuf = ffi.new("unsigned char[?]", _ERRBUF_LEN)
local _UNSET = ffi.cast("size_t", -1)

--- Load the PCRE2 library once, caching success/failure.
---@return ffi.namespace*? lib, string? err
local function _ensure_lib()
	if _lib then
		return _lib
	end
	if _tried_load then
		return nil, _load_err
	end
	_tried_load = true

	-- ffi.load canonicalizes the bare name to libpcre2-8.so / .dylib per platform.
	local ok, lib_or_err = pcall(ffi.load, "pcre2-8")
	if not ok then
		_load_err = "could not load libpcre2-8: " .. tostring(lib_or_err)
		return nil, _load_err
	end

	-- Confirm the 8-bit symbols are actually present.
	if not pcall(function()
		return lib_or_err.pcre2_compile_8
	end) then
		_load_err = "libpcre2-8 loaded but is missing its 8-bit (pcre2_*_8) symbols"
		return nil, _load_err
	end

	_lib = lib_or_err
	return _lib
end

---@param code integer PCRE2 error code
---@return string
local function _err_message(code)
	if not _lib then
		return ("PCRE2 error %d"):format(code)
	end
	local n = _lib.pcre2_get_error_message_8(code, _errbuf, _ERRBUF_LEN)
	if n < 0 then
		return ("PCRE2 error %d"):format(code)
	end
	return ffi.string(_errbuf, n)
end

--- Convert an FFI integer cdata (size_t / uint32_t offset) to a Lua integer.
--- PCRE2 offsets always fit a Lua number, so the `or 0` is only to satisfy the
--- type checker that the result is never nil.
---@param value any
---@return integer
local function _to_int(value)
	return math.floor(tonumber(value) or 0)
end

--------------------------------------------------------------------------------
-- Flag parsing
--------------------------------------------------------------------------------

---@param flags string|integer|nil  flag chars ("imsxuUA"), raw option bits, or nil
---@return integer options
local function _parse_flags(flags)
	if flags == nil then
		return 0
	end
	if type(flags) == "number" then
		return flags
	end
	assert(type(flags) == "string", "regex flags must be a string or number")

	local opts = 0
	for i = 1, #flags do
		local c = flags:sub(i, i)
		if c == "u" then
			opts = bit.bor(opts, M.opt.UTF, M.opt.UCP)
		else
			local o = _STR_FLAGS[c]
			assert(o, "unknown regex flag: " .. c)
			opts = bit.bor(opts, o)
		end
	end
	return opts
end

---@param init integer? 1-based start index (negative counts from the end)
---@param len integer subject byte length
---@return integer offset 0-based byte offset clamped to [0, len]
local function _init_offset(init, len)
	if not init or init == 0 then
		return 0
	end
	local off
	if init > 0 then
		off = init - 1
	else
		off = len + init
	end
	if off < 0 then
		return 0
	elseif off > len then
		return len
	end
	return off
end

--------------------------------------------------------------------------------
-- Regex object
--------------------------------------------------------------------------------

---@class easytasks.tk.Regex
---@field private _lib ffi.namespace* the loaded libpcre2-8 handle
---@field private _code ffi.cdata* compiled pcre2_code_8*
---@field private _md ffi.cdata* match data bound to this pattern
---@field private _ncaptures integer number of capturing groups (excludes group 0)
local Regex = {}
Regex.__index = Regex

--- Run a single match starting at `offset` (0-based byte offset).
---@param subject string
---@param offset integer 0-based byte offset
---@return ffi.cdata*? ovector size_t* on match, nil on no match
---@return integer rc number of valid ovector pairs
function Regex:_exec(subject, offset)
	local rc = self._lib.pcre2_match_8(self._code, subject, #subject, offset, 0, self._md, nil)
	if rc == _ERROR_NOMATCH then
		return nil, 0
	end
	if rc < 0 then
		error("pcre2_match: " .. _err_message(rc))
	end
	if rc == 0 then
		-- Ovector too small for every group; only the available pairs are set.
		rc = _to_int(self._lib.pcre2_get_ovector_count_8(self._md))
	end
	return self._lib.pcre2_get_ovector_pointer_8(self._md), rc
end

--- Extract capture group substrings (groups 1..n) from an ovector.
---@param subject string
---@param ovector ffi.cdata* size_t*
---@param rc integer number of valid ovector pairs
---@return (string|nil)[] captures, integer n (n == self._ncaptures)
function Regex:_captures(subject, ovector, rc)
	local caps = {}
	local n = self._ncaptures
	for i = 1, n do
		-- Group i is only set when i <= rc-1 and not explicitly unset.
		if i <= rc - 1 and ovector[2 * i] ~= _UNSET then
			local s = _to_int(ovector[2 * i])
			local e = _to_int(ovector[2 * i + 1])
			caps[i] = subject:sub(s + 1, e)
		else
			caps[i] = nil
		end
	end
	return caps, n
end

--- Whole-match substring from an ovector.
---@param subject string
---@param ovector ffi.cdata*
---@return string
local function _whole(subject, ovector)
	return subject:sub(_to_int(ovector[0]) + 1, _to_int(ovector[1]))
end

--- Test whether the pattern matches anywhere in `subject`.
---@param subject string
---@param init integer? 1-based start index
---@return boolean
function Regex:test(subject, init)
	local ov = self:_exec(subject, _init_offset(init, #subject))
	return ov ~= nil
end

--- Find the first match, returning 1-based inclusive byte offsets.
---@param subject string
---@param init integer? 1-based start index
---@return integer? start, integer? finish, (string|nil)[]? captures
function Regex:find(subject, init)
	local ov, rc = self:_exec(subject, _init_offset(init, #subject))
	if not ov then
		return nil
	end
	local s = _to_int(ov[0]) + 1
	local e = _to_int(ov[1])
	local caps = self:_captures(subject, ov, rc)
	return s, e, caps
end

--- Match like `string.match`: returns the capture groups if the pattern has
--- any, otherwise the whole match. Returns nil on no match.
---@param subject string
---@param init integer? 1-based start index
---@return ... string|nil
function Regex:match(subject, init)
	local ov, rc = self:_exec(subject, _init_offset(init, #subject))
	if not ov then
		return nil
	end
	if self._ncaptures == 0 then
		return _whole(subject, ov)
	end
	local caps, n = self:_captures(subject, ov, rc)
	return unpack(caps, 1, n)
end

--- Iterate over all non-overlapping matches, like `string.gmatch`.
--- Each step yields the captures (or whole match when there are no groups).
---@param subject string
---@return fun(): ...
function Regex:gmatch(subject)
	local offset = 0
	local len = #subject
	return function()
		if offset > len then
			return nil
		end
		local ov, rc = self:_exec(subject, offset)
		if not ov then
			offset = len + 1
			return nil
		end
		local mstart = _to_int(ov[0])
		local mend = _to_int(ov[1])
		-- Advance; bump past empty matches to guarantee progress.
		offset = (mend > mstart) and mend or (mend + 1)

		if self._ncaptures == 0 then
			return subject:sub(mstart + 1, mend)
		end
		local caps, n = self:_captures(subject, ov, rc)
		return unpack(caps, 1, n)
	end
end

--- Expand a string replacement template. `%0` is the whole match, `%1`..`%9`
--- are capture groups, and `%%` is a literal percent.
---@param template string
---@param subject string
---@param ovector ffi.cdata*
---@param rc integer
---@return string
function Regex:_expand(template, subject, ovector, rc)
	return (template:gsub("%%([%%0-9])", function(d)
		if d == "%" then
			return "%"
		end
		local i = tonumber(d)
		if i == 0 then
			return _whole(subject, ovector)
		end
		if i <= rc - 1 and ovector[2 * i] ~= _UNSET then
			return subject:sub(_to_int(ovector[2 * i]) + 1, _to_int(ovector[2 * i + 1]))
		end
		return ""
	end))
end

--- Substitute matches, like `string.gsub`.
---@param subject string
---@param repl string|fun(...):string? template string or function of the captures
---@param max integer? maximum number of substitutions
---@return string result, integer count
function Regex:gsub(subject, repl, max)
	local is_fn = type(repl) == "function"
	assert(is_fn or type(repl) == "string", "gsub replacement must be a string or function")

	local out = {}
	local len = #subject
	local offset = 0
	local count = 0

	while offset <= len do
		if max and count >= max then
			break
		end
		local ov, rc = self:_exec(subject, offset)
		if not ov then
			break
		end
		local mstart = _to_int(ov[0])
		local mend = _to_int(ov[1])

		out[#out + 1] = subject:sub(offset + 1, mstart) -- text before the match

		local rep
		if type(repl) == "function" then
			local r
			if self._ncaptures == 0 then
				r = repl(_whole(subject, ov))
			else
				local caps, n = self:_captures(subject, ov, rc)
				r = repl(unpack(caps, 1, n))
			end
			if r == nil or r == false then
				rep = _whole(subject, ov)
			elseif type(r) == "string" or type(r) == "number" then
				rep = tostring(r)
			else
				error("gsub replacement function must return string/number/nil/false")
			end
		else
			rep = self:_expand(repl, subject, ov, rc)
		end
		out[#out + 1] = rep
		count = count + 1

		if mend > mstart then
			offset = mend
		else
			-- Empty match: keep one source byte and step forward.
			if mend < len then
				out[#out + 1] = subject:sub(mend + 1, mend + 1)
			end
			offset = mend + 1
		end
	end

	out[#out + 1] = subject:sub(offset + 1) -- trailing text
	return table.concat(out), count
end

--- Resolve a named capture group to its 1-based group number.
---@param name string
---@return integer? number, string? err
function Regex:group_index(name)
	local n = self._lib.pcre2_substring_number_from_name_8(self._code, name)
	if n < 0 then
		return nil, _err_message(n)
	end
	return n
end

---@return integer count of capturing groups (excluding the whole match)
function Regex:count_captures()
	return self._ncaptures
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

---@return boolean available whether libpcre2-8 could be loaded
function M.is_available()
	return _ensure_lib() ~= nil
end

--- Compile a pattern into a reusable `Regex` object.
---@param pattern string
---@param flags string|integer|nil flag chars ("imsxuUA"), raw option bits, or nil
---@return easytasks.tk.Regex? regex, string? err
function M.compile(pattern, flags)
	local lib, err = _ensure_lib()
	if not lib then
		return nil, err
	end
	assert(type(pattern) == "string", "regex pattern must be a string")

	local options = _parse_flags(flags)
	local errcode = ffi.new("int[1]")
	local erroffset = ffi.new("size_t[1]")

	local code = lib.pcre2_compile_8(pattern, #pattern, options, errcode, erroffset, nil)
	if code == nil then
		return nil,
			("pcre2_compile: %s (at offset %d)"):format(_err_message(errcode[0]), _to_int(erroffset[0]))
	end
	code = ffi.gc(code, lib.pcre2_code_free_8)

	local md = lib.pcre2_match_data_create_from_pattern_8(code, nil)
	if md == nil then
		return nil, "pcre2: failed to allocate match data"
	end
	md = ffi.gc(md, lib.pcre2_match_data_free_8)

	local ncap = ffi.new("uint32_t[1]")
	lib.pcre2_pattern_info_8(code, _INFO_CAPTURECOUNT, ncap)

	-- Assign to a typed local before returning: returning setmetatable() directly
	-- spreads its (possibly multi-value) result into the second return slot.
	---@type easytasks.tk.Regex
	local re = setmetatable({
		_lib = lib,
		_code = code,
		_md = md,
		_ncaptures = _to_int(ncap[0]),
	}, Regex)
	return re
end

-- Compiled-pattern cache for the stdlib-shaped convenience helpers.
local _cache = LRU:new(128)

---@param pattern string
---@param flags string|integer|nil
---@return easytasks.tk.Regex
local function _get_cached(pattern, flags)
	local key = tostring(flags) .. "\31" .. pattern
	local re = _cache:get(key)
	if not re then
		local err
		re, err = M.compile(pattern, flags)
		if not re then
			error(err, 3)
		end
		_cache:put(key, re)
	end
	return re
end

--- Convenience wrapper: `regex.compile(pattern, flags):test(subject)`.
---@param subject string
---@param pattern string
---@param flags string|integer|nil
---@return boolean
function M.test(subject, pattern, flags)
	return _get_cached(pattern, flags):test(subject)
end

--- Convenience wrapper: `regex.compile(pattern, flags):find(subject)`.
---@param subject string
---@param pattern string
---@param flags string|integer|nil
---@return integer? start, integer? finish, (string|nil)[]? captures
function M.find(subject, pattern, flags)
	return _get_cached(pattern, flags):find(subject)
end

--- Convenience wrapper: `regex.compile(pattern, flags):match(subject)`.
---@param subject string
---@param pattern string
---@param flags string|integer|nil
---@return ... string|nil
function M.match(subject, pattern, flags)
	return _get_cached(pattern, flags):match(subject)
end

--- Convenience wrapper: `regex.compile(pattern, flags):gmatch(subject)`.
---@param subject string
---@param pattern string
---@param flags string|integer|nil
---@return fun(): ...
function M.gmatch(subject, pattern, flags)
	return _get_cached(pattern, flags):gmatch(subject)
end

--- Convenience wrapper: `regex.compile(pattern, flags):gsub(subject, repl)`.
---@param subject string
---@param pattern string
---@param repl string|fun(...):string?
---@param flags string|integer|nil
---@return string result, integer count
function M.gsub(subject, pattern, repl, flags)
	return _get_cached(pattern, flags):gsub(subject, repl)
end

return M
