local schema_nav = require("easytasks.parse.schema_nav")

describe("schema_nav.matches_filter", function()
  it("matches empty prefix", function()
    assert.is_true(schema_nav.matches_filter("", "workspace"))
  end)

  it("matches case-insensitively", function()
    assert.is_true(schema_nav.matches_filter("WORK", "workspace"))
    assert.is_false(schema_nav.matches_filter("files", "workspace"))
  end)

  it("matches dotted prefixes", function()
    assert.is_true(schema_nav.matches_filter("workspace.", "workspace.files"))
  end)
end)
