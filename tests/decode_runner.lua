-- tests/decode_runner.lua
-- Run with: nvim -l tests/decode_runner.lua
-- Reads TOML from stdin, writes toml-test tagged JSON to stdout.
-- Exits non-zero on invalid TOML.

local cwd = vim.fn.getcwd()
vim.opt.rtp:append(vim.fs.joinpath(vim.fn.fnamemodify(cwd, ":h")))

local helper = require("toml_test_helper")

local toml = io.read("*a")
local json, err = helper.parse_to_tagged_json(toml)

if err then
    io.stderr:write(err .. "\n")
    os.exit(1)
end

io.write(json .. "\n")
