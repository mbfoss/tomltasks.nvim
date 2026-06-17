local M = {}

local ui = require("easytasks.util.ui_util")

---@class easytasks.SpawnHandle
---@field bufnr number
---@field pid   integer
---@field stop  fun()  stop the spawned command

---@class easytasks.SpawnOpts
---@field cwd?       string
---@field env?       table<string,string>
---@field on_stdout?      fun(id: integer, data: string[], name: string)
---@field on_stderr?      fun(id: integer, data: string[], name: string)
---@field on_exit?        fun(code: integer)
---@field line_buffered?  boolean  only emit complete lines to on_stdout/on_stderr

---Neovim splits on newlines but the last element of each on_stdout/on_stderr
---call is always a partial fragment joined to the first element of the next call.
---This wraps the callback so it only fires with complete lines.
---@param cb fun(id: integer, data: string[], name: string)
---@return fun(id: integer, data: string[], name: string)
local function _wrap_line_buffered(cb)
    local partial = ""
    return function(id, data, name)
        if #data == 0 then return end
        local first = partial .. data[1]
        if #data == 1 then
            partial = first
            return
        end
        local lines = { first }
        for i = 2, #data - 1 do
            lines[#lines + 1] = data[i]
        end
        partial = data[#data]
        cb(id, lines, name)
    end
end


--- Spawn a command in a terminal buffer.
--- Returns immediately with a handle, or nil if jobstart failed.
--- termopen handles all output rendering including ANSI colours.
---@param cmd   string|string[]
---@param opts  easytasks.SpawnOpts
---@return number?,string?
local function _start_job(cmd, opts)
    local job_id
    local start_ok, job_id_or_err = pcall(function()
        return vim.fn.jobstart(cmd, {
            term      = true,
            cwd       = opts.cwd,
            env       = opts.env,
            on_stdout = opts.on_stdout and (opts.line_buffered and _wrap_line_buffered(opts.on_stdout) or opts.on_stdout),
            on_stderr = opts.on_stderr and (opts.line_buffered and _wrap_line_buffered(opts.on_stderr) or opts.on_stderr),
            on_exit   = function(_, code)
                job_id = -1
                vim.schedule(function()
                    if opts.on_exit then opts.on_exit(code) end
                end)
            end,
        })
    end)

    if not start_ok then
        return nil, tostring(job_id_or_err)
    end

    job_id = job_id_or_err
    if job_id < 0 then
        local program = type(cmd) == "table" and tostring(cmd[0]) or tostring(cmd)
        return nil, (start_ok and "Invalid command:" .. program)
    end

    if job_id == 0 then
        return nil, (start_ok and "Invalid arguments")
    end
    return job_id
end

--- Spawn a command in a terminal buffer.
--- Returns immediately with a handle, or nil if jobstart failed.
--- termopen handles all output rendering including ANSI colours.
---@param cmd   string|string[]
---@param opts  easytasks.SpawnOpts
---@param bufnr? integer buffer to own the terminal (auto created if nil)
---@return easytasks.SpawnHandle?,string?
function M.spawn(cmd, opts, bufnr)
    -- A terminal buffer must be in a window for jobstart {term=true}.
    local own_buf
    if not bufnr then
        own_buf = true
        bufnr = vim.api.nvim_create_buf(false, true)
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

    local job_id, job_err = _start_job(cmd, opts)

    vim.api.nvim_set_current_win(saved_win)
    vim.api.nvim_win_close(spawn_win, true)

    if not job_id then
        if own_buf then
            vim.api.nvim_buf_delete(bufnr, { force = true })
            own_buf = nil
        end
        return nil, job_err
    end

    if own_buf then
        vim.bo[bufnr].buflisted = true
    end

    vim.api.nvim_create_autocmd("TermClose", {
        buffer   = bufnr,
        once     = true,
        callback = function(ev)
            local buf = ev.buf
            assert(buf)
            for _, key in ipairs({ 'i', 'a', 'o', 'I', 'A', 'O', 'c', 'cc', 'C', 's', 'S', 'R', '.' }) do
                vim.keymap.set("n", key, "<Nop>", { buffer = buf, nowait = true })
            end
        end,
    })

    return { ---@type easytasks.SpawnHandle
        bufnr = bufnr,
        pid   = vim.fn.jobpid(job_id),
        stop  = function()
            vim.fn.jobstop(job_id)
        end,
    }
end

return M
