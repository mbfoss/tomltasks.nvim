local str_util = require("easytasks.util.str_util")

---Split task.command (string or string[]) into the program path and any extra args.
---@param task table
---@return string  program
---@return string[] args
local function _split_command(task)
    local parts = type(task.command) == "table"
        and task.command
        or str_util.split_shell_args(task.command)
    local args = {}
    for i = 2, #parts do args[#args + 1] = parts[i] end
    return parts[1], args
end

---@param task table
---@return table
local function _task_to_dap_config(task)
    local config = {
        type    = task.adapter,
        request = task.request or "launch",
        name    = task.name or task.adapter,
    }
    if task.command then
        local program, args = _split_command(task)
        config.program = task.command
        config.args = args
    end
    if task.cwd then config.cwd = task.cwd end
    if task.env then config.env = task.env end
    if task.host then config.host = task.host end
    if task.port then config.port = task.port end
    if task.run_in_terminal ~= nil then config.runInTerminal = task.run_in_terminal end
    if task.stop_on_entry ~= nil then config.stopOnEntry = task.stop_on_entry end
    -- request_args take precedence over all named fields above
    if type(task.request_args) == "table" then
        config = vim.tbl_extend("force", config, task.request_args)
    end
    return config
end

---@return easytasks.debug.Backend?
return function()
    local ok, dap = pcall(require, "dap")
    if not ok then return nil end
    return {
        run = function(task, _, on_done)
            local config = _task_to_dap_config(task)
            local key    = "easytasks_" .. tostring(vim.uv.hrtime())
            local _done  = false
            local function _finish(success)
                if _done then return end
                _done                                     = true
                dap.listeners.after.event_terminated[key] = nil
                dap.listeners.after.event_exited[key]     = nil
                on_done(success)
            end
            dap.listeners.after.event_terminated[key] = function() _finish(true) end
            dap.listeners.after.event_exited[key]     = function(_, body)
                _finish(body and body.exitCode == 0)
            end
            dap.run(config)
            return function()
                _finish(false)
                dap.terminate()
            end
        end,
        adapters = function()
            local names = vim.tbl_keys(dap.adapters)
            table.sort(names)
            return names
        end,
    }
end
