local str_util = require("easytasks.util.str_util")

---@param params easytasks.debug.Params
---@return string  program
---@return string[] args
local function _split_command(params)
    local parts ---@type string[]
    if type(params.command) == "table" then
        parts = params.command --[=[@as string[]]=]
    else
        parts = str_util.split_shell_args(params.command --[[@as string]])
    end
    local args = {}
    for i = 2, #parts do args[#args + 1] = parts[i] end
    return parts[1], args
end

---@param params easytasks.debug.Params
---@return table
local function _params_to_dap_config(params)
    local config = {
        type    = params.adapter,
        request = params.request or "launch",
        name    = params.name or params.adapter,
    }
    if params.command then
        local program, args = _split_command(params)
        config.program = program
        config.args = args
    end
    if params.cwd then config.cwd = params.cwd end
    if params.env then config.env = params.env end
    if params.host then config.host = params.host end
    if params.port then config.port = params.port end
    if params.run_in_terminal ~= nil then config.runInTerminal = params.run_in_terminal end
    if params.stop_on_entry ~= nil then config.stopOnEntry = params.stop_on_entry end
    -- request_args take precedence over all named fields above
    if type(params.request_args) == "table" then
        config = vim.tbl_extend("force", config, params.request_args)
    end
    return config
end

---@return easytasks.debug.Backend?
return function()
    local ok, dap = pcall(require, "dap")
    if not ok then return nil end
    ---@type easytasks.debug.Backend
    return {
        run = function(params, ctx, on_done)
            local config = _params_to_dap_config(params)
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
            ctx.report("run config " .. vim.inspect(config))
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
