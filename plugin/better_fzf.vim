" better-fzf.nvim — plugin entrypoint
" Loads the Lua core lazily on first command use.
if exists('g:loaded_better_fzf') | finish | endif
let g:loaded_better_fzf = 1

" Grep content:  :BFzf [pattern] [types...]     e.g. :BFzf "hello" go
" Pick a file:   :BFzfFile [types...]           e.g. :BFzfFile go,ts
command! -nargs=* -bar BetterFzf     lua require('better_fzf').cmd(<q-args>)
command! -nargs=* -bar BFzf          lua require('better_fzf').cmd(<q-args>)
command! -nargs=* -bar BetterFzfFile lua require('better_fzf').file_cmd(<q-args>)
command! -nargs=* -bar BFzfFile      lua require('better_fzf').file_cmd(<q-args>)

" Compatibility alias (filetype-grep name used in some configs)
command! -nargs=* -bar BfzfGrep      lua require('better_fzf').cmd(<q-args>)
