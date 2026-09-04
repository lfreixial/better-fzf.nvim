#!/usr/bin/env bash
# Try better-fzf.nvim without touching your real Neovim config.
#
#   bash demo/demo.sh
#
# Requires: nvim (>= 0.9) and ripgrep on $PATH. fzf is optional — when it is
# missing, results go straight to the quickfix list instead of the picker.
#
# Everything runs in a throwaway XDG dir; nothing outside this box is touched.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for bin in nvim rg; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "demo: '$bin' not found on \$PATH — install it first." >&2
    exit 1
  fi
done
if ! command -v fzf >/dev/null 2>&1; then
  echo "demo: fzf not found — matches will go to the quickfix list (still works)." >&2
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

export XDG_CONFIG_HOME="$scratch/config"
export XDG_DATA_HOME="$scratch/data"
export XDG_STATE_HOME="$scratch/state"
export XDG_CACHE_HOME="$scratch/cache"
mkdir -p "$XDG_CONFIG_HOME/nvim"

cat > "$XDG_CONFIG_HOME/nvim/init.lua" <<LUA
vim.opt.rtp:append('$repo')
vim.opt.number = true
vim.cmd('runtime plugin/better_fzf.vim')
require('better_fzf').setup({ extra_fzf_args = { '--no-history' } }) -- deterministic demo

vim.keymap.set('n', '<leader>fg', function()
  require('better_fzf').grep({})
end)
vim.keymap.set('n', '<leader>ff', function()
  require('better_fzf').files({})
end)
vim.keymap.set('n', '<leader>fw', function()
  require('better_fzf').grep({ pattern = vim.fn.expand('<cword>') })
end)

print('demo: :BFzf \"hello\" go | :BFzfFile | <leader>fg/ff/fw')
LUA

cd "$repo/demo/project"
exec nvim -u "$XDG_CONFIG_HOME/nvim/init.lua" cmd/server/main.go "$@"
