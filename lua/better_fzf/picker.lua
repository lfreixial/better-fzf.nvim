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

-- ------------------------------------------------ live grep

--- Shell-quote with single quotes (for embedding static values like globs
-- into the reload command, which fzf runs through `$SHELL -c`).
local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- rg base flags shared by the reload command and the initial producer.
local function live_rg_base(o)
  local argv = { 'rg', '--column', '--no-heading', '--color', 'never' }
  local case = o.case or 'smart'
  if case == 'sensitive' then
    argv[#argv + 1] = '-s'
  elseif case == 'insensitive' then
    argv[#argv + 1] = '-i'
  else
    argv[#argv + 1] = '-S'
  end
  if o.respects_ignore == false then argv[#argv + 1] = '--no-ignore' end
  if o.hidden then argv[#argv + 1] = '--hidden' end
  return argv
end

--- The `change:reload` command string. {q} is left bare: fzf substitutes it
-- with a single-quoted value (man: "you should not manually add quotes").
function M.live_reload_cmd(o, globs)
  local parts = live_rg_base(o)
  for _, g in ipairs(globs or {}) do
    parts[#parts + 1] = '-g'
    parts[#parts + 1] = shq(g)
  end
  parts[#parts + 1] = '-e'
  parts[#parts + 1] = '{q}'
  parts[#parts + 1] = '.'
  return table.concat(parts, ' ') .. ' || true'
end

--- Initial producer argv (rg with the initial query) — pre-populates the list
-- when re-launching after a file-type change.
local function live_producer(o, globs, query)
  local argv = live_rg_base(o)
  for _, g in ipairs(globs or {}) do
    argv[#argv + 1] = '-g'
    argv[#argv + 1] = g
  end
  argv[#argv + 1] = '-e'
  argv[#argv + 1] = query
  argv[#argv + 1] = '.'
  return argv
end

--- Parse fzf output produced with `--print-query --expect ctrl-g`.
-- line 1 = query, line 2 = completing key ('' = enter), lines 3+ = selection.
function M.parse_exit(lines)
  local selection = {}
  for i = 3, #lines do
    if lines[i] ~= '' then selection[#selection + 1] = lines[i] end
  end
  return { query = lines[1] or '', key = lines[2] or '', selection = selection }
end

--- Run live grep: the typed query IS the regex; results stream in via
-- `change:reload`. <C-g> (via --expect) exits and hands the query to
-- opts.on_filetype so the caller can prompt for a file type and re-launch.
-- @param o merged config
-- @param opts { globs?: string[], initial_query?: string,
--               on_select: fun(lines), on_filetype: fun(query),
--               on_cancel?: fun(), on_spawn?: fun(job) }
function M.live_grep(o, opts)
  if vim.fn.executable('fzf') ~= 1 then
    vim.notify('better_fzf: fzf not found on $PATH', vim.log.levels.ERROR)
    return false
  end

  local out = vim.fn.tempname()
  local globs = opts.globs or {}

  local fzf = { 'fzf', '--disabled', '--delimiter', ':', '--layout', 'reverse' }
  local pv = M.context_preview(o.preview_lines)
  if pv then
    fzf[#fzf + 1] = '--preview'
    fzf[#fzf + 1] = pv
    fzf[#fzf + 1] = '--preview-window'
    fzf[#fzf + 1] = o.preview_window or 'right,40%'
  end
  fzf[#fzf + 1] = '--bind'
  fzf[#fzf + 1] = 'change:reload:' .. M.live_reload_cmd(o, globs)
  fzf[#fzf + 1] = '--expect'
  fzf[#fzf + 1] = 'ctrl-g'
  fzf[#fzf + 1] = '--print-query'
  if opts.initial_query and opts.initial_query ~= '' then
    fzf[#fzf + 1] = '--query'
    fzf[#fzf + 1] = opts.initial_query
  end
  for _, a in ipairs(o.extra_fzf_args or {}) do
    fzf[#fzf + 1] = a
  end

  local producer
  if opts.initial_query and opts.initial_query ~= '' then
    producer = live_producer(o, globs, opts.initial_query)
  else
    producer = { 'true' }
  end

  local pipeline = esc(producer) .. ' | ' .. esc(fzf) .. ' > ' .. vim.fn.shellescape(out)
  local buf, win = open_window(o, 'grep (live)')
  local closed = false

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
        if win and api.nvim_win_is_valid(win) then pcall(api.nvim_win_close, win, true) end
        if code == 0 then
          local lines = {}
          local f = io.open(out, 'rb')
          if f then
            for l in f:lines() do lines[#lines + 1] = l end
            f:close()
          end
          local parsed = M.parse_exit(lines)
          if parsed.key == 'ctrl-g' then
            local q = parsed.query
            -- Defer: closing a terminal window inside on_exit can leave the
            -- terminal's exit-mode restoration pending, which steals focus
            -- from the float we open next. Let teardown finish first.
            vim.defer_fn(function()
              pcall(opts.on_filetype, q)
            end, 120)
          elseif #parsed.selection == 0 then
            vim.notify('better_fzf: no matches', vim.log.levels.INFO)
          else
            pcall(opts.on_select, parsed.selection)
          end
        elseif code == 1 or code == 130 then
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
  -- Deferred: when re-launched from a prompt's on_confirm (also a callback),
  -- a synchronous startinsert can be ignored and fzf never gets the keys.
  api.nvim_set_current_win(win)
  vim.schedule(function()
    if api.nvim_win_is_valid(win) then
      api.nvim_set_current_win(win)
      vim.cmd('startinsert')
    end
  end)
  return true
end

return M
