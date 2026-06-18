" Highlight `easytasks` files using the TOML syntax.
"
" Loaded by Neovim's Syntax mechanism (`:syntax on` sets syntax=easytasks on
" FileType), which is the correct hook for aliasing one filetype's syntax to
" another -- doing `runtime! syntax/toml.vim` from the ftplugin gets clobbered
" when that mechanism runs afterwards. When TOML tree-sitter highlight queries
" are installed the ftplugin starts tree-sitter on top of this, exactly as a
" normal `.toml` buffer behaves.
if exists('b:current_syntax')
  finish
endif

runtime! syntax/toml.vim
