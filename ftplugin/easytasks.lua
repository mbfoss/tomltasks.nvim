-- Make `easytasks` files behave exactly like TOML.
--
-- Neovim auto-sources ftplugin/syntax files by filetype *name*, so the runtime
-- `toml` files never run for us. `ftplugin/toml.vim` sets
-- commentstring/comments/iskeyword and, crucially, `b:undo_ftplugin`, so
-- leaving the filetype restores those options. Regex highlighting is handled
-- separately by syntax/easytasks.vim.

vim.cmd("runtime! ftplugin/toml.vim")
