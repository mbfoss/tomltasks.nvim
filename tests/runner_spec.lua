local exec = require("easytasks.runner.exec")

describe("runner", function()
    it("lists task names from a TOML file sorted alphabetically", function()
        local toml = table.concat({
            '[[tasks]]',
            'name    = "zebra"',
            'type    = "process"',
            'command = "echo zebra"',
            '',
            '[[tasks]]',
            'name    = "alpha"',
            'type    = "process"',
            'command = "echo alpha"',
        }, "\n")

        local path = vim.fn.tempname() .. ".toml"
        vim.fn.writefile(vim.split(toml, "\n"), path)

        local names, err = exec.list(path)

        vim.fn.delete(path)

        assert.is_nil(err)
        assert.are.same({ "alpha", "zebra" }, names)
    end)
end)
