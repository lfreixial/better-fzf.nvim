-- better_fzf.input — floating prompt window.
--
-- A centered single-line prompt with an optional file-type field toggled via
-- <C-g>. Replaces the bottom-of-screen vim.fn.input prompts.
--
-- Keys (insert mode):
--   <C-g>  toggle to the next field (pattern <-> file type)
--   <CR>   run the search with the entered values
--   <Esc>  cancel

local api = vim.api
local M = {}

local LABEL = {
  pattern = 'pattern (regex)',
  type = 'file type (empty = all)',
}

local function title_for(fields, idx)
  local f = fields[idx]
  if #fields > 1 then
    local other = LABEL[fields[idx % #fields + 1]]
    return (' ' .. LABEL[f] .. '  ·  <C-g> ' .. other .. ' · <CR> run · <Esc> cancel')
  end
  return (' ' .. LABEL[f] .. '  ·  <CR> run · <Esc> cancel')
end

--- Open a floating prompt.
-- @param opts { cfg?: table, pattern?: bool, type?: bool,
--               on_confirm?: fun(values), on_cancel?: fun() }
--   values = { pattern = string|nil, type = string|nil } (enabled fields only)
-- @return win, buf
function M.prompt(opts)
  local cfg = opts.cfg or {}
  local fields = {}
  if opts.pattern then fields[#fields + 1] = 'pattern' end
  if opts.type then fields[#fields + 1] = 'type' end
  if #fields == 0 then fields = { 'pattern' } end

  local values = { pattern = '', type = '' }
  local idx = 1

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  api.nvim_buf_set_lines(buf, 0, -1, false, { '' })

  local width = math.max(40, math.floor(vim.o.columns * (cfg.width or 0.7)))
  local win = api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.max(0, math.floor((vim.o.lines - 3) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = 1,
    style = 'minimal',
    border = cfg.border or 'rounded',
    title = title_for(fields, 1),
    title_pos = 'center',
  })

  local closed = false
  local function close()
    if closed then return end
    closed = true
    if api.nvim_win_is_valid(win) then pcall(api.nvim_win_close, win, true) end
  end

  local function commit_field()
    local line = api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''
    values[fields[idx]] = line
  end

  local function refresh_title()
    -- title update via win config (0.10+); harmless no-op before that
    pcall(api.nvim_win_set_config, win, { title = title_for(fields, idx) })
  end

  local function switch_field()
    commit_field()
    idx = idx % #fields + 1
    api.nvim_buf_set_lines(buf, 0, -1, false, { values[fields[idx]] })
    api.nvim_win_set_cursor(win, { 1, #values[fields[idx]] })
    refresh_title()
  end

  local function confirm()
    commit_field()
    close()
    if opts.on_confirm then opts.on_confirm(values) end
  end

  local function cancel()
    close()
    if opts.on_cancel then opts.on_cancel() end
  end

  vim.keymap.set('i', '<CR>', confirm, { buffer = buf, nowait = true })
  if #fields > 1 then
    vim.keymap.set('i', '<C-g>', switch_field, { buffer = buf, nowait = true })
  end
  -- no `nowait` on <Esc>: nvim must wait a beat so arrow keys (<Esc>[D) still work
  vim.keymap.set('i', '<Esc>', cancel, { buffer = buf })
  vim.keymap.set('i', '<C-c>', cancel, { buffer = buf })

  -- Programmatic handle (also used by the headless tests): lets callers drive
  -- the prompt without insert-mode keys, which headless nvim can't produce.
  if opts.on_ready then
    opts.on_ready({ switch = switch_field, confirm = confirm, cancel = cancel, buf = buf, win = win })
  end

  -- Enter insert mode. Deferred: when opened from a terminal job's on_exit
  -- (e.g. live-grep <C-g>), a synchronous startinsert can be ignored, leaving
  -- the float stuck in normal mode.
  api.nvim_set_current_win(win)
  vim.schedule(function()
    if api.nvim_win_is_valid(win) then
      api.nvim_set_current_win(win)
      vim.cmd('startinsert')
    end
  end)
  return win, buf
end

return M
