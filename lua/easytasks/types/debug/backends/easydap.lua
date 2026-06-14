---@return easytasks.debug.Backend?
return function()
    local ok, m      = pcall(require, "easydap")
    local ok2, adaps = pcall(require, "easydap.adapters")
    if not ok then return nil end
    return {
        run      = m.run,
        adapters = ok2 and function()
            local names = vim.tbl_keys(adaps)
            table.sort(names)
            return names
        end or nil,
        templates = ok2 and require("easydap.task").templates or nil,
    }
end
