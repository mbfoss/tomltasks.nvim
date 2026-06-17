--- easydap backend. easydap derives the DAP launch/attach `request_args` from
--- the generic `easytasks.DebugSpec` fields (`command`, `cwd`, `env`,
--- `stop_on_entry`, …), so the task is passed straight through to `m.run`.

--- Map easydap's own task templates (shape `{ label, task }`) onto easytasks'
--- template shape (`{ label, spec }`).
---@return easytasks.TaskTemplate[]?
local function _templates()
    local ok, mod = pcall(require, "easydap.task")
    if not ok or type(mod.templates) ~= "table" then return nil end
    local out = {} ---@type easytasks.TaskTemplate[]
    for _, t in ipairs(mod.templates) do
        out[#out + 1] = { label = t.label, spec = t.task or t.spec }
    end
    return out
end

---@return easytasks.debug.Backend?
return function()
    local ok, m      = pcall(require, "easydap")
    local ok2, adaps = pcall(require, "easydap.adapters")
    if not ok then return nil end
    local adapters = ok2 and function()
        local names = vim.tbl_keys(adaps)
        table.sort(names)
        return names
    end or nil
    return {
        run       = m.run,
        adapters  = adapters,
        templates = _templates(),
    }
end
