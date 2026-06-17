local runner   = require("easytasks.runner")
local resolver = require("easytasks.runner.resolver")
local et       = require("easytasks")

--- Write `contents` to a temp file and return its path.
---@param contents string
---@return string
local function _tmp_tasks(contents)
    local path = vim.fn.tempname() .. "_tasks.lua"
    vim.fn.writefile(vim.split(contents, "\n", { plain = true }), path)
    return path
end

describe("constructors", function()
    it("tag the spec with its type", function()
        assert.are.same("run", et.run({ command = "x" }).type)
        assert.are.same("composite", et.composite({}).type)
        assert.are.same("debug", et.debug({ adapter = "a" }).type)
        assert.are.same("run", et.task("run", {}).type)
    end)

    it("expose constructors for registered types via metatable", function()
        -- unknown type names do not produce a constructor
        assert.is_nil(et.definitely_not_a_type)
        -- a registered custom type gets an auto-generated constructor
        et.register_task_type("smoketype", { start = function(_, _, d) d(true) end })
        assert.is_function(et.smoketype)
        assert.are.same("smoketype", et.smoketype({}).type)
    end)
end)

describe("loading tasks.lua", function()
    it("lists tasks from a map", function()
        local path = _tmp_tasks([[
local t = require("easytasks")
return {
  build = t.run { command = "make" },
  test  = t.run { command = "make test", depends_on = { "build" } },
}
]])
        local names, by_name, err = runner.list_tasks(path)
        assert.is_nil(err)
        assert.are.same({ "build", "test" }, names)
        assert.are.same("make", by_name.build.command)
        assert.are.same("run", by_name.test.type)
    end)

    it("accepts an array with explicit names", function()
        local path = _tmp_tasks([[
local t = require("easytasks")
return {
  t.run { name = "a", command = "x" },
  t.run { name = "b", command = "y" },
}
]])
        local names, _, err = runner.list_tasks(path)
        assert.is_nil(err)
        assert.are.same({ "a", "b" }, names)
    end)

    it("reports a syntax error", function()
        local path = _tmp_tasks("return {{{")
        local names, _, err = runner.list_tasks(path)
        assert.is_nil(names)
        assert.is_not_nil(err)
    end)
end)

describe("resolve_values", function()
    it("replaces function-valued fields with their result", function()
        local task = {
            type    = "run",
            command = function() return "computed" end,
            args    = { "static", function() return "dynamic" end },
        }
        local done, result, ok
        resolver.resolve_values(task, { task = task, tasks = {} }, function(o, r)
            ok, result, done = o, r, true
        end)
        vim.wait(1000, function() return done end)
        assert.is_true(ok)
        assert.are.same("computed", result.command)
        assert.are.same({ "static", "dynamic" }, result.args)
        -- the original table is not mutated
        assert.is_function(task.command)
    end)

    it("aborts when a function returns (nil, err)", function()
        local task = { command = function() return nil, "boom" end }
        local done, err, ok
        resolver.resolve_values(task, { task = task, tasks = {} }, function(o, _, e)
            ok, err, done = o, e, true
        end)
        vim.wait(1000, function() return done end)
        assert.is_false(ok)
        assert.is_not_nil(err and err:match("boom"))
    end)
end)
