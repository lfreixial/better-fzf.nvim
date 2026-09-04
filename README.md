# better-fzf.nvim

An fzf picker that does **regex content search** across your project, scoped to
**the file types you say** — and every file type when you don't.

```
:BFzf "hello" go            → regex "hello" in *.go files
:BFzf "func .*Error" ts,go  → regex across Go + TypeScript files
:BFzf "hello"               → search "hello" across ALL file types
:BFzf                       → floating prompt (type pattern, <C-g> file type)
:BFzfFile go,ts             → pick a file among *.go / *.ts (fuzzy names)
```

No telescope. No fzf-lua. No UI framework. Just ripgrep (`rg`, with a `grep`
fallback) piped into fzf, plus a quickfix fallback for machines without fzf.

![CI](https://github.com/lfreixial/better-fzf.nvim/workflows/CI/badge.svg)

## Demo

![better-fzf.nvim demo](demo/better-fzf-demo.gif)

Try it yourself in ~10 seconds — the demo uses an isolated config in a
throwaway dir, so nothing on your machine is touched (needs `nvim` + `rg`;
`fzf` optional, results fall back to quickfix without it):

```sh
git clone https://github.com/lfreixial/better-fzf.nvim
cd better-fzf.nvim
bash demo/demo.sh
```

Inside the demo project, try `:BFzf "hello" go`, `:BFzf TODO go`, `:BFzfFile go`
or the `<leader>fg/ff/fw` mappings.

## Why "better fzf"

Plain `fzf` fuzzy-matches *filenames* but can't regex-search *file contents*.
This gives you the layered combo:

1. **rg** finds regex matches (real regex, not subsequence fuzz) —
2. **fzf** lets you narrow the result list fuzzy as you type (the "better fzf"
   part) — with a live, line-numbered context preview —
3. **Enter** jumps straight to the match; **Tab** to multi-select and dump all
   into the quickfix list.

## Requirements

- Neovim >= 0.9
- `rg` (ripgrep) — recommended; plain `grep` is used automatically if missing
- `fzf` binary on `$PATH` — optional: without it, results go straight to the
  quickfix list

## Install

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ 'lfreixial/better-fzf.nvim', lazy = true, cmd = { 'BFzf', 'BFzfFile' } }
```

[pckr.nvim](https://github.com/lewis6991/pckr.nvim) / packer / paq: add the
repo and call `require('better_fzf').setup({})` in your config — or skip
`setup()` entirely; every option has a default.

## Usage

### Grep (regex, type-scoped)

```
:BFzf <pattern> [types...]
```

| Form | Behaviour |
| --- | --- |
| `:BFzf "hello world" go` | regex `hello world` in `*.go` |
| `:BFzf "^func " go,!*_test.go` | anchored regex, test files excluded |
| `:BFzf hello` | regex `hello`, all file types |
| `:BFzf` | floating prompt — type the pattern, `<C-g>` for file type, `<CR>` to run |
| `:BFzf "struct .*Error"` | pattern only → all files |
| `:BFzfFile` | pick a file (fuzzy), all files |
| `:BFzfFile go,ts,rs` | pick a file among those types |

Type tokens are flexible:

- `go` → `*.go` (extension shorthand)
- `*.go`, `src/**`, `docs/*.md` → used as a literal glob
- `!*_test.go` → exclusion glob
- `go, ts, !vendor/**` → comma/space separated list, mixed

**Default is every file type** — types are purely additive narrowing.

### In the prompt window

Running `:BFzf` bare (or `bf.grep({})` / `<leader>fg`) opens a floating prompt
instead of a bottom-of-screen input:

- Type the regex, `<CR>` to search — skip the file type and it defaults to **all** file types
- `<C-g>` toggles to the **file type** field (`go`, `go,ts`, `!*_test.go`, …); `<CR>` runs with it — no separate "file types" prompt
- `<Esc>` cancels

### In the picker

- Type to fuzzy-filter the rg matches (query matches against the full
  `path:line:col:text` row)
- `Enter` — jump to the match (cursor lands on the exact match column)
- `Tab` / `Shift-Tab` — multi-select; `Enter` then sends all selections to the
  quickfix list
- `Ctrl-C` / `Ctrl-G` — cancel
- `Esc` `Esc` — force-close the picker window
- Right pane previews ±N lines of context around the match, with line numbers

### Lua API

```lua
local bf = require('better_fzf')

bf.setup({ case = 'sensitive', preview_lines = 5 }) -- global defaults

-- one-off search, jump straight in
bf.grep({ pattern = 'hello', types = { 'go', 'ts' } })

-- straight to quickfix, no fzf required
bf.grep({ pattern = 'TODO', driver = 'qf' })

-- file picker
bf.files({ types = 'go' })
```

## Options

```lua
require('better_fzf').setup({
  backend = 'auto',          -- 'auto' | 'rg' | 'grep'
  case = 'smart',            -- 'smart' | 'sensitive' | 'insensitive'
  default_types = nil,       -- e.g. { 'go' } applied when none given (nil = all)
  literal = false,           -- true = treat pattern as fixed string, not regex
  respects_ignore = true,    -- rg honours .gitignore / .ignore
  hidden = false,            -- also search hidden files/dirs
  layout = 'float',          -- 'float' | 'split'
  width = 0.9,               -- float size (fractions of the editor)
  height = 0.6,
  prompt_width = 0.6,        -- floating prompt width (fraction of columns)
  border = 'rounded',
  preview_lines = 3,         -- context lines above/below a match (0 = off)
  preview_window = 'right,40%',
  extra_fzf_args = {},       -- e.g. { '--no-multi' }
  driver = 'auto',           -- 'auto' | 'fzf' | 'qf'
  open = 'edit',             -- 'edit' | 'split' | 'vsplit' | 'tabedit'
  center = true,             -- zz after jumping
  file_preview = false,      -- preview pane in :BFzfFile
})
```

## Key bindings suggestion

```lua
local bf = require('better_fzf')
vim.keymap.set('n', '<leader>fg', function() bf.grep({}) end) -- opens the floating prompt
vim.keymap.set('n', '<leader>ff', function() bf.files({}) end)
-- grep the word under the cursor (as a regex)
vim.keymap.set('n', '<leader>fw', function()
  bf.grep({ pattern = vim.fn.expand('<cword>') })
end)
```

## Notes & trade-offs

- rg output uses byte columns, which is what Neovim's cursor API expects — tabs
  and multibyte text land correctly.
- The `grep` fallback is regex (`-E`) but has no column info and does **not**
  respect `.gitignore`/`.ignore`. Install ripgrep for the full experience.
- The file picker needs ripgrep (`rg --files`).
- The fzf preview runs through `$SHELL`; a filename containing a literal
  double-quote could, in theory, break that preview (not the search). Rare
  enough to ignore, noted for completeness.

## Development

Tests are plain headless nvim scripts (no busted needed):

```sh
export PATH="$HOME/.local/bin:$PATH"   # wherever nvim/rg/fzf live
BFZF_REPO="$PWD" BFZF_FIXTURE="$PWD/tests/fixture" nvim --headless -u NONE -l tests/run.lua
BFZF_REPO="$PWD" BFZF_FIXTURE="$PWD/tests/fixture" TERM=xterm-256color nvim --headless -u NONE -l tests/e2e_fzf.lua
```

The second test drives the *real* fzf UI headlessly (termopen gives fzf a PTY,
`chansend` feeds it keystrokes) and asserts the final cursor position. CI runs
both on every push.

## Roadmap

- Live query → regex re-run (rg --json streaming as you type)
- `--no-ignore` / hidden / literal toggles bound inside the picker
- File picker preview via `bat`
- Windows support (currently assumes a POSIX shell for the fzf pipeline)

MIT
