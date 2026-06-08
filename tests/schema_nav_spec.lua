---@diagnostic disable: undefined-global, undefined-field
local sn = require("tomltools.toml.schema_nav")

-- Minimal DecodeTree stub: key_parts_of returns the given parts table.
local function make_dt(parts)
    return { key_parts_of = function() return parts end }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- flatten
-- ─────────────────────────────────────────────────────────────────────────────

describe("schema_nav.flatten", function()
    it("copies base schema keys verbatim", function()
        local r = sn.flatten({ type = "string", minLength = 2 }, "hi")
        assert.equals("string", r.type)
        assert.equals(2, r.minLength)
    end)

    it("merges allOf branches and removes allOf from output", function()
        local r = sn.flatten({
            allOf = {
                { properties = { a = { type = "string" } } },
                { properties = { b = { type = "number" } } },
            },
        }, {})
        assert.not_nil(r.properties and r.properties.a)
        assert.not_nil(r.properties and r.properties.b)
        assert.is_nil(r.allOf)
    end)

    it("if/then: merges then-branch when if passes", function()
        local r = sn.flatten({
            ["if"]   = { type = "string" },
            ["then"] = { minLength = 5 },
            ["else"] = { minimum  = 10 },
        }, "hello")
        assert.equals(5, r.minLength)
        assert.is_nil(r.minimum)
        assert.is_nil(r["if"])
        assert.is_nil(r["then"])
        assert.is_nil(r["else"])
    end)

    it("if/else: merges else-branch when if fails", function()
        local r = sn.flatten({
            ["if"]   = { type = "string" },
            ["then"] = { minLength = 5 },
            ["else"] = { minimum  = 10 },
        }, 42)
        assert.equals(10, r.minimum)
        assert.is_nil(r.minLength)
    end)

    it("oneOf: picks best-matching branch (fewest errors)", function()
        local r = sn.flatten({
            oneOf = {
                { properties = { a = { type = "string" } }, required = { "a" } },
                { properties = { b = { type = "number" } }, required = { "b" } },
            },
        }, { a = "hello" })
        -- data satisfies first branch (has 'a') → its properties are merged
        assert.not_nil(r.properties and r.properties.a)
        assert.is_nil(r.oneOf)
    end)

    it("anyOf: merges ALL passing branches", function()
        local r = sn.flatten({
            anyOf = {
                { minimum = 1 },
                { maximum = 100 },
            },
        }, 50)  -- both branches valid for 50
        assert.equals(1,   r.minimum)
        assert.equals(100, r.maximum)
        assert.is_nil(r.anyOf)
    end)

    it("anyOf: falls back to best branch when none pass", function()
        -- boolean matches neither string nor number branch
        local r = sn.flatten({
            anyOf = {
                { type = "string" },
                { type = "number" },
            },
        }, true)
        assert.not_nil(r)       -- should not error or return nil
        assert.is_nil(r.anyOf)  -- keyword must be removed
    end)

    it("dependentSchemas: merged when controlling property is present", function()
        local r = sn.flatten({
            dependentSchemas = {
                foo = { properties = { bar = { type = "string" } } },
            },
        }, { foo = 1 })
        assert.not_nil(r.properties and r.properties.bar)
        assert.is_nil(r.dependentSchemas)
    end)

    it("dependentSchemas: skipped when controlling property is absent", function()
        local r = sn.flatten({
            dependentSchemas = {
                foo = { properties = { bar = { type = "string" } } },
            },
        }, { baz = 1 })
        assert.is_nil(r.properties)
        assert.is_nil(r.dependentSchemas)
    end)

    it("dependentSchemas: not applied when data is an array", function()
        local r = sn.flatten({
            dependentSchemas = {
                ["1"] = { properties = { extra = {} } },
            },
        }, { "elem" })  -- vim.islist → true, so dependentSchemas must be skipped
        assert.is_nil(r.properties)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- schema_at
-- ─────────────────────────────────────────────────────────────────────────────

describe("schema_nav.schema_at", function()
    -- Shared fixture ──────────────────────────────────────────────────────────
    local root_schema = {
        type       = "object",
        properties = {
            name  = { type = "string" },
            score = { type = "number" },
            tags  = {
                type        = "array",
                prefixItems = { [1] = { type = "string", const = "first" } },
                items       = { type = "string" },
            },
            meta  = {
                type                 = "object",
                patternProperties    = { ["^x_"] = { type = "string" } },
                additionalProperties = { type = "number" },
            },
            locked = {
                type = "object",
                -- no additionalProperties → unknown keys return nil
            },
        },
    }
    local root_data = {
        name  = "test",
        score = 10,
        tags  = { "first", "second", "third" },
        meta  = { x_label = "ok", count = 5 },
        locked = {},
    }

    it("navigates to a plain property", function()
        local s = sn.schema_at(root_schema, root_data, make_dt({ "name" }), 0)
        assert.not_nil(s)
        assert.equals("string", s.type)
    end)

    it("empty parts returns flattened root schema", function()
        local s = sn.schema_at(root_schema, root_data, make_dt({}), 0)
        assert.not_nil(s)
        assert.equals("object", s.type)
    end)

    it("prefixItems: numeric index within prefix range", function()
        local s = sn.schema_at(root_schema, root_data, make_dt({ "tags", "1" }), 0)
        assert.not_nil(s)
        assert.equals("first", s.const)
    end)

    it("items: numeric index beyond prefix range falls back to items", function()
        local s = sn.schema_at(root_schema, root_data, make_dt({ "tags", "2" }), 0)
        assert.not_nil(s)
        assert.equals("string", s.type)
        assert.is_nil(s.const)
    end)

    it("patternProperties: key matching a pattern", function()
        local s = sn.schema_at(root_schema, root_data, make_dt({ "meta", "x_label" }), 0)
        assert.not_nil(s)
        assert.equals("string", s.type)
    end)

    it("additionalProperties: unmatched key falls through", function()
        local s = sn.schema_at(root_schema, root_data, make_dt({ "meta", "count" }), 0)
        assert.not_nil(s)
        assert.equals("number", s.type)
    end)

    it("returns nil for unknown key when no additionalProperties", function()
        local s = sn.schema_at(root_schema, root_data, make_dt({ "locked", "nope" }), 0)
        assert.is_nil(s)
    end)

    it("returns nil for unknown top-level property", function()
        local s = sn.schema_at(root_schema, root_data, make_dt({ "nonexistent" }), 0)
        assert.is_nil(s)
    end)

    it("returns nil when navigating numeric index with no array schema", function()
        -- 'name' is a string, not an array
        local s = sn.schema_at(root_schema, root_data, make_dt({ "name", "1" }), 0)
        assert.is_nil(s)
    end)

    it("navigates through a conditional (allOf) schema", function()
        local schema = {
            allOf = {
                {
                    properties = {
                        x = { type = "number" },
                    },
                },
            },
        }
        local s = sn.schema_at(schema, { x = 1 }, make_dt({ "x" }), 0)
        assert.not_nil(s)
        assert.equals("number", s.type)
    end)

    it("navigates through if/then conditional", function()
        local schema = {
            ["if"]   = { properties = { kind = { const = "str" } } },
            ["then"] = { properties = { value = { type = "string" } } },
            ["else"] = { properties = { value = { type = "number" } } },
        }
        -- data satisfies the if-condition
        local data = { kind = "str", value = "hello" }
        local s = sn.schema_at(schema, data, make_dt({ "value" }), 0)
        assert.not_nil(s)
        assert.equals("string", s.type)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- raw_schema_at
-- ─────────────────────────────────────────────────────────────────────────────

describe("schema_nav.raw_schema_at", function()
    it("preserves oneOf on the target node (not flattened)", function()
        local schema = {
            type       = "object",
            properties = {
                item = {
                    oneOf = {
                        { type = "string" },
                        { type = "number" },
                    },
                },
            },
        }
        local s = sn.raw_schema_at(schema, { item = "hi" }, make_dt({ "item" }), 0)
        assert.not_nil(s)
        assert.not_nil(s.oneOf)
        assert.is_nil(s.type)  -- raw: not flattened into a concrete type
    end)

    it("intermediate steps still use flatten for navigation", function()
        -- Root schema has a oneOf; flatten resolves which branch to navigate into.
        local schema = {
            oneOf = {
                {
                    properties = { x = { type = "string" } },
                    required   = { "x" },
                },
                {
                    properties = { y = { type = "number" } },
                    required   = { "y" },
                },
            },
        }
        -- data matches first branch
        local s = sn.raw_schema_at(schema, { x = "hello" }, make_dt({ "x" }), 0)
        assert.not_nil(s)
        assert.equals("string", s.type)
    end)

    it("returns nil for unknown path (same as schema_at)", function()
        local schema = {
            type       = "object",
            properties = { a = { type = "string" } },
        }
        local s = sn.raw_schema_at(schema, {}, make_dt({ "missing" }), 0)
        assert.is_nil(s)
    end)

    it("empty parts returns the root schema unflattened", function()
        local schema = {
            oneOf = {
                { type = "string" },
                { type = "number" },
            },
        }
        local s = sn.raw_schema_at(schema, "hi", make_dt({}), 0)
        assert.not_nil(s)
        assert.not_nil(s.oneOf)  -- not flattened at the end
    end)
end)
