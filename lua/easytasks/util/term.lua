local M = {}

local ui = require("easytasks.util.ui_util")

---@class easytasks.SpawnHandle
---@field bufnr number
---@field pid   integer
---@field stop  fun()  stop the spawned command

---@class easytasks.SpawnOpts
---@field cwd?       string
---@field env?       table<string,string>
---@field on_stdout? fun(id: integer, data: string[], name: string)
---@field on_stderr? fun(id: integer, data: string[], name: string)
---@field on_exit?   fun(code: integer)

--- Spawn a command in a terminal buffer.
--- Returns immediately with a handle, or nil if jobstart failed.
--- termopen handles all output rendering including ANSI colours.
---@param cmd   string|string[]
---@param opts  easytasks.SpawnOpts
---@param bufnr? integer buffer to own the terminal (auto created if nil)
---@return easytasks.SpawnHandle?
function M.spawn(cmd, opts, bufnr)
    -- A terminal buffer must be in a window for jobstart {term=true}.
    local own_buf
    if not bufnr then
        own_buf = true
        bufnr = vim.api.nvim_create_buf(true, true)
        vim.bo[bufnr].swapfile = false
    end

    local spawn_win = ui.create_window(bufnr, false, {
        relative  = "editor",
        row       = 0,
        col       = 0,
        width     = vim.o.columns,
        height    = vim.o.lines,
        style     = "minimal",
        hide      = true,
        focusable = false,
        zindex    = 1,
    }, function() end)

    local saved_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(spawn_win)

    local job_id
    job_id = vim.fn.jobstart(cmd, {
        term      = true,
        cwd       = opts.cwd,
        env       = opts.env,
        on_stdout = opts.on_stdout,
        on_stderr = opts.on_stderr,
        on_exit   = function(_, code)
            job_id = -1
            vim.schedule(function()
                if opts.on_exit then opts.on_exit(code) end
            end)
        end,
    })

    vim.api.nvim_set_current_win(saved_win)
    vim.api.nvim_win_close(spawn_win, true)

    if job_id <= 0 then
        if own_buf then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        return nil
    end

    vim.api.nvim_create_autocmd("TermClose", {
        buffer   = bufnr,
        once     = true,
        callback = function()
            for _, key in ipairs({ 'i', 'a', 'o', 'I', 'A', 'O', 'c', 'cc', 'C', 's', 'S', 'R', '.' }) do
                vim.keymap.set("n", key, "<Nop>", { buffer = bufnr, nowait = true })
            end
        end,
    })

    return { ---@type easytasks.SpawnHandle
        bufnr = bufnr,
        pid   = vim.fn.jobpid(job_id),
        stop  = function()
            if job_id > 0 then
                vim.fn.jobstop(job_id)
            end
        end,
    }
end

return M
