local exec       = require("easytasks.runner.exec")
local task_types = require("easytasks.types")

-- The built-in task types load lazily on first schema build, resolved against
-- the rtp "." entry (the plugin root). These tests chdir into temp projects, so
-- force the modules to load and cache now, while cwd is still the plugin root.
task_types.build_resolved_schema()

--- Create a temp project (dir with a tasks file) and return its root + path.
---@param toml_lines string[]
---@return string root, string path
local function make_project(toml_lines)
    local root  = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local path = vim.fs.joinpath(root, require("easytasks.config").tasks_filename)
    vim.fn.writefile(toml_lines, path)
    return root, path
end

--- The single live (non-ephemeral) run entry for a task name, or nil.
---@param name string
---@return easytasks.RunEntry?
local function entry_for(name)
    for _, e in pairs(exec.get_all()) do
        if e.task_name == name and not e.ephemeral then return e end
    end
end

describe("stop", function()
    local prev_cwd, prev_notify

    before_each(function()
        prev_cwd    = vim.fn.getcwd()
        prev_notify = vim.notify
        vim.notify  = function() end

        -- A controllable task type that never finishes on its own: start() blocks
        -- until cancelled, and cancelling completes the run as failed — the way a
        -- real long-running process settles when it is terminated.
        task_types.register("blocker", {
            start = function(_, _, on_done)
                return function() on_done(false) end
            end,
        })
    end)

    after_each(function()
        vim.fn.chdir(prev_cwd)
        vim.notify = prev_notify
    end)

    it("cancels the in-flight dependency of a task that is only waiting", function()
        local root, path = make_project({
            "[[tasks]]",
            'name = "dep"',
            'type = "blocker"',
            "",
            "[[tasks]]",
            'name = "main"',
            'type = "blocker"',
            'depends_on = ["dep"]',
        })
        vim.fn.chdir(root)

        exec.run("main", path)

        -- Let the dependency advance past expression resolution into its running,
        -- cancellable state (its cancel fn is only set once start() runs).
        assert.is_true(vim.wait(2000, function()
            local d = entry_for("dep")
            return d ~= nil and d.cancel ~= nil
        end))
        assert.are.equal("waiting", entry_for("main").state)
        assert.are.equal("running", entry_for("dep").state)

        exec.stop("main")

        -- The wait must unblock: stopping cascades to the dependency, and both
        -- the dependency and the waiting task settle as "stopped".
        assert.is_true(vim.wait(2000, function()
            local m, d = entry_for("main"), entry_for("dep")
            return m ~= nil and d ~= nil
                and m.state == "stopped" and d.state == "stopped"
        end))
    end)

    it("stops a directly running task", function()
        local root, path = make_project({
            "[[tasks]]",
            'name = "solo"',
            'type = "blocker"',
        })
        vim.fn.chdir(root)

        exec.run("solo", path)

        assert.is_true(vim.wait(2000, function()
            local e = entry_for("solo")
            return e ~= nil and e.cancel ~= nil
        end))

        exec.stop("solo")

        assert.is_true(vim.wait(2000, function()
            local e = entry_for("solo")
            return e ~= nil and e.state == "stopped"
        end))
    end)
end)
