---@diagnostic disable: undefined-global, undefined-field, missing-fields, need-check-nil
-- Unit tests for the LSP code action providers
-- (lua/tomltasks/lsp/server/actions.lua).
--
-- Each case is a TOML snippet with a single "|" cursor marker. The helper
-- strips the marker, runs the real parser/decoder pipeline into a buffer
-- context, asks a provider for actions and applies the chosen one's edits back
-- to the text, so the assertions are on the resulting document.

local parser  = require("tomltasks.tomltools.parser")
local decoder = require("tomltasks.tomltools.decoder")
local actions = require("tomltasks.lsp.server.actions")

local URI     = "file:///tasks.toml"

-- Helpers

-- Split a snippet on its single "|" cursor marker into (text, row0, col0).
local function split_cursor(s)
    local lines = vim.split(s, "\n", { plain = true })
    for r, line in ipairs(lines) do
        local c = line:find("|", 1, true)
        if c then
            lines[r] = line:sub(1, c - 1) .. line:sub(c + 1)
            return table.concat(lines, "\n"), r - 1, c - 1
        end
    end
    error("snippet has no '|' cursor marker")
end

local function make_ctx(text)
    local parsed = parser.parse(text)
    local dec    = decoder.decode(parsed.cst)
    return {
        schema      = {},
        cst         = parsed.cst,
        data        = dec.data,
        decode_tree = dec.decode_tree,
        text        = text,
        lines       = vim.split(text, "\n", { plain = true }),
    }
end

-- Apply one text edit (each of these actions returns exactly one).
local function apply(text, edit)
    local lines = vim.split(text, "\n", { plain = true })
    local s, e  = edit.range.start, edit.range["end"]
    local head  = (lines[s.line + 1] or ""):sub(1, s.character)
    local tail  = (lines[e.line + 1] or ""):sub(e.character + 1)

    local out   = {}
    for i = 1, s.line do out[#out + 1] = lines[i] end
    out[#out + 1] = head .. edit.newText .. tail
    for i = e.line + 2, #lines do out[#out + 1] = lines[i] end
    return table.concat(out, "\n")
end

-- Run a provider on a "|"-marked snippet; returns the action list and the text.
local function run(provider, snippet)
    local text, row, col = split_cursor(snippet)
    local params         = {
        textDocument = { uri = URI },
        range        = { start = { line = row, character = col }, ["end"] = { line = row, character = col } },
    }
    return provider(make_ctx(text), params), text
end

-- Run a provider and apply its single action; returns the rewritten document.
local function rewrite(provider, snippet)
    local list, text = run(provider, snippet)
    assert.equals(1, #list)
    return apply(text, list[1].edit.changes[URI][1])
end

describe("toggle_inline_table_layout", function()
    local toggle = actions.toggle_inline_table_layout

    it("expands a one-line inline table", function()
        assert.equals([[
[tasks.build]
opts = {
  jobs = 4,
  keep = true,
}]], rewrite(toggle, [[
[tasks.build]
opts = { jobs = 4, k|eep = true }]]))
    end)

    it("collapses an expanded inline table", function()
        assert.equals([[
[tasks.build]
opts = { jobs = 4, keep = true }]], rewrite(toggle, [[
[tasks.build]
opts = {|
  jobs = 4,
  keep = true
}]]))
    end)

    it("keeps the surrounding indentation", function()
        assert.equals([[
[tasks.build]
    opts = {
      jobs = 4,
    }]], rewrite(toggle, [[
[tasks.build]
    opts = { j|obs = 4 }]]))
    end)

    it("picks the innermost table under the cursor", function()
        assert.equals([[opts = { a = {
  b = 1,
} }]], rewrite(toggle, [[opts = { a = { b| = 1 } }]]))
    end)

    it("refuses a table holding comments", function()
        assert.equals(0, #(run(toggle, [[
opts = {|
  # why
  a = 1
}]])))
    end)

    it("refuses a table addressed by an index", function()
        assert.equals(0, #(run(toggle, [==[items = [ { a| = 1 } ]]==])))
    end)

    it("offers nothing away from an inline table", function()
        assert.equals(0, #(run(toggle, [[
[tasks.build]
comm|and = "make"]])))
    end)
end)

describe("toggle_array_layout", function()
    local toggle = actions.toggle_array_layout

    it("expands a one-line array", function()
        assert.equals([==[
[tasks.test]
depends_on = [
  "build",
  "lint",
]]==], rewrite(toggle, [==[
[tasks.test]
depends_on = [ "bu|ild", "lint" ]]==]))
    end)

    it("collapses an expanded array", function()
        assert.equals([==[
[tasks.test]
depends_on = [ "build", "lint" ]]==], rewrite(toggle, [==[
[tasks.test]
depends_on = [|
  "build",
  "lint",
]]==]))
    end)

    it("keeps the surrounding indentation", function()
        assert.equals([==[
[tasks.test]
    args = [
      1,
      2,
    ]]==], rewrite(toggle, [==[
[tasks.test]
    args = [ 1|, 2 ]]==]))
    end)

    it("works on an array inside an inline table", function()
        assert.equals([[opts = { args = [
  1,
  2,
], jobs = 4 }]], rewrite(toggle, [[opts = { args = [ 1|, 2 ], jobs = 4 }]]))
    end)

    it("leaves the enclosing table to the table action", function()
        local list = run(actions.toggle_inline_table_layout, [[opts = { args = [ 1|, 2 ] }]])
        assert.equals(0, #list)
    end)

    it("refuses an array holding comments", function()
        assert.equals(0, #(run(toggle, [==[
args = [|
  1, # why
  2,
]]==])))
    end)

    it("refuses an array nested in another array", function()
        assert.equals(0, #(run(toggle, [==[pairs = [ [ 1|, 2 ], [ 3, 4 ] ]]==])))
    end)

    it("offers nothing for an empty array", function()
        assert.equals(0, #(run(toggle, [==[args = [|]]==])))
    end)

    it("offers nothing away from an array", function()
        assert.equals(0, #(run(toggle, [[
[tasks.build]
comm|and = "make"]])))
    end)
end)
