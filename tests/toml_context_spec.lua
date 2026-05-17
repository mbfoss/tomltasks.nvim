local toml_context = require("easytasks.parse.toml_context")
local default_schema = require("easytasks.parse.schema")

describe("toml_context value side", function()
  local bufnr

  before_each(function()
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].filetype = "toml"
    toml_context.set_schema(default_schema)
  end)

  after_each(function()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  local function ctx_at(line, col)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(line, "\n"))
    return toml_context.get(bufnr, 0, col)
  end

  it("detects value side after = at root", function()
    local ctx = ctx_at("workspace = ", 12)
    assert.equals("table_value", ctx.kind)
    assert.equals("workspace", ctx.key)
  end)

  it("detects value side in a table section", function()
    local ctx = ctx_at("[workspace]\nname = ", 14)
    assert.equals("table_value", ctx.kind)
    assert.equals("name", ctx.key)
    assert.same({ "workspace" }, ctx.path)
  end)

  it("detects key side before =", function()
    local ctx = ctx_at("workspace", 4)
    assert.equals("root_key", ctx.kind)
  end)
end)
