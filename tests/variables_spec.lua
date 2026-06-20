local macros   = require("easytasks.macros")
local resolver = require("easytasks.runner.resolver")

--- Expand `val` through the macro resolver synchronously, blocking until the
--- async callback fires.
---@param val any
---@param ctx easytasks.MacroCtx
---@return boolean ok
---@return any result
---@return string? err
local function expand(val, ctx)
    local done, ok, result, err = false, nil, nil, nil
    resolver.resolve_macros(val, ctx, function(o, r, e)
        ok, result, err, done = o, r, e, true
    end)
    vim.wait(1000, function() return done end)
    assert.is_true(done, "resolve_macros callback never fired")
    return ok, result, err
end

describe("var macro", function()
    it("returns the declared value", function()
        local ctx = { variables = { filename = "main.cpp" } }
        local val, err = macros.var(ctx, "filename")
        assert.equals("main.cpp", val)
        assert.is_nil(err)
    end)

    it("errors on an undefined variable", function()
        local val, err = macros.var({ variables = {} }, "missing")
        assert.is_nil(val)
        assert.equals("undefined variable: 'missing'", err)
    end)

    it("falls back to the default when undefined", function()
        local val, err = macros.var({ variables = {} }, "missing", "fallback")
        assert.equals("fallback", val)
        assert.is_nil(err)
    end)

    it("prefers the declared value over the default", function()
        local val = macros.var({ variables = { x = "set" } }, "x", "fallback")
        assert.equals("set", val)
    end)

    it("errors when no name is given", function()
        local val, err = macros.var({ variables = {} }, nil)
        assert.is_nil(val)
        assert.is_not_nil(err)
    end)

    it("treats a nil variables map as empty", function()
        local val, err = macros.var({}, "anything")
        assert.is_nil(val)
        assert.is_not_nil(err)
    end)
end)

describe("var macro through resolve_macros", function()
    it("substitutes a variable into a command string", function()
        local ctx = { variables = { filename = "main.cpp" } }
        local ok, result = expand("g++ ${var:filename} -o main.out", ctx)
        assert.is_true(ok)
        assert.equals("g++ main.cpp -o main.out", result)
    end)

    it("expands variables inside a task table", function()
        local ctx = { variables = { filename = "main.cpp", out = "main.out" } }
        local ok, result = expand(
            { command = "g++ ${var:filename} -o ${var:out}" },
            ctx
        )
        assert.is_true(ok)
        assert.equals("g++ main.cpp -o main.out", result.command)
    end)

    it("fails the expansion on an undefined variable", function()
        local ok, _, err = expand("${var:nope}", { variables = {} })
        assert.is_false(ok)
        assert.is_not_nil(err)
    end)
end)
