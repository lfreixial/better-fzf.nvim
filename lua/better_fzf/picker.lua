-- better_fzf.picker — fzf terminal picker + helpers
--
-- Runs `search_argv | fzf [...] > outfile` inside a terminal buffer so fzf has
-- a real TTY. On exit the selection(s) are read from the outfile and handed to
-- the caller. Returns false so callers can fall back to quickfix if fzf is
-- missing or the terminal job fails to start.

local api = vim.api
local M = {}

--- Escape argv items and join them into one shell pipeline stage.
local function esc(argv)
  local parts = {}
  for _, a in ipairs(argv) do
    parts[#parts + 1] = vim.fn.shellescape(a)
  end
  return table.concat(parts, ' ')
end

--- Open a window for the terminal picker.
-- @return buf, win
local function open_window(cfg, title)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  local win
  if cfg.layout == 'float' then
    local width = math.max(20, math.floor(vim.o.columns * (cfg.width or 0.9)))
    local height = math.max(5, math.floor(vim.o.lines * (cfg.height or 0.6)))
    win = api.nvim_open_win(buf, true, {
      relative = 'editor',
      row = math.max(0, math.floor((vim.o.lines - height) / 2)),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      width = width,
      height = height,
      style = 'minimal',
      border = cfg.border or 'rounded',
      title = title or '',
      title_pos = 'center',
    })
  else
    win = api.nvim_open_win(buf, true, {
      split = 'below',
      height = math.max(5, math.floor(vim.o.lines * (cfg.height or 0.6))),
    })
  end
  return buf, win
end

--- Build the fzf argv.
-- @param cfg better_fzf config
-- @param preview_command string|nil  --preview template (nil = no preview)
-- @param delimiter string|nil  field delimiter (':' for path:line:col rows)
local function fzf_argv(cfg, preview_command, delimiter)
  local argv = { 'fzf', '--multi' }
  if delimiter then
    argv[#argv + 1] = '--delimiter'
    argv[#argv + 1] = delimiter
  end
  argv[#argv + 1] = '--layout=reverse'
  -- persist the fuzzy query between invocations
  vim.fn.mkdir(vim.fn.stdpath('data'), 'p')
  argv[#argv + 1] = '--history'
  argv[#argv + 1] = vim.fn.stdpath('data') .. '/better_fzf_history'
  if preview_command then
    argv[#argv + 1] = '--preview'
    argv[#argv + 1] = preview_command
    argv[#argv + 1] = '--preview-window'
    argv[#argv + 1] = cfg.preview_window or 'right,40%'
  end
  for _, a in ipairs(cfg.extra_fzf_args or {}) do
    argv[#argv + 1] = a
  end
  return argv
end

--- Context preview for grep rows. awk prints ±ctx lines with numbers and
-- clamps near BOF (sed -n "-2,4p" errors on early matches; awk doesn't).
-- {2} = line number, {1} = file path (fzf placeholders).
-- NOTE: fzf already substitutes placeholders with single-quoted values, so do
-- NOT wrap them in extra quotes here: "{1}" would hand awk literal quote chars.
-- @return string|nil  preview command, nil when ctx <= 0
function M.context_preview(ctx)
  local n = tonumber(ctx) or 3
  if n <= 0 then return nil end
  return ('awk -v ln={2} -v ctx=%d "NR>=ln-ctx && NR<=ln+ctx {print NR \\"  \\" \\$0}" {1}'):format(n)
end

--- Run an interactive fzf pick over a producer argv.
-- @param opts { argv: string[], cfg: table, title?: string, preview?: string|false,
--               delimiter?: string, on_select: fun(lines: string[]),
--               on_cancel?: fun(), on_spawn?: fun(job_id) }
function M.pick(opts)
  local cfg = opts.cfg
  local out = vim.fn.tempname()

  if vim.fn.executable('fzf') ~= 1 then
    vim.notify('better_fzf: fzf not found on $PATH', vim.log.levels.ERROR)
    return false
  end

  local fzf = fzf_argv(cfg, opts.preview, opts.delimiter)
  local pipeline = esc(opts.argv) .. ' | ' .. esc(fzf) .. ' > ' .. vim.fn.shellescape(out)

  local buf, win = open_window(cfg, opts.title)
  local closed = false

  -- <Esc><Esc> force-closes the picker window even while fzf is still running
  vim.keymap.set('t', '<Esc><Esc>', function()
    if not closed then
      closed = true
      pcall(api.nvim_win_close, win, true)
    end
  end, { buffer = buf, silent = true })

  local job = vim.fn.termopen({ 'bash', '-c', pipeline }, {
    on_exit = function(_, code)
      vim.schedule(function()
        if closed then
          os.remove(out)
          return
        end
        closed = true
        if win and api.nvim_win_is_valid(win) then
          pcall(api.nvim_win_close, win, true)
        end
        if code == 0 then
          local lines = {}
          local f = io.open(out, 'rb')
          if f then
            for l in f:lines() do
              if l ~= '' then lines[#lines + 1] = l end
            end
            f:close()
          end
          if #lines == 0 then
            vim.notify('better_fzf: no matches', vim.log.levels.INFO)
          else
            pcall(opts.on_select, lines)
          end
        elseif code == 1 or code == 130 then
          -- 1 = no match, 130 = cancelled (Esc/Ctrl-C inside fzf)
          pcall(opts.on_cancel or function() end)
        else
          vim.notify(('better_fzf: fzf exited with %d'):format(code), vim.log.levels.ERROR)
        end
        os.remove(out)
      end)
    end,
  })

  if job <= 0 then
    if api.nvim_win_is_valid(win) then pcall(api.nvim_win_close, win, true) end
    vim.notify('better_fzf: failed to start terminal job', vim.log.levels.ERROR)
    return false
  end
  if opts.on_spawn then pcall(opts.on_spawn, job) end
  vim.cmd('startinsert')
  return true
end

return M
