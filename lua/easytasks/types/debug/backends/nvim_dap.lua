---@param params easytasks.debug.Params
---@return table
local function _params_to_dap_config(params)
    local config = {
        type    = params.adapter,
        request = params.request or "launch",
        name    = params.name or params.adapter,
    }
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
    local function adapters()
        local names = vim.tbl_keys(dap.adapters)
        table.sort(names)
        return names
    end
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
        adapters = adapters,
    }
end
