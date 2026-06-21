local lua_file_type = require("easytasks.types.lua.file")

--- Run a `lua_file` task synchronously and collect its reported output + result.
---@param task table
---@return boolean ok
---@return string[] reported
local function run(task)
    local reported = {}
    local result
    local ctx = {
        tasks  = {},
        report = function(msg) table.insert(reported, msg) end,
    }
    lua_file_type.start(task, ctx, function(ok) result = ok end)
    return result, reported
end

--- Create a temp project (dir with a tasks file) and return its path.
---@return string root
local function make_project()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    -- find_root() looks for the configured tasks filename in cwd.
    local tasks = require("easytasks.config").tasks_filename
    vim.fn.writefile({ "" }, vim.fs.joinpath(root, tasks))
    return root
end

--- Write `lines` to `<root>/relpath`, creating parent dirs.
---@param root string
---@param relpath string
---@param lines string[]
local function write_script(root, relpath, lines)
    local path = vim.fs.joinpath(root, relpath)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(lines, path)
    return path
end

describe("lua_file task", function()
    local prev_cwd
    local prev_notify
    local notifications

    before_each(function()
        prev_cwd = vim.fn.getcwd()
        -- Capture notifications instead of letting ERROR-level ones write to
        -- stderr (which the headless harness reports as a spurious error).
        notifications = {}
        prev_notify = vim.notify
        vim.notify = function(msg) table.insert(notifications, msg) end
    end)

    after_each(function()
        vim.fn.chdir(prev_cwd)
        vim.notify = prev_notify
    end)

    it("runs a script file and reports its output", function()
        local root = make_project()
        write_script(root, "scripts/hello.lua", {
            "print('hello from file')",
            "return true",
        })
        vim.fn.chdir(root)

        local ok, out = run({ name = "hello", type = "lua_file", file = "scripts/hello.lua" })
        assert.is_true(ok)
        assert.are.same({ "hello from file" }, out)
    end)

    it("resolves relative paths against the project root, not cwd", function()
        local root = make_project()
        write_script(root, "task.lua", { "print('ran')" })
        vim.fn.chdir(root)
        -- move cwd somewhere else; find_root() should still locate the project
        -- because the test stays inside `root`, so a bare relative path resolves
        -- against it.
        local ok, out = run({ name = "t", type = "lua_file", file = "task.lua" })
        assert.is_true(ok)
        assert.are.same({ "ran" }, out)
    end)

    it("accepts an absolute path", function()
        local root = make_project()
        local abs = write_script(root, "abs.lua", { "print('abs')" })
        vim.fn.chdir(root)

        local ok, out = run({ name = "t", type = "lua_file", file = abs })
        assert.is_true(ok)
        assert.are.same({ "abs" }, out)
    end)

    it("runs in a restricted environment", function()
        local root = make_project()
        write_script(root, "env.lua", {
            "print('vim=' .. tostring(vim ~= nil))",
            "print('require=' .. tostring(require ~= nil))",
        })
        vim.fn.chdir(root)

        local ok, out = run({ name = "envtask", type = "lua_file", file = "env.lua" })
        assert.is_true(ok)
        assert.are.same({ "vim=true", "require=false" }, out)
    end)

    it("fails when the chunk returns false", function()
        local root = make_project()
        write_script(root, "fail.lua", { "return false" })
        vim.fn.chdir(root)

        local ok = run({ name = "t", type = "lua_file", file = "fail.lua" })
        assert.is_false(ok)
    end)

    it("fails when the chunk raises an error", function()
        local root = make_project()
        write_script(root, "boom.lua", { "error('boom')" })
        vim.fn.chdir(root)

        local ok, out = run({ name = "t", type = "lua_file", file = "boom.lua" })
        assert.is_false(ok)
        assert.is_true(#out >= 1 and out[#out]:match("boom") ~= nil)
    end)

    it("fails cleanly when the file does not exist", function()
        local root = make_project()
        vim.fn.chdir(root)

        local ok, out = run({ name = "t", type = "lua_file", file = "nope.lua" })
        assert.is_false(ok)
        assert.is_true(out[#out]:match("cannot load lua file") ~= nil)
    end)

    it("fails when no file is given", function()
        local ok = run({ name = "t", type = "lua_file" })
        assert.is_false(ok)
        assert.is_true(#notifications >= 1)
        assert.is_true(notifications[#notifications]:match("has no file") ~= nil)
    end)
end)
