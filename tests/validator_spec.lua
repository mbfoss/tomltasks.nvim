---@diagnostic disable: undefined-global, undefined-field
local validator  = require("tomltools.toml.validator")
local DecodeTree = require("tomltools.toml.DecodeTree")

local function valid(schema, data)
    local ok, _ = validator.validate(schema, data)
    return ok
end

local function errors(schema, data, dt)
    local _, errs = validator.validate(schema, data, dt)
    return errs
end

describe("validator – type", function()
    it("null", function()
        assert.is_true(valid({ type = "null" }, nil))
        assert.is_false(valid({ type = "null" }, ""))
    end)

    it("boolean", function()
        assert.is_true(valid({ type = "boolean" }, true))
        assert.is_true(valid({ type = "boolean" }, false))
        assert.is_false(valid({ type = "boolean" }, 0))
    end)

    it("integer accepts whole numbers only", function()
        assert.is_true(valid({ type = "integer" }, 0))
        assert.is_true(valid({ type = "integer" }, -7))
        assert.is_false(valid({ type = "integer" }, 1.5))
    end)

    it("number accepts floats and integers", function()
        assert.is_true(valid({ type = "number" }, 3.14))
        assert.is_true(valid({ type = "number" }, 42))
        assert.is_false(valid({ type = "number" }, "42"))
    end)

    it("string", function()
        assert.is_true(valid({ type = "string" }, "hello"))
        assert.is_false(valid({ type = "string" }, 1))
    end)

    it("array", function()
        assert.is_true(valid({ type = "array" }, { 1, 2 }))
        assert.is_false(valid({ type = "array" }, { a = 1 }))
    end)

    it("object", function()
        assert.is_true(valid({ type = "object" }, { a = 1 }))
        assert.is_false(valid({ type = "object" }, { 1, 2 }))
    end)

    it("multiple types", function()
        local s = { type = { "string", "null" } }
        assert.is_true(valid(s, "x"))
        assert.is_true(valid(s, nil))
        assert.is_false(valid(s, 42))
    end)

    it("error message names the actual type", function()
        local errs = errors({ type = "string" }, 42)
        assert.is_true(errs[1].err_msg:find("number") ~= nil)
    end)
end)

describe("validator – enum / const", function()
    it("enum accepts matching value", function()
        assert.is_true(valid({ enum = { "a", "b" } }, "a"))
    end)

    it("enum rejects non-matching value", function()
        assert.is_false(valid({ enum = { "a", "b" } }, "c"))
    end)

    it("const matches exactly", function()
        assert.is_true(valid({ const = 42 }, 42))
        assert.is_false(valid({ const = 42 }, 43))
    end)
end)

describe("validator – string keywords", function()
    it("minLength", function()
        assert.is_true(valid({ minLength = 3 }, "abc"))
        assert.is_false(valid({ minLength = 3 }, "ab"))
    end)

    it("minLength=1 emits 'cannot be empty'", function()
        local errs = errors({ minLength = 1 }, "")
        assert.is_true(errs[1].err_msg:find("empty") ~= nil)
    end)

    it("maxLength", function()
        assert.is_true(valid({ maxLength = 3 }, "abc"))
        assert.is_false(valid({ maxLength = 3 }, "abcd"))
    end)

    it("pattern", function()
        assert.is_true(valid({ pattern = "^%d+$" }, "123"))
        assert.is_false(valid({ pattern = "^%d+$" }, "12x"))
    end)
end)

describe("validator – numeric keywords", function()
    it("minimum (inclusive)", function()
        assert.is_true(valid({ minimum = 5 }, 5))
        assert.is_false(valid({ minimum = 5 }, 4))
    end)

    it("maximum (inclusive)", function()
        assert.is_true(valid({ maximum = 5 }, 5))
        assert.is_false(valid({ maximum = 5 }, 6))
    end)

    it("exclusiveMinimum", function()
        assert.is_false(valid({ exclusiveMinimum = 5 }, 5))
        assert.is_true(valid({ exclusiveMinimum = 5 }, 6))
    end)

    it("exclusiveMaximum", function()
        assert.is_false(valid({ exclusiveMaximum = 5 }, 5))
        assert.is_true(valid({ exclusiveMaximum = 5 }, 4))
    end)

    it("multipleOf", function()
        assert.is_true(valid({ multipleOf = 3 }, 9))
        assert.is_false(valid({ multipleOf = 3 }, 10))
    end)
end)

describe("validator – object keywords", function()
    it("required: passes when all present", function()
        assert.is_true(valid({ required = { "a", "b" } }, { a = 1, b = 2 }))
    end)

    it("required: fails when fields are missing", function()
        local errs = errors({ required = { "a", "b" } }, { a = 1 })
        assert.is_true(#errs > 0)
        assert.is_true(errs[1].err_msg:find("b") ~= nil)
    end)

    it("properties validates child values", function()
        assert.is_true(valid({ properties = { x = { type = "string" } } }, { x = "hi" }))
        assert.is_false(valid({ properties = { x = { type = "string" } } }, { x = 1 }))
    end)

    it("additionalProperties = false", function()
        local s = { properties = { a = {} }, additionalProperties = false }
        assert.is_false(valid(s, { a = 1, b = 2 }))
        assert.is_true(valid(s, { a = 1 }))
    end)

    it("additionalProperties schema", function()
        local s = { properties = { a = {} }, additionalProperties = { type = "string" } }
        assert.is_false(valid(s, { a = 1, b = 99 }))
        assert.is_true(valid(s, { a = 1, b = "ok" }))
    end)

    it("patternProperties validates matching keys", function()
        local s = { patternProperties = { ["^x"] = { type = "number" } } }
        assert.is_false(valid(s, { xfoo = "nope" }))
        assert.is_true(valid(s, { xfoo = 42, other = "ignored" }))
    end)

    it("minProperties", function()
        assert.is_false(valid({ minProperties = 2 }, { a = 1 }))
        assert.is_true(valid({ minProperties = 2 }, { a = 1, b = 2 }))
    end)

    it("maxProperties", function()
        assert.is_false(valid({ maxProperties = 1 }, { a = 1, b = 2 }))
        assert.is_true(valid({ maxProperties = 1 }, { a = 1 }))
    end)

    it("dependentRequired triggers only when controlling prop present", function()
        local s = { dependentRequired = { foo = { "bar" } } }
        assert.is_false(valid(s, { foo = 1 }))
        assert.is_true(valid(s, { foo = 1, bar = 2 }))
        assert.is_true(valid(s, { baz = 1 }))  -- foo absent → no requirement
    end)

    it("dependentSchemas applies sub-schema when prop present", function()
        local s = { dependentSchemas = { foo = { required = { "bar" } } } }
        assert.is_false(valid(s, { foo = 1 }))
        assert.is_true(valid(s, { foo = 1, bar = 2 }))
        assert.is_true(valid(s, { baz = 1 }))
    end)
end)

describe("validator – array keywords", function()
    it("prefixItems validates positionally", function()
        local s = { prefixItems = { { type = "string" }, { type = "number" } } }
        assert.is_true(valid(s, { "hi", 42 }))
        assert.is_false(valid(s, { "hi", "not-num" }))
    end)

    it("items applies only beyond prefixItems", function()
        local s = {
            prefixItems = { { type = "string" } },
            items       = { type = "number" },
        }
        assert.is_true(valid(s, { "first", 2, 3 }))
        assert.is_false(valid(s, { "first", "second" }))
    end)

    it("items without prefixItems covers all elements", function()
        assert.is_true(valid({ items = { type = "number" } }, { 1, 2, 3 }))
        assert.is_false(valid({ items = { type = "number" } }, { 1, "two" }))
    end)

    it("minItems / maxItems", function()
        assert.is_false(valid({ minItems = 2 }, { 1 }))
        assert.is_true(valid({ minItems = 2 }, { 1, 2 }))
        assert.is_false(valid({ maxItems = 2 }, { 1, 2, 3 }))
        assert.is_true(valid({ maxItems = 2 }, { 1, 2 }))
    end)

    it("uniqueItems", function()
        assert.is_false(valid({ uniqueItems = true }, { 1, 2, 1 }))
        assert.is_true(valid({ uniqueItems = true }, { 1, 2, 3 }))
    end)

    it("contains requires at least one match", function()
        assert.is_false(valid({ contains = { type = "number" } }, { "a", "b" }))
        assert.is_true(valid({ contains = { type = "number" } }, { "a", 1 }))
    end)

    it("minContains / maxContains", function()
        local s = { contains = { type = "number" }, minContains = 2 }
        assert.is_false(valid(s, { 1, "a" }))
        assert.is_true(valid(s, { 1, 2, "a" }))

        local s2 = { contains = { type = "number" }, maxContains = 1 }
        assert.is_false(valid(s2, { 1, 2, "a" }))
        assert.is_true(valid(s2, { 1, "a" }))
    end)
end)

describe("validator – composition", function()
    it("allOf: all sub-schemas must pass", function()
        assert.is_true(valid({ allOf = { { minimum = 1 }, { maximum = 10 } } }, 5))
        assert.is_false(valid({ allOf = { { minimum = 5 }, { maximum = 3 } } }, 4))
    end)

    it("anyOf: at least one must pass; reports best-match errors on total failure", function()
        local s = { anyOf = { { type = "string" }, { type = "number" } } }
        assert.is_true(valid(s, 42))
        assert.is_true(valid(s, "hi"))
        assert.is_false(valid(s, true))
        -- errors should be non-empty but come from the best branch
        local errs = errors(s, true)
        assert.is_true(#errs > 0)
    end)

    it("oneOf: exactly one must pass", function()
        assert.is_true(valid({ oneOf = { { type = "string" }, { type = "number" } } }, 42))
        -- both minimum=1 and maximum=10 pass for 5 → not exactly one
        assert.is_false(valid({ oneOf = { { minimum = 1 }, { maximum = 10 } } }, 5))
    end)

    it("oneOf: zero matches reports best-match errors", function()
        local s = { oneOf = { { type = "string" }, { type = "number" } } }
        local errs = errors(s, true)
        assert.is_true(#errs > 0)
    end)

    it("not: schema must not match", function()
        assert.is_true(valid({ ["not"] = { type = "string" } }, 42))
        assert.is_false(valid({ ["not"] = { type = "string" } }, "hi"))
    end)

    it("if/then: then applies only when if passes", function()
        local s = { ["if"] = { type = "string" }, ["then"] = { minLength = 3 } }
        assert.is_false(valid(s, "ab"))
        assert.is_true(valid(s, "abc"))
        assert.is_true(valid(s, 42))  -- if fails → then skipped
    end)

    it("if/else: else applies only when if fails", function()
        local s = { ["if"] = { type = "string" }, ["else"] = { minimum = 10 } }
        assert.is_false(valid(s, 5))
        assert.is_true(valid(s, 15))
        assert.is_true(valid(s, "hi"))  -- if passes → else skipped
    end)
end)

describe("validator – node_id tracking", function()
    it("attaches DecodeTree child id to property errors", function()
        local dt   = DecodeTree.new()
        local root = dt:root_id()
        local child = dt:add_child(root, "x", { 0, 0, 0, 1 })

        local schema = { properties = { x = { type = "number" } } }
        local errs   = errors(schema, { x = "oops" }, dt)

        assert.is_true(#errs > 0)
        assert.equals(child, errs[1].node_id)
    end)

    it("returns root id on top-level type mismatch", function()
        local dt   = DecodeTree.new()
        local root = dt:root_id()

        local errs = errors({ type = "string" }, 42, dt)
        assert.is_true(#errs > 0)
        assert.equals(root, errs[1].node_id)
    end)
end)
