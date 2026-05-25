-- Composite tasks have no command of their own; their entire behaviour is
-- the dependency resolution done by exec.lua before run() is called.
---@type easytasks.TaskTypeDef
return {
    run = function()
        return true
    end,

    schema = {
        description = "Definition of a `composite` task",
        ["x-order"] = { "name", "type", "save_buffers", "if_running", "depends_on", "depends_order" },
    },
}
