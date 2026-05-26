local ordered = require("easytasks.util.table_util").ordered

-- Demo task type: creates multiple scratch buffers with static content.
-- Useful for exercising the multi-buffer status panel UI.
---@type easytasks.TaskTypeDef
return {
    run = function(task, ctx)
        local panes = task.panes or {
            { label = "stdout", lines = { "Hello from stdout", "All good." } },
            { label = "stderr", lines = { "Hello from stderr", "No errors." } },
            { label = "log",    lines = { "2026-05-26 started", "2026-05-26 done" } },
        }

        for _, pane in ipairs(panes) do
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.bo[bufnr].bufhidden = "wipe"
            vim.bo[bufnr].swapfile  = false
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, pane.lines or {})
            ctx.add_bufnr(bufnr, pane.label)
        end

        return true
    end,

    schema = {
        description = "Creates multiple scratch buffers — demo for the multi-buffer status panel",
        ["x-order"] = { "name", "type", "depends_on", "depends_order" },
    },

    templates = {
        {
            label = "Multi-buffer demo",
            task  = ordered({ name = "demo", type = "multibuffer" }, { "name", "type" }),
        },
    },
}
