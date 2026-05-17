local schema = require("easytasks.parse.schema")
local toml_emit = require("easytasks.parse.toml_emit")
local toml_parse = require("easytasks.parse.toml_parse")

describe("toml_emit", function()
  it("emits schema-ordered sections", function()
    local data = {
      workspace = {
        name = "myproject",
        files = {
          include = { "*.lua" },
          exclude = {},
          follow_symlinks = true,
        },
      },
    }
    local out = toml_emit.format_data(data, schema)
    assert.matches("%[workspace%]", out)
    assert.matches("%[workspace%.files%]", out)
    assert.matches('name = "myproject"', out)
    assert.matches("follow_symlinks = true", out)
    assert.matches("include = %[", out)
    assert.is_not.matches("include = %{", out)
    local name_pos = out:find("name = ")
    local files_pos = out:find("%[workspace%.files%]")
    assert.is_true(name_pos < files_pos)
  end)

  it("round-trips through parse and emit", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "toml"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "follow_symlinks = false",
      "[workspace]",
      'name = "z"',
      "[workspace.files]",
      'include = [ "a.toml" ]',
      "exclude = []",
    })
    local parsed = toml_parse.parse(buf)
    assert.truthy(parsed.data)
    local out = toml_emit.format_data(parsed.data, schema)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.matches("%[workspace%]", out)
    assert.matches('name = "z"', out)
    assert.matches("follow_symlinks = false", out)
    assert.matches('include = %[ "a%.toml" %]', out)
  end)
end)

describe("format", function()
  local format = require("easytasks.lsp.format")
  local toml_context = require("easytasks.parse.toml_context")

  before_each(function()
    toml_context.set_schema(schema)
  end)

  it("rejects buffers with syntax errors", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "toml"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'name = "' })
    local parsed = toml_parse.parse(buf)
    if #parsed.syntax_errors == 0 then
      pending("treesitter did not report a syntax error for this fixture")
    end
    local edit, err = format.build_edit(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.is_nil(edit)
    assert.truthy(err)
  end)
end)
