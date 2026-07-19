local M = {}

---@param str string
---@return string[]
 function M.split_args(str)
    local args = {}
    local i = 1
    local len = #str
    local part = {}
    local has_part = false
    local quote = nil

    while i <= len do
        local c = str:sub(i, i)
        if quote == "'" then
            -- Single quotes: everything literal until the closing quote,
            -- including backslashes.
            if c == "'" then
                quote = nil
            else
                table.insert(part, c)
            end
            i = i + 1
        elseif quote == '"' then
            -- Double quotes: backslash only escapes " and \ (and itself);
            -- any other backslash is kept literally.
            if c == '\\' then
                local n = str:sub(i + 1, i + 1)
                if n == '"' or n == '\\' then
                    table.insert(part, n)
                    i = i + 2
                else
                    table.insert(part, c)
                    i = i + 1
                end
            elseif c == '"' then
                quote = nil
                i = i + 1
            else
                table.insert(part, c)
                i = i + 1
            end
        elseif c == '\\' then
            -- Unquoted backslash escapes the next character literally.
            local n = str:sub(i + 1, i + 1)
            if n == '' then
                table.insert(part, c)
                i = i + 1
            else
                table.insert(part, n)
                has_part = true
                i = i + 2
            end
        elseif c == '"' or c == "'" then
            quote = c
            has_part = true
            i = i + 1
        elseif c:match('%s') then
            if has_part then
                table.insert(args, table.concat(part))
                part = {}
                has_part = false
            end
            i = i + 1
        else
            table.insert(part, c)
            has_part = true
            i = i + 1
        end
    end
    if has_part then
        table.insert(args, table.concat(part))
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
