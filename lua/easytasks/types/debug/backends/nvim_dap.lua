local str_util = require("easytasks.util.str_util")

--- Reduced schema for nvim-dap, which does not derive the DAP `request_args`
--- from the generic fields the way easydap does. Only fields passed through
--- verbatim are kept; adapter-specific options go straight into `request_args`.
---@param adapters fun(): string[]  adapter-name enum source for the schema
---@return table
local function _schema(adapters)
    return {
        description = "Definition of a `debug` task (runs via a DAP adapter)",
        ["x-order"] = {
            "name", "type", "if_running", "depends_on", "depends_order", "save_buffers",
            "adapter", "request", "host", "port", "cwd",
            "request_args", "raw_messages",
        },
        required    = { "adapter" },
        properties  = {
            adapter      = {
                type        = "string",
                minLength   = 1,
                description = "Name of the DAP adapter to use (e.g. codelldb, delve, debugpy)",
                enum        = adapters,
            },
            request      = {
                description = "Whether to launch a new process or attach to a running one",
                oneOf       = {
                    { type = "string", const = "launch", description = "Start the program under the debugger" },
                    { type = "string", const = "attach", description = "Attach to an already-running process" },
                },
            },
            request_args = {
                type                 = { "object", "null" },
                description          =
                "Arguments sent verbatim in the DAP launch or attach request (carries all adapter-specific launch/attach options)",
                additionalProperties = true,
            },
        },
    }
end

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
        schema = _schema(adapters),
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
