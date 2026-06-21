---@diagnostic disable: undefined-global, undefined-field
require("plenary.busted")

local Tree = require("easytasks.util.Tree")

-- Collect (id, depth) pairs in walk order.
local function walk_order(tree)
    local out = {}
    tree:walk_tree(function(id, _, depth)
        out[#out + 1] = { id = id, depth = depth }
        return true
    end)
    return out
end

-- Just the ids, in walk order.
local function walk_ids(tree)
    local out = {}
    tree:walk_tree(function(id)
        out[#out + 1] = id
        return true
    end)
    return out
end

describe("easytasks.util.Tree", function()
    -- ──────────────────────────────────────────────────────────────────────────
    -- construction / basics
    -- ──────────────────────────────────────────────────────────────────────────
    describe("new", function()
        it("starts empty", function()
            local t = Tree.new()
            assert.same({}, t:get_roots())
            assert.same({}, t:get_items())
            assert.is_true(t:validate())
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────────────
    -- add_item
    -- ──────────────────────────────────────────────────────────────────────────
    describe("add_item", function()
        it("adds root items in insertion order", function()
            local t = Tree.new()
            t:add_item(nil, "a", 1)
            t:add_item(nil, "b", 2)
            t:add_item(nil, "c", 3)
            assert.same({ "a", "b", "c" }, walk_ids(t))
            assert.is_true(t:validate())
        end)

        it("adds children under a parent", function()
            local t = Tree.new()
            t:add_item(nil, "root", nil)
            t:add_item("root", "c1", nil)
            t:add_item("root", "c2", nil)
            assert.same({ "c1", "c2" }, t:get_children_ids("root"))
            assert.equals("root", t:get_parent_id("c1"))
            assert.is_true(t:validate())
        end)

        it("stores and returns data", function()
            local t = Tree.new()
            t:add_item(nil, "a", { v = 42 })
            assert.same({ v = 42 }, t:get_data("a"))
        end)

        it("errors on duplicate id", function()
            local t = Tree.new()
            t:add_item(nil, "a", 1)
            assert.has_error(function() t:add_item(nil, "a", 2) end)
        end)

        it("errors on nil id", function()
            local t = Tree.new()
            assert.has_error(function() t:add_item(nil, nil, 1) end)
        end)

        it("errors when parent does not exist", function()
            local t = Tree.new()
            assert.has_error(function() t:add_item("missing", "a", 1) end)
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────────────
    -- add_sibling
    -- ──────────────────────────────────────────────────────────────────────────
    describe("add_sibling", function()
        it("inserts after a root reference", function()
            local t = Tree.new()
            t:add_item(nil, "a", nil)
            t:add_item(nil, "c", nil)
            t:add_sibling("a", "b", nil, false)
            assert.same({ "a", "b", "c" }, walk_ids(t))
            assert.is_true(t:validate())
        end)

        it("inserts before a root reference", function()
            local t = Tree.new()
            t:add_item(nil, "b", nil)
            t:add_item(nil, "c", nil)
            t:add_sibling("b", "a", nil, true)
            assert.same({ "a", "b", "c" }, walk_ids(t))
            assert.is_true(t:validate())
        end)

        it("inserts before the first root and updates _root_first", function()
            local t = Tree.new()
            t:add_item(nil, "b", nil)
            t:add_sibling("b", "a", nil, true)
            assert.same({ "a", "b" }, walk_ids(t))
            assert.is_nil(t:get_prev_sibling_id("a"))
            assert.is_true(t:is_root("a"))
            assert.is_true(t:validate())
        end)

        it("inserts after the last root and updates _root_last", function()
            local t = Tree.new()
            t:add_item(nil, "a", nil)
            t:add_sibling("a", "b", nil, false)
            assert.is_nil(t:get_next_sibling_id("b"))
            assert.is_true(t:validate())
        end)

        it("inserts before a child reference", function()
            local t = Tree.new()
            t:add_item(nil, "root", nil)
            t:add_item("root", "b", nil)
            t:add_sibling("b", "a", nil, true)
            assert.same({ "a", "b" }, t:get_children_ids("root"))
            assert.is_true(t:validate())
        end)

        it("inserts after a child reference", function()
            local t = Tree.new()
            t:add_item(nil, "root", nil)
            t:add_item("root", "a", nil)
            t:add_item("root", "c", nil)
            t:add_sibling("a", "b", nil, false)
            assert.same({ "a", "b", "c" }, t:get_children_ids("root"))
            assert.is_true(t:validate())
        end)

        it("errors when reference does not exist", function()
            local t = Tree.new()
            assert.has_error(function() t:add_sibling("missing", "a", nil, false) end)
        end)

        it("errors on duplicate id", function()
            local t = Tree.new()
            t:add_item(nil, "a", nil)
            assert.has_error(function() t:add_sibling("a", "a", nil, false) end)
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────────────
    -- set_item_data
    -- ──────────────────────────────────────────────────────────────────────────
    describe("set_item_data", function()
        it("updates data and returns true", function()
            local t = Tree.new()
            t:add_item(nil, "a", 1)
            assert.is_true(t:set_item_data("a", 2))
            assert.equals(2, t:get_data("a"))
        end)

        it("returns false for a missing id", function()
            local t = Tree.new()
            assert.is_false(t:set_item_data("nope", 1))
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────────────
    -- queries
    -- ──────────────────────────────────────────────────────────────────────────
    describe("queries", function()
        local function sample()
            local t = Tree.new()
            t:add_item(nil, "root", "r")
            t:add_item("root", "a", "av")
            t:add_item("root", "b", "bv")
            t:add_item("a", "a1", "a1v")
            return t
        end

        it("have_item reflects presence", function()
            local t = sample()
            assert.is_true(t:have_item("a"))
            assert.is_false(t:have_item("missing"))
        end)

        it("is_root true only for parentless nodes", function()
            local t = sample()
            assert.is_true(t:is_root("root"))
            assert.is_false(t:is_root("a"))
            assert.is_false(t:is_root("missing"))
        end)

        it("have_children", function()
            local t = sample()
            assert.is_true(t:have_children("root"))
            assert.is_true(t:have_children("a"))
            assert.is_false(t:have_children("b"))
        end)

        it("get_depth counts ancestors", function()
            local t = sample()
            assert.equals(0, t:get_depth("root"))
            assert.equals(1, t:get_depth("a"))
            assert.equals(2, t:get_depth("a1"))
            assert.equals(0, t:get_depth(nil))
        end)

        it("get_depth errors on missing node", function()
            local t = sample()
            assert.has_error(function() t:get_depth("missing") end)
        end)

        it("get_parent_id", function()
            local t = sample()
            assert.is_nil(t:get_parent_id("root"))
            assert.equals("root", t:get_parent_id("a"))
            assert.equals("a", t:get_parent_id("a1"))
        end)

        it("get_parent_id errors on missing node", function()
            local t = sample()
            assert.has_error(function() t:get_parent_id("missing") end)
        end)

        it("first/last child ids", function()
            local t = sample()
            assert.equals("a", t:get_first_child_id("root"))
            assert.equals("b", t:get_last_child_id("root"))
            assert.is_nil(t:get_first_child_id("b"))
        end)

        it("prev/next sibling ids", function()
            local t = sample()
            assert.is_nil(t:get_prev_sibling_id("a"))
            assert.equals("b", t:get_next_sibling_id("a"))
            assert.equals("a", t:get_prev_sibling_id("b"))
            assert.is_nil(t:get_next_sibling_id("b"))
        end)

        it("get_children returns id+data items", function()
            local t = sample()
            assert.same(
                { { id = "a", data = "av" }, { id = "b", data = "bv" } },
                t:get_children("root")
            )
        end)

        it("get_roots returns top-level id+data items", function()
            local t = sample()
            assert.same({ { id = "root", data = "r" } }, t:get_roots())
        end)

        it("get_items returns every node", function()
            local t = sample()
            local ids = {}
            for _, item in ipairs(t:get_items()) do ids[item.id] = true end
            assert.same({ root = true, a = true, b = true, a1 = true }, ids)
        end)

        it("get_data returns nil for missing id", function()
            local t = sample()
            assert.is_nil(t:get_data("missing"))
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────────────
    -- iterators
    -- ──────────────────────────────────────────────────────────────────────────
    describe("iterators", function()
        it("iter_roots yields id,data in order", function()
            local t = Tree.new()
            t:add_item(nil, "a", 1)
            t:add_item(nil, "b", 2)
            local got = {}
            for id, data in t:iter_roots() do got[#got + 1] = { id, data } end
            assert.same({ { "a", 1 }, { "b", 2 } }, got)
        end)

        it("iter_children yields id,data in order", function()
            local t = Tree.new()
            t:add_item(nil, "root", nil)
            t:add_item("root", "a", 1)
            t:add_item("root", "b", 2)
            local got = {}
            for id, data in t:iter_children("root") do got[#got + 1] = { id, data } end
            assert.same({ { "a", 1 }, { "b", 2 } }, got)
        end)

        it("iter_children errors on missing parent", function()
            local t = Tree.new()
            assert.has_error(function() t:iter_children("missing") end)
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────────────
    -- walk_tree / walk_node
    -- ──────────────────────────────────────────────────────────────────────────
    describe("walk", function()
        local function sample()
            local t = Tree.new()
            t:add_item(nil, "r1", nil)
            t:add_item("r1", "a", nil)
            t:add_item("a", "a1", nil)
            t:add_item("r1", "b", nil)
            t:add_item(nil, "r2", nil)
            return t
        end

        it("walk_tree visits depth-first with correct depths", function()
            local t = sample()
            assert.same({
                { id = "r1", depth = 0 },
                { id = "a", depth = 1 },
                { id = "a1", depth = 2 },
                { id = "b", depth = 1 },
                { id = "r2", depth = 0 },
            }, walk_order(t))
        end)

        it("walk_tree stops descending when handler returns falsy", function()
            local t = sample()
            local seen = {}
            t:walk_tree(function(id)
                seen[#seen + 1] = id
                return id ~= "a" -- do not descend into a's children
            end)
            -- a is visited, but a1 (its child) is skipped
            assert.same({ "r1", "a", "b", "r2" }, seen)
        end)

        it("walk_node walks a subtree rooted at id", function()
            local t = sample()
            local seen = {}
            t:walk_node("a", function(id, _, depth)
                seen[#seen + 1] = { id = id, depth = depth }
                return true
            end)
            assert.same({ { id = "a", depth = 0 }, { id = "a1", depth = 1 } }, seen)
        end)

        it("walk_node errors on missing node", function()
            local t = sample()
            assert.has_error(function() t:walk_node("missing", function() return true end) end)
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────────────
    -- remove_item / remove_children
    -- ──────────────────────────────────────────────────────────────────────────
    describe("removal", function()
        it("remove_item drops the node and its subtree", function()
            local t = Tree.new()
            t:add_item(nil, "root", nil)
            t:add_item("root", "a", nil)
            t:add_item("a", "a1", nil)
            t:add_item("root", "b", nil)
            t:remove_item("a")
            assert.is_false(t:have_item("a"))
            assert.is_false(t:have_item("a1"))
            assert.same({ "b" }, t:get_children_ids("root"))
            assert.is_true(t:validate())
        end)

        it("remove_item relinks siblings (middle)", function()
            local t = Tree.new()
            t:add_item(nil, "a", nil)
            t:add_item(nil, "b", nil)
            t:add_item(nil, "c", nil)
            t:remove_item("b")
            assert.same({ "a", "c" }, walk_ids(t))
            assert.equals("c", t:get_next_sibling_id("a"))
            assert.equals("a", t:get_prev_sibling_id("c"))
            assert.is_true(t:validate())
        end)

        it("remove_item updates _root_first when removing first root", function()
            local t = Tree.new()
            t:add_item(nil, "a", nil)
            t:add_item(nil, "b", nil)
            t:remove_item("a")
            assert.same({ "b" }, walk_ids(t))
            assert.is_nil(t:get_prev_sibling_id("b"))
            assert.is_true(t:validate())
        end)

        it("remove_item is a no-op for a missing id", function()
            local t = Tree.new()
            t:add_item(nil, "a", nil)
            t:remove_item("missing")
            assert.same({ "a" }, walk_ids(t))
            assert.is_true(t:validate())
        end)

        it("remove_children clears children but keeps the node", function()
            local t = Tree.new()
            t:add_item(nil, "root", nil)
            t:add_item("root", "a", nil)
            t:add_item("root", "b", nil)
            t:remove_children("root")
            assert.is_true(t:have_item("root"))
            assert.is_false(t:have_children("root"))
            assert.is_false(t:have_item("a"))
            assert.is_nil(t:get_first_child_id("root"))
            assert.is_nil(t:get_last_child_id("root"))
            assert.is_true(t:validate())
        end)

        it("remove_children is a no-op for a missing id", function()
            local t = Tree.new()
            assert.has_no_error(function() t:remove_children("missing") end)
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────────────
    -- set_children
    -- ──────────────────────────────────────────────────────────────────────────
    describe("set_children", function()
        it("populates root children", function()
            local t = Tree.new()
            t:set_children(nil, {
                { id = "a", data = 1 },
                { id = "b", data = 2 },
            })
            assert.same({ "a", "b" }, walk_ids(t))
            assert.equals(1, t:get_data("a"))
            assert.is_true(t:validate())
        end)

        it("replaces existing children and their subtrees", function()
            local t = Tree.new()
            t:add_item(nil, "root", nil)
            t:add_item("root", "old", nil)
            t:add_item("old", "old1", nil)
            t:set_children("root", {
                { id = "new", data = nil },
            })
            assert.is_false(t:have_item("old"))
            assert.is_false(t:have_item("old1"))
            assert.same({ "new" }, t:get_children_ids("root"))
            assert.is_true(t:validate())
        end)

        it("errors on duplicate ids in the batch", function()
            local t = Tree.new()
            assert.has_error(function()
                t:set_children(nil, {
                    { id = "a", data = 1 },
                    { id = "a", data = 2 },
                })
            end)
        end)

        it("errors when parent does not exist", function()
            local t = Tree.new()
            assert.has_error(function()
                t:set_children("missing", { { id = "a", data = 1 } })
            end)
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────────────
    -- update_children
    -- ──────────────────────────────────────────────────────────────────────────
    describe("update_children", function()
        it("keeps surviving children and their subtrees, removes the rest", function()
            local t = Tree.new()
            t:add_item(nil, "root", nil)
            t:add_item("root", "a", "old_a")
            t:add_item("a", "a1", nil)
            t:add_item("root", "b", nil)
            t:update_children("root", {
                { id = "a", data = "new_a", keep_children = true },
                { id = "c", data = "new_c", keep_children = true },
            })
            -- a survives (with its subtree), b is gone, c is new
            assert.same({ "a", "c" }, t:get_children_ids("root"))
            assert.equals("new_a", t:get_data("a"))
            assert.is_true(t:have_item("a1"))
            assert.is_false(t:have_item("b"))
            assert.is_true(t:validate())
        end)

        it("reorders existing children to match the given order", function()
            local t = Tree.new()
            t:add_item(nil, "root", nil)
            t:add_item("root", "a", nil)
            t:add_item("root", "b", nil)
            t:add_item("root", "c", nil)
            t:update_children("root", {
                { id = "c", data = nil, keep_children = true },
                { id = "a", data = nil, keep_children = true },
                { id = "b", data = nil, keep_children = true },
            })
            assert.same({ "c", "a", "b" }, t:get_children_ids("root"))
            assert.is_true(t:validate())
        end)

        it("keep_children=false drops a surviving node's subtree", function()
            local t = Tree.new()
            t:add_item(nil, "root", nil)
            t:add_item("root", "a", nil)
            t:add_item("a", "a1", nil)
            t:update_children("root", {
                { id = "a", keep_children = false },
            })
            assert.is_true(t:have_item("a"))
            assert.is_false(t:have_item("a1"))
            assert.is_false(t:have_children("a"))
            assert.is_true(t:validate())
        end)

        it("errors on duplicate ids in the batch", function()
            local t = Tree.new()
            t:add_item(nil, "root", nil)
            assert.has_error(function()
                t:update_children("root", {
                    { id = "a" },
                    { id = "a" },
                })
            end)
        end)

        it("errors when an item id already lives under a different parent", function()
            local t = Tree.new()
            t:add_item(nil, "p1", nil)
            t:add_item(nil, "p2", nil)
            t:add_item("p1", "x", nil)
            assert.has_error(function()
                t:update_children("p2", { { id = "x", keep_children = true } })
            end)
        end)
    end)

    -- ──────────────────────────────────────────────────────────────────────────
    -- integration / invariants
    -- ──────────────────────────────────────────────────────────────────────────
    describe("invariants", function()
        it("stays consistent through a mix of operations", function()
            local t = Tree.new()
            t:add_item(nil, "root", nil)
            t:add_item("root", "a", nil)
            t:add_item("root", "b", nil)
            t:add_sibling("a", "z", nil, true)         -- z before a
            t:add_sibling("b", "c", nil, false)        -- c after b
            t:add_item("a", "a1", nil)
            t:set_children("a", { { id = "a2", data = nil } })
            t:remove_item("z")
            t:update_children("root", {
                { id = "b", keep_children = true },
                { id = "a", keep_children = true },
            })
            assert.same({ "b", "a" }, t:get_children_ids("root"))
            assert.is_false(t:have_item("c"))
            assert.is_false(t:have_item("a1"))
            assert.is_true(t:have_item("a2"))
            assert.is_true(t:validate())
        end)
    end)
end)
