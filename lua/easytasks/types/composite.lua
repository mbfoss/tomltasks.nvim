-- Composite tasks have no command of their own; their entire behaviour is
-- the dependency resolution done by exec.lua before run() is called.
---@type easytasks.TaskTypeDef
return {
    ---@return fun()
    start = function(_, _, on_done)
        on_done(true)
        return function() end
    end,

    templates = {
        {
            label = "Task Sequence",
            spec  = { name = "Sequence", type = "composite", depends_on = { "", "" }, depends_order = "sequence" },
        },
        {
            label = "Parallel Tasks",
            spec  = { name = "Parallel", type = "composite", depends_on = { "", "" }, depends_order = "parallel" },
        },
    },
}
