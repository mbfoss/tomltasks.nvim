local M = {}

-- Quoting rules (shared with keystone.nvim's queryflags):
--
--   Arguments are whitespace-separated. Only " quotes: a quoted span may
--   contain whitespace, and the delimiting quotes are stripped from the
--   argument. A single quote is an ordinary literal character.
--
--   Anywhere in the input -- inside a quoted span or outside one -- a literal
--   double quote is written as \": inside a span it does not close it, outside
--   one it does not open one. A backslash before anything else is literal.
--
--   An unterminated quote is not a real delimiter: its opening " is kept as a
--   literal character, and the span runs to the end of the input.
--
--   "" is an explicit empty argument and is kept as one.
--
---@param str string
---@return string[]
function M.split_args(str)
    local args = {}
    local i    = 1
    local len  = #str

    while i <= len do
        while i <= len and str:sub(i, i):match("%s") do i = i + 1 end
        if i > len then break end

        local chars     = {}
        local quote     = nil -- active quote char while inside a quoted span
        local quote_idx = nil -- index in `chars` where the active quote opened

        while i <= len do
            local c = str:sub(i, i)
            if quote then
                if c == "\\" and str:sub(i + 1, i + 1) == quote then
                    table.insert(chars, quote)
                    i = i + 2
                elseif c == quote then
                    quote     = nil
                    quote_idx = nil
                    i         = i + 1
                else
                    table.insert(chars, c)
                    i = i + 1
                end
            elseif c == "\\" and str:sub(i + 1, i + 1) == '"' then
                table.insert(chars, '"')
                i = i + 2
            elseif c:match("%s") then
                break
            elseif c == '"' then
                quote     = c
                quote_idx = #chars + 1
                i         = i + 1
            else
                table.insert(chars, c)
                i = i + 1
            end
        end

        if quote and quote_idx then
            table.insert(chars, quote_idx, quote)
        end

        -- The inner loop always consumes at least one non-whitespace char, so
        -- an empty `chars` means an explicitly quoted empty argument ("") --
        -- keep it rather than dropping the argument.
        table.insert(args, table.concat(chars))
    end

    return args
end

---@alias tomltasks.tk.usercmd.subcommand fun(cmd:string,rest:string[],arg_lead:string):string[]

---@alias tomltasks.tk.usercmd.run_fn
---| fun(cmd:string,args:string[],opts:vim.api.keyset.create_user_command.command_args)


---@param subcommand tomltasks.tk.usercmd.subcommand
local function _complete(subcommand, arg_lead, cmd_line)
    local function filter(strs)
        local out = {}
        for _, s in ipairs(strs or {}) do
            if vim.startswith(s, arg_lead) then
                table.insert(out, s)
            end
        end
        return out
    end

    local args = M.split_args(cmd_line)
    if cmd_line:match("%s+$") then
        table.insert(args, ' ')
    end

    local cmd = args[1]
    if #args == 1 then
        return filter(subcommand(cmd, {}, arg_lead))
    elseif #args >= 2 then
        local rest = { unpack(args, 2) }
        rest[#rest] = nil
        return filter(subcommand(cmd, rest, arg_lead))
    end
    return {}
end

---@param cmd string
---@param run_fn tomltasks.tk.usercmd.run_fn
---@param opts vim.api.keyset.create_user_command.command_args
local function _dispatch(cmd, run_fn, opts)
    local args = M.split_args(opts.args)
    local ok, err = pcall(run_fn, cmd, args, opts)
    if not ok then
        vim.notify(
            "[tomltasks.tk.nvim] " .. cmd .. " command error\n" .. tostring(err),
            vim.log.levels.ERROR
        )
    end
end

---@param cmd string
---@param run_fn tomltasks.tk.usercmd.run_fn
---@param opts {desc:string?,subcommand:tomltasks.tk.usercmd.subcommand?,count:boolean,range:boolean}?
function M.register_user_cmd(cmd, run_fn, opts)
    opts = opts or {}
    vim.api.nvim_create_user_command(cmd, function(cmd_opts)
            _dispatch(cmd, run_fn, cmd_opts)
        end,
        {
            nargs = "*",
            count = opts.count,
            range = opts.range,
            complete = opts.subcommand ~= nil and function(arg_lead, cmd_line, _)
                return _complete(opts.subcommand, arg_lead, cmd_line)
            end or function() return {} end,
            desc = opts.desc,
        })
end

return M
