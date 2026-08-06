if vim.fn.has("nvim-0.10") ~= 1 then
    error("tomltasks.nvim requires Neovim >= 0.10")
end

-- Startup wiring: `:Tasks`, the `tomltasks` filetype and the autocmd that
-- attaches the tasks-file LSP are all registered here without requiring any
-- Lua. Every callback pulls in what it needs on first use -- `util/usercmd` is
-- the command plumbing (it splits arguments and drives completion, and knows
-- nothing about what the subcommands do), `tomltasks.commands` is the
-- subcommand implementations, and `tomltasks` is the plugin proper. None of
-- them is read until the command is first run or completed, or until a tasks
-- file is actually opened.
-- The modules are cached in a local on first use, so the callbacks pay for a
-- `require` lookup once rather than on every invocation.
local usercmd ---@type table?
local commands ---@type table?

---@return table
local function _usercmd()
    usercmd = usercmd or require("tomltasks.util.usercmd")
    return usercmd
end

---@return table
local function _commands()
    commands = commands or require("tomltasks.commands")
    return commands
end

-- The default command name and tasks filename are spelled out here rather than
-- read from `tomltasks.config` (requiring it would defeat the point). When
-- `setup()` changes either one, `enable()` registers the configured name and
-- filename on top of these.
vim.api.nvim_create_user_command("Tasks", function(opts)
    _usercmd().handle(opts, function(cmd, args, cmd_opts)
        return _commands().run(cmd, args, cmd_opts)
    end)
end, {
    nargs = "*",
    desc = "Run, stop and inspect project tasks",
    complete = function(arg_lead, cmd_line, _)
        return _usercmd().complete(arg_lead, cmd_line,
            function(cmd, rest, lead)
                return _commands().complete(cmd, rest, lead)
            end)
    end,
})

-- The tasks file gets its own `tomltasks` filetype (not `toml`): it carries
-- vendored TOML + expression-hole highlighting via syntax/tomltasks.vim and no
-- treesitter parser, and the LSP attaches by this filetype.
vim.filetype.add({
    filename = {
        ["tasks.toml"] = "tomltasks",
    },
})

vim.api.nvim_create_autocmd("FileType", {
    pattern  = "tomltasks",
    group    = vim.api.nvim_create_augroup("tomltasks", { clear = true }),
    desc     = "Attach the tasks-file language server",
    callback = function(ev)
        require("tomltasks").on_filetype(ev.buf)
    end,
})
