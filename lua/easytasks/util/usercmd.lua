local M = {}

---@class easytasks.usercmd.SubcommandDef
---@field run  fun(name:string, args:string[], opts:table)
---@field complete fun(rest:string[], arg_lead:string):string[]

---@type table<string, easytasks.usercmd.SubcommandDef>
local _ext_subcommands = {}

---Register a subcommand under the main `Easytasks` command.
---@param name       string
---@param run_fn     fun(name:string, args:string[], opts:table)
---@param opts?      { complete_fn?: fun(rest:string[], arg_lead:string):string[] }
function M.register_subcommand(name, run_fn, opts)
    _ext_subcommands[name] = {
        run      = run_fn,
        complete = opts and opts.complete_fn or function() return {} end,
    }
end

---@param name string
---@return easytasks.usercmd.SubcommandDef?
function M.get_subcommand(name)
    return _ext_subcommands[name]
end

---@return string[]
function M.subcommand_names()
    return vim.tbl_keys(_ext_subcommands)
end

---@param str string
---@return string[]
local function _split_args(str)
    local args = {}
    local i = 1
    local len = #str
    local part = {}

    while i <= len do
        local c = str:sub(i, i)
        if c == '\\' and i < len then
            table.insert(part, str:sub(i + 1, i + 1))
            i = i + 2
        elseif c:match('%s') then
            if #part > 0 then
                table.insert(args, table.concat(part))
                part = {}
            end
            i = i + 1
        else
            table.insert(part, c)
            i = i + 1
        end
    end
    if #part > 0 then
        table.insert(args, table.concat(part))
    end
    return args
end

---@alias easytasks.usercmd.subcommand_fn fun(cmd:string,rest:string[],arg_lead:string):string[]

---@alias easytasks.usercmd.run_fn
---| fun(cmd:string,args:string[],opts:vim.api.keyset.create_user_command.command_args)


---@param subcommand_fn easytasks.usercmd.subcommand_fn
local function _complete(subcommand_fn, arg_lead, cmd_line)
    local function filter(strs)
        local out = {}
        for _, s in ipairs(strs or {}) do
            if not vim.startswith(s, '_') and vim.startswith(s, arg_lead) then
                table.insert(out, s)
            end
        end
        return out
    end

    local args = _split_args(cmd_line)
    if cmd_line:match("%s+$") then
        table.insert(args, ' ')
    end

    local cmd = args[1]
    if #args == 1 then
        return filter(subcommand_fn(cmd, {}, arg_lead))
    elseif #args >= 2 then
        local rest = { unpack(args, 2) }
        rest[#rest] = nil
        return filter(subcommand_fn(cmd, rest, arg_lead))
    end
    return {}
end

---@param cmd string
---@param run_fn easytasks.usercmd.run_fn
---@param opts vim.api.keyset.create_user_command.command_args
local function _dispatch(cmd, run_fn, opts)
    local args = _split_args(opts.args)
    local ok, err = pcall(run_fn, cmd, args, opts)
    if not ok then
        vim.notify(
            "[easytasks.nvim] " .. cmd .. " command error\n" .. tostring(err),
            vim.log.levels.ERROR
        )
    end
end

---@param cmd string
---@param run_fn easytasks.usercmd.run_fn
---@param opts {desc:string?,subcommand_fn:easytasks.usercmd.subcommand_fn?}?
function M.register_user_cmd(cmd, run_fn, opts)
    opts = opts or {}
    vim.api.nvim_create_user_command(cmd, function(cmd_opts)
            _dispatch(cmd, run_fn, cmd_opts)
        end,
        {
            nargs = opts.subcommand_fn ~= nil and "*" or nil,
            complete = opts.subcommand_fn ~= nil and function(arg_lead, cmd_line, _)
                return _complete(opts.subcommand_fn, arg_lead, cmd_line)
            end or nil,
            desc = opts.desc,
        })
end

return M
