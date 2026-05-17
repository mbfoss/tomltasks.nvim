local toml_parse = require("easytasks.parse.toml_parse")

describe("toml_parse (tinytoml)", function()
  local bufnr

  before_each(function()
    bufnr = vim.api.nvim_create_buf(false, true)
  end)

  after_each(function()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("parses valid toml", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "[workspace]",
      'name = "test"',
      "",
      "[workspace.files]",
      "include = []",
      "exclude = []",
      "follow_symlinks = true",
    })
    local parsed = toml_parse.parse(bufnr)
    assert.is_true(parsed.ok)
    assert.same("test", parsed.data.workspace.name)
    assert.same({}, parsed.data.workspace.files.include)
  end)

  it("reports syntax errors", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'name = "' })
    local parsed = toml_parse.parse(bufnr)
    assert.is_false(parsed.ok)
    assert.is_nil(parsed.data)
    assert.is_true(#parsed.syntax_errors > 0)
  end)

  it("strips filename from syntax error messages", function()
    local err = table.concat({
      "",
      "",
      "In 'string input', line 2:",
      "",
      '  2 | name = "',
      "",
      "Unable to find closing quote for string",
      "",
      "See https://toml.io/en/v1.1.0#string for more details",
    }, "\n")
    local msg = toml_parse.clean_error_message(err)
    assert.equals("Unable to find closing quote for string", msg)
    assert.is_nil(msg:match("string input"))
  end)
end)
