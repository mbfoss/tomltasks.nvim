-- easytasks.nvim task file. Returns a map of task name → task, each built with
-- a typed constructor from `require("easytasks")`. Field values may be plain
-- data or a function evaluated lazily at run time.
local t = require("easytasks")

return {
    -- Run the plenary test suite.
    test = t.run {
        command = { "make", "test" },
    },

    -- Demonstrates a function-valued field (replaces the old `${file}` macro):
    -- echoes the absolute path of the current buffer when run.
    ["echo-file"] = t.run {
        command = function() return { "echo", vim.fn.expand("%:p") } end,
    },
}
