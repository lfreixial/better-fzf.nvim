" better-fzf.nvim — plugin entrypoint
"
" Commands are registered through Lua (nvim_create_user_command): legacy
" :command! defs would treat `"` in args as a comment and eat quoted patterns.
if exists('g:loaded_better_fzf') | finish | endif
let g:loaded_better_fzf = 1

lua require('better_fzf').register_commands()
