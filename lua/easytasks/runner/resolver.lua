---@class easytasks.runner.resolver
local M = {}

local macros = require("easytasks.runner.macros")

---@param str string
---@param sep string
---@return string[]
local function _split_with_escapes(str, sep)
    local result  = {}
    local current = ""
    local i       = 1
    while i <= #str do
        local char = str:sub(i, i)
        if char == "\\" and i < #str then
            current = current .. str:sub(i + 1, i + 1)
            i       = i + 2
        elseif char == sep then
            table.insert(result, current)
            current = ""
            i       = i + 1
        else
            current = current .. char
            i       = i + 1
        end
    end
    table.insert(result, current)
    return result
end

---@param str       string
---@param start_pos integer
---@return string|nil content, integer|nil end_pos, string|nil err
local function _parse_nested(str, start_pos)
    local stack  = 0
    local result = ""
    local i      = start_pos
    while i <= #str do
        local char = str:sub(i, i)
        if char == "\\" and i < #str then
            result = result .. char .. str:sub(i + 1, i + 1)
            i      = i + 2
        elseif char == "{" then
            stack  = stack + 1
            result = result .. char
            i      = i + 1
        elseif char == "}" then
            stack = stack - 1
            if stack == 0 then return result:sub(2), i end
            result = result .. char
            i      = i + 1
        else
            result = result .. char
            i      = i + 1
        end
    end
    return nil, nil, "Unterminated macro"
end

local function _async_call(fn, args)
    local parent_co = coroutine.running()
    vim.schedule(function()
        coroutine.wrap(function()
            local ret = vim.F.pack_len(pcall(fn, unpack(args)))
            coroutine.resume(parent_co, vim.F.unpack_len(ret))
        end)()
    end)
    return coroutine.yield()
end

---@param str string
---@param ctx easytasks.MacroCtx
---@return string|nil result, string|nil err
local function _expand_recursive(str, ctx)
    local res = ""
    local i   = 1
    while i <= #str do
        local char      = str:sub(i, i)
        local next_char = str:sub(i + 1, i + 1)
        if char == "$" and next_char == "$" then
            res = res .. "$"
            i   = i + 2
        elseif char == "$" and next_char == "{" then
            local content, end_pos, parse_err = _parse_nested(str, i + 1)
            if parse_err then return nil, parse_err end
            if not content then return nil, "Failed to parse macro content" end

            local expanded_inner, expand_err = _expand_recursive(content, ctx)
            if expand_err then return nil, expand_err end
            if not expanded_inner then return nil, "Macro expansion returned nil" end

            local macro_name, args_list = "", {}
            local colon_pos = expanded_inner:find(":")
            if colon_pos then
                macro_name = vim.trim(expanded_inner:sub(1, colon_pos - 1))
                local raw_args = expanded_inner:sub(colon_pos + 1)
                if raw_args and raw_args ~= "" then
                    args_list = _split_with_escapes(raw_args, ",")
                end
            else
                macro_name = vim.trim(expanded_inner)
            end
            if not macro_name or macro_name == "" then
                return nil, "Unknown macro: ''"
            end

            local fn = macros.get(macro_name)
            if not fn then return nil, "Unknown macro: '" .. macro_name .. "'" end

            local macro_args = { ctx }
            for _, arg in ipairs(args_list) do
                table.insert(macro_args, arg)
            end

            local status, val, macro_err = _async_call(fn, macro_args)
            if not status then
                return nil, "Macro crashed: " .. tostring(val)
            end
            if val == nil and macro_err then
                return nil, macro_err
            end

            res = res .. tostring(val or "")
            i   = end_pos + 1
        else
            res = res .. char
            i   = i + 1
        end
    end
    return res
end

---@param tbl  table
---@param seen table
---@param ctx  easytasks.MacroCtx
---@return boolean ok, string? err
local function _expand_table(tbl, seen, ctx)
    seen = seen or {}
    if seen[tbl] then return true end
    seen[tbl] = true
    for k, v in pairs(tbl) do
        if type(v) == "table" then
            local ok, err = _expand_table(v, seen, ctx)
            if not ok then return false, err end
        elseif type(v) == "string" then
            local res, err = _expand_recursive(v, ctx)
            if err then return false, err end
            tbl[k] = res
        end
    end
    return true
end

---@param val      any                    string or table to expand
---@param ctx      easytasks.MacroCtx
---@param callback fun(ok: boolean, result: any, err: string?)
function M.resolve_macros(val, ctx, callback)
    coroutine.wrap(function()
        local call_ok, call_ret = xpcall(function()
            if type(val) == "table" then
                local tbl = vim.deepcopy(val)
                local ok, err = _expand_table(tbl, {}, ctx)
                if not ok then error(err) end
                return tbl
            elseif type(val) == "string" then
                local res, err = _expand_recursive(val, ctx)
                if err then error(err) end
                return res
            else
                return val
            end
        end, debug.traceback)

        local ok, result, err
        if call_ok then
            ok     = true
            result = call_ret
        else
            ok  = false
            err = call_ret
            if type(err) == "string" then
                local clean = err:match(":%d+: (.*)\nstack traceback:")
                if clean then err = clean end
            end
        end

        vim.schedule(function() callback(ok, result, err) end)
    end)()
end

return M
