-- Shared bootstrap for the test suite: ensures plenary is available, puts the
-- plugin and plenary on the runtimepath, and configures tomltasks. Sourced both
-- by tests/init.lua (the harness entry point) and by each child nvim that
-- plenary spawns per spec file (passed as `minimal_init`), so the two stay in
-- sync and the child nvims run with a fully-set-up environment.

local PLENARY_REPO   = "https://github.com/nvim-lua/plenary.nvim"
local PLENARY_COMMIT = "74b06c6c75e4eeb3108ec01852001636d85a932b"
local plenary_dir    = os.getenv("NVIM_PLENARY_DIR") or "/tmp/plenary.nvim"

-- Re-clone when the checkout is missing OR incomplete. A bare directory check
-- is not enough: /tmp cleanup can wipe the files while leaving empty dirs
-- behind, which leaves plenary unrequireable.
local marker = plenary_dir .. "/lua/plenary/test_harness.lua"
if vim.fn.filereadable(marker) == 0 then
    print("cloning plenary.nvim @ " .. PLENARY_COMMIT .. " …")
    vim.fn.delete(plenary_dir, "rf")
    vim.fn.system({ "git", "init", plenary_dir })
    vim.fn.system({ "git", "-C", plenary_dir, "fetch", "--depth", "1", PLENARY_REPO, PLENARY_COMMIT })
    vim.fn.system({ "git", "-C", plenary_dir, "checkout", "FETCH_HEAD" })
end

vim.opt.rtp:append(".")
vim.opt.rtp:append(plenary_dir)

require("tomltasks").setup()
