local resolver = require("easytasks.runner.resolver")
local expressions   = require("easytasks.expressions")

--- Drive the async `resolve_expressions` synchronously.
---@param val any
---@param ctx table?
---@return boolean ok, any result, string? err
local function resolve(val, ctx)
    local done, rok, result, rerr
    resolver.resolve_expressions(val, ctx or { task = {}, tasks = {}, expressions = {} },
        function(ok, res, err)
            rok, result, rerr, done = ok, res, err, true
        end)
    assert.is_true(vim.wait(2000, function() return done end), "resolve_expressions timed out")
    return rok, result, rerr
end

describe("expression type preservation", function()
    before_each(function()
        expressions.register("ret_num", function() return 42 end)
        expressions.register("ret_bool", function() return false end)
        expressions.register("ret_str", function() return "hello" end)
        expressions.register("ret_strnum", function() return "8080" end)
        expressions.register("ret_nil", function() return nil end)
    end)

    it("preserves a number when the whole value is a single expression", function()
        local ok, res = resolve({ port = "${ret_num}" })
        assert.is_true(ok)
        assert.are.equal("number", type(res.port))
        assert.are.equal(42, res.port)
    end)

    it("preserves a boolean (including false) for a sole expression", function()
        local ok, res = resolve({ flag = "${ret_bool}" })
        assert.is_true(ok)
        assert.are.equal("boolean", type(res.flag))
        assert.is_false(res.flag)
    end)

    it("preserves type with surrounding whitespace around the sole expression", function()
        local ok, res = resolve({ port = "  ${ret_num}  " })
        assert.is_true(ok)
        assert.are.equal(42, res.port)
    end)

    it("stringifies when the expression is mixed with literal text", function()
        local ok, res = resolve({ label = "port=${ret_num}" })
        assert.is_true(ok)
        assert.are.equal("string", type(res.label))
        assert.are.equal("port=42", res.label)
    end)

    it("stringifies when multiple expressions are concatenated", function()
        local ok, res = resolve({ x = "${ret_num}${ret_num}" })
        assert.is_true(ok)
        assert.are.equal("4242", res.x)
    end)

    it("keeps string-returning expressions as strings (backward compatible)", function()
        local ok, res = resolve({ x = "${ret_str}" })
        assert.is_true(ok)
        assert.are.equal("hello", res.x)
    end)

    it("drops the field when a sole expression returns nil", function()
        local ok, res = resolve({ x = "${ret_nil}" })
        assert.is_true(ok)
        assert.is_nil(res.x)
    end)
end)

describe("num/bool cast expressions", function()
    before_each(function()
        expressions.register("ret_strnum2", function() return "8080" end)
    end)

    it("num casts a literal to a number", function()
        local ok, res = resolve({ port = "${num:8080}" })
        assert.is_true(ok)
        assert.are.equal("number", type(res.port))
        assert.are.equal(8080, res.port)
    end)

    it("num composes with a string-returning expression", function()
        local ok, res = resolve({ port = "${num:${ret_strnum2}}" })
        assert.is_true(ok)
        assert.are.equal(8080, res.port)
    end)

    it("num errors on a non-numeric value", function()
        local ok, _, err = resolve({ port = "${num:abc}" })
        assert.is_false(ok)
        assert.is_truthy(err and err:match("not a number"))
    end)

    it("bool casts true/false-ish values to booleans", function()
        local ok, res = resolve({ a = "${bool:true}", b = "${bool:no}" })
        assert.is_true(ok)
        assert.is_true(res.a)
        assert.is_false(res.b)
    end)
end)

describe("expression argument parsing", function()
    -- Report the args a expression received, as "#<count>:<a>|<b>|...".
    local function register_nargs(name)
        expressions.register(name, function(_, ...)
            local a = { ... }
            return "#" .. #a .. ":" .. table.concat(a, "|")
        end)
    end

    it("does not re-split a nested expression's output on commas", function()
        register_nargs("nargs1")
        expressions.register("withcomma", function() return "a,b" end)
        -- The nested expression yields "a,b"; it must arrive as ONE argument.
        local ok, res = resolve({ x = "${nargs1:${withcomma}}" })
        assert.is_true(ok)
        assert.are.equal("#1:a,b", res.x)
    end)

    it("treats separators inside a nested ${...} as part of that span", function()
        register_nargs("nargs2")
        expressions.register("second", function(_, _, b) return b end)
        -- The ':' and ',' belong to the inner ${second:...} lookup, not to
        -- nargs2, so nargs2 receives exactly one argument: second's output.
        local ok, res = resolve({ x = "${nargs2:${second:missing,xyz}}" })
        assert.is_true(ok)
        assert.are.equal("#1:xyz", res.x)
    end)

    it("keeps everything after the first colon as the args region", function()
        register_nargs("nargs3")
        -- Only the first top-level ':' splits name from args.
        local ok, res = resolve({ x = "${nargs3:a:b:c}" })
        assert.is_true(ok)
        assert.are.equal("#1:a:b:c", res.x)
    end)

    it("keeps commas literal inside a double-quoted argument", function()
        register_nargs("nargs4")
        local ok, res = resolve({ x = [[${nargs4:"a,b",c}]] })
        assert.is_true(ok)
        assert.are.equal("#2:a,b|c", res.x)
    end)

    it("keeps commas literal inside a single-quoted argument", function()
        register_nargs("nargs4b")
        local ok, res = resolve({ x = "${nargs4b:'a,b',c}" })
        assert.is_true(ok)
        assert.are.equal("#2:a,b|c", res.x)
    end)

    it("unescapes a doubled quote inside a quoted argument", function()
        register_nargs("nargs4c")
        local ok, res = resolve({ x = [[${nargs4c:"a""b"}]] })
        assert.is_true(ok)
        assert.are.equal([[#1:a"b]], res.x)
    end)

    it("expands a nested expression inside a quoted argument", function()
        register_nargs("nargs4d")
        expressions.register("withcomma2", function() return "x,y" end)
        -- The comma is protected by quotes; the nested expression still expands and
        -- its output is not re-split.
        local ok, res = resolve({ x = [[${nargs4d:"<${withcomma2}>"}]] })
        assert.is_true(ok)
        assert.are.equal("#1:<x,y>", res.x)
    end)

    it("treats a backslash as a literal character (no longer an escape)", function()
        register_nargs("nargs4e")
        -- '\' is literal now, so the comma still splits into two args.
        local ok, res = resolve({ x = [[${nargs4e:a\,b}]] })
        assert.is_true(ok)
        assert.are.equal([[#2:a\|b]], res.x)
    end)

    it("treats a quoted empty string as one argument", function()
        register_nargs("nargs4f")
        local ok, res = resolve({ x = [[${nargs4f:""}]] })
        assert.is_true(ok)
        assert.are.equal("#1:", res.x)
    end)

    it("preserves empty argument slots", function()
        register_nargs("nargs5")
        local ok, res = resolve({ x = "${nargs5:a,,c}" })
        assert.is_true(ok)
        assert.are.equal("#3:a||c", res.x)
    end)
end)

describe("inline expressions ([expressions] table)", function()
    -- Build a ctx whose inline `[expressions]` table holds the given templates.
    local function ctx(exprs)
        return { task = {}, tasks = {}, expressions = exprs }
    end

    it("expands an inline expression referenced by name", function()
        local ok, res = resolve({ x = "curl ${api}" },
            ctx({ api = "http://localhost:8080" }))
        assert.is_true(ok)
        assert.are.equal("curl http://localhost:8080", res.x)
    end)

    it("lets an inline expression reference other inline expressions", function()
        local ok, res = resolve({ x = "${api}" },
            ctx({ api = "http://${host}:${port}", host = "localhost", port = "8080" }))
        assert.is_true(ok)
        assert.are.equal("http://localhost:8080", res.x)
    end)

    it("lets an inline expression reference a built-in expression", function()
        local ok, res = resolve({ x = "${count}" }, ctx({ count = "${num:5}" }))
        assert.is_true(ok)
        assert.are.equal(5, res.x)        -- number survives (sole expression)
        assert.are.equal("number", type(res.x))
    end)

    it("prefers a built-in/registered expression over an inline one of the same name", function()
        expressions.register("regwins", function() return "registered" end)
        local ok, res = resolve({ x = "${regwins}" }, ctx({ regwins = "inline" }))
        assert.is_true(ok)
        assert.are.equal("registered", res.x)
    end)

    it("errors on a direct cycle", function()
        local ok, _, err = resolve({ x = "${a}" }, ctx({ a = "${a}" }))
        assert.is_false(ok)
        assert.is_truthy(err and err:match("cycle"))
    end)

    it("errors on an indirect cycle", function()
        local ok, _, err = resolve({ x = "${a}" }, ctx({ a = "${b}", b = "${a}" }))
        assert.is_false(ok)
        assert.is_truthy(err and err:match("cycle"))
    end)

    it("errors when an inline expression is given arguments", function()
        local ok, _, err = resolve({ x = "${api:foo}" }, ctx({ api = "value" }))
        assert.is_false(ok)
        assert.is_truthy(err and err:match("does not accept arguments"))
    end)

    it("errors on an unknown name that is neither registered nor inline", function()
        local ok, _, err = resolve({ x = "${nope}" }, ctx({}))
        assert.is_false(ok)
        assert.is_truthy(err and err:match("Unknown expression"))
    end)

    it("reuses the same inline expression twice without a false cycle", function()
        local ok, res = resolve({ x = "${a}-${a}" }, ctx({ a = "v" }))
        assert.is_true(ok)
        assert.are.equal("v-v", res.x)
    end)
end)

describe("shell builtin", function()
    it("returns command stdout with the trailing newline stripped", function()
        local ok, res = resolve({ x = "${shell:printf hello}" })
        assert.is_true(ok)
        assert.are.equal("hello", res.x)
    end)

    it("re-joins comma-split arguments into one command", function()
        local ok, res = resolve({ x = "${shell:printf 'a,b'}" })
        assert.is_true(ok)
        assert.are.equal("a,b", res.x)
    end)

    it("interpolates in a larger string", function()
        local ok, res = resolve({ x = "user=${shell:printf bob}" })
        assert.is_true(ok)
        assert.are.equal("user=bob", res.x)
    end)

    it("errors on a non-zero exit status", function()
        local ok, _, err = resolve({ x = "${shell:false}" })
        assert.is_false(ok)
        assert.is_truthy(err and err:match("shell command failed"))
    end)

    it("errors when given no command", function()
        local ok, _, err = resolve({ x = "${shell}" })
        assert.is_false(ok)
        assert.is_truthy(err and err:match("requires a command"))
    end)
end)

describe("lua builtin", function()
    it("evaluates an expression and preserves a numeric result", function()
        local ok, res = resolve({ x = "${lua:1 + 2}" })
        assert.is_true(ok)
        assert.are.equal("number", type(res.x))
        assert.are.equal(3, res.x)
    end)

    it("evaluates a call with comma-separated arguments", function()
        local ok, res = resolve({ x = "${lua:math.max(1, 5, 3)}" })
        assert.is_true(ok)
        assert.are.equal(5, res.x)
    end)

    it("preserves a boolean result", function()
        local ok, res = resolve({ x = "${lua:2 > 1}" })
        assert.is_true(ok)
        assert.is_true(res.x)
    end)

    it("evaluates a statement chunk with an explicit return", function()
        local ok, res = resolve({ x = "${lua:return 'hi'}" })
        assert.is_true(ok)
        assert.are.equal("hi", res.x)
    end)

    it("errors on a runtime error", function()
        local ok, _, err = resolve({ x = "${lua:error('boom')}" })
        assert.is_false(ok)
        assert.is_truthy(err and err:match("lua error"))
    end)

    it("errors when a result is not a scalar", function()
        local ok, _, err = resolve({ x = "${lua:{1, 2}}" })
        assert.is_false(ok)
        assert.is_truthy(err and err:match("Invalid return type"))
    end)

    it("errors when given no code", function()
        local ok, _, err = resolve({ x = "${lua}" })
        assert.is_false(ok)
        assert.is_truthy(err and err:match("requires code"))
    end)
end)
