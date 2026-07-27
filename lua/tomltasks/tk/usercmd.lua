local M = {}

-- This module does no argument parsing of its own. Dispatch passes Neovim's
-- opts.fargs straight through, and completion runs the raw command line back
-- through nvim_parse_cmd, so both paths split by Vim's native rules
-- (:h <f-args>):
--
--   Arguments are separated by unescaped whitespace. A backslash escapes the
--   character after it: \<space> (or \<tab>) is that literal whitespace and
--   does not split the argument, \\ is a single backslash, and a backslash
--   before anything else -- including a trailing backslash at end of line --
--   is kept verbatim along with what follows it. Quotes are not special.
--
--     a\ b c   -> a b  and  c        a\\b     -> a\b
--     a\\\ b   -> a\ b               a\nb     -> a\nb
--     \ a      -> " a"               a\       -> a\
--     "a b"    -> "a  and  b"        --p=x\ y -> --p=x y
--
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

    -- nvim_parse_cmd splits exactly as <f-args> does, and strips any range or
    -- command modifiers. It throws on a command line it cannot parse.
    local ok, parsed = pcall(vim.api.nvim_parse_cmd, cmd_line, {})
    if not ok then return {} end

    -- Trailing whitespace means a new, still-empty argument has begun; without
    -- it the last argument is the one being completed, not context for it.
    local rest = parsed.args
    if not cmd_line:match("%s$") then
        rest[#rest] = nil
    end

    return filter(subcommand(parsed.cmd, rest, arg_lead))
end

---@param cmd string
---@param run_fn tomltasks.tk.usercmd.run_fn
---@param opts vim.api.keyset.create_user_command.command_args
local function _dispatch(cmd, run_fn, opts)
    -- nargs="*" always yields fargs; the fallback is only to satisfy its
    -- optional type.
    local ok, err = pcall(run_fn, cmd, opts.fargs or {}, opts)
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
