local resolver = require("easytasks.runner.resolver")
local macros   = require("easytasks.macros")

--- Drive the async `resolve_macros` synchronously.
---@param val any
---@param ctx table?
---@return boolean ok, any result, string? err
local function resolve(val, ctx)
    local done, rok, result, rerr
    resolver.resolve_macros(val, ctx or { task = {}, tasks = {}, variables = {} },
        function(ok, res, err)
            rok, result, rerr, done = ok, res, err, true
        end)
    assert.is_true(vim.wait(2000, function() return done end), "resolve_macros timed out")
    return rok, result, rerr
end

describe("macro type preservation", function()
    before_each(function()
        macros.register("ret_num", function() return 42 end)
        macros.register("ret_bool", function() return false end)
        macros.register("ret_str", function() return "hello" end)
        macros.register("ret_strnum", function() return "8080" end)
        macros.register("ret_nil", function() return nil end)
    end)

    it("preserves a number when the whole value is a single macro", function()
        local ok, res = resolve({ port = "${ret_num}" })
        assert.is_true(ok)
        assert.are.equal("number", type(res.port))
        assert.are.equal(42, res.port)
    end)

    it("preserves a boolean (including false) for a sole macro", function()
        local ok, res = resolve({ flag = "${ret_bool}" })
        assert.is_true(ok)
        assert.are.equal("boolean", type(res.flag))
        assert.is_false(res.flag)
    end)

    it("preserves type with surrounding whitespace around the sole macro", function()
        local ok, res = resolve({ port = "  ${ret_num}  " })
        assert.is_true(ok)
        assert.are.equal(42, res.port)
    end)

    it("stringifies when the macro is mixed with literal text", function()
        local ok, res = resolve({ label = "port=${ret_num}" })
        assert.is_true(ok)
        assert.are.equal("string", type(res.label))
        assert.are.equal("port=42", res.label)
    end)

    it("stringifies when multiple macros are concatenated", function()
        local ok, res = resolve({ x = "${ret_num}${ret_num}" })
        assert.is_true(ok)
        assert.are.equal("4242", res.x)
    end)

    it("keeps string-returning macros as strings (backward compatible)", function()
        local ok, res = resolve({ x = "${ret_str}" })
        assert.is_true(ok)
        assert.are.equal("hello", res.x)
    end)

    it("drops the field when a sole macro returns nil", function()
        local ok, res = resolve({ x = "${ret_nil}" })
        assert.is_true(ok)
        assert.is_nil(res.x)
    end)
end)

describe("num/bool cast macros", function()
    before_each(function()
        macros.register("ret_strnum2", function() return "8080" end)
    end)

    it("num casts a literal to a number", function()
        local ok, res = resolve({ port = "${num:8080}" })
        assert.is_true(ok)
        assert.are.equal("number", type(res.port))
        assert.are.equal(8080, res.port)
    end)

    it("num composes with a string-returning macro", function()
        local ok, res = resolve({ port = "${num:${ret_strnum2}}" })
        assert.is_true(ok)
        assert.are.equal(8080, res.port)
    end)

    it("num errors on a non-numeric value", function()
        local ok, _, err = resolve({ port = "${num:abc}" })
        assert.is_false(ok)
        assert.is_truthy(err:match("not a number"))
    end)

    it("bool casts true/false-ish values to booleans", function()
        local ok, res = resolve({ a = "${bool:true}", b = "${bool:no}" })
        assert.is_true(ok)
        assert.is_true(res.a)
        assert.is_false(res.b)
    end)
end)
