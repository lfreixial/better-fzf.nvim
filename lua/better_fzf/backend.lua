-- better_fzf.backend — search backends (ripgrep preferred, grep fallback)
--
-- Builds and runs content searches. Row format from rg:
--   path:line:col:text        (--column)
-- from grep -rE (no column support):
--   path:line:text

local M = {}

--- Detect an available backend, honouring a user preference.
-- @param pref string|nil  "auto" | "rg" | "grep"
-- @return string|nil backend name, or nil if none found
function M.detect(pref)
  local p = pref or 'auto'
  if p ~= 'auto' then
    if vim.fn.executable(p) == 1 then return p end
    return nil
  end
  if vim.fn.executable('rg') == 1 then return 'rg' end
  if vim.fn.executable('grep') == 1 then return 'grep' end
  return nil
end

--- Convert one user type token into an rg -g glob.
--  "go"            -> "*.go"
--  "*.go", "src/x" -> passed through as-is (anything containing glob metachars)
--  "!*_test.go"    -> "!*_test.go" (exclusion)
function M.to_glob(tok)
  local t = tostring(tok):gsub('^%s+', ''):gsub('%s+$', '')
  if t == '' then return nil end
  local excl = t:sub(1, 1) == '!'
  local body = excl and t:sub(2) or t
  local glob
  if body:find('[%*%?%[]') then
    glob = body
  else
    glob = '*.' .. body
  end
  return (excl and '!' or '') .. glob
end

--- Normalize user type input (string "go, ts" or list) into glob list.
-- @param tokens string|string[]|nil
-- @return string[] globs (empty = all files)
function M.parse_types(tokens)
  local globs = {}
  local list
  if type(tokens) == 'string' then
    list = { tokens }
  else
    list = tokens or {}
  end
  for _, tok in ipairs(list) do
    for piece in tostring(tok):gmatch('[^,%s]+') do
      local g = M.to_glob(piece)
      if g then globs[#globs + 1] = g end
    end
  end
  return globs
end

local ROW_RG = '^([^:]+):(%d+):(%d+):(.*)$'
local ROW_GR = '^([^:]+):(%d+):(.*)$'

--- Parse one raw output line into a row.
-- @return {file,line,col,text}|nil
local function normalize_file(f)
  -- rg/grep print "./x" when given "." as the search path
  return (f:gsub('^%./', ''))
end

function M.parse_row(line, backend)
  if backend == 'rg' then
    local f, l, c, t = line:match(ROW_RG)
    if not f then return nil end
    return { file = normalize_file(f), line = tonumber(l), col = tonumber(c), text = t }
  end
  local f, l, t = line:match(ROW_GR)
  if not f then return nil end
  return { file = normalize_file(f), line = tonumber(l), col = 1, text = t }
end

--- Build argv for a content search.
-- opts: { pattern, globs?, literal?, case?, respects_ignore?, hidden?, backend? }
-- @return argv table, backend name
function M.build(opts)
  local pattern = opts.pattern
  if type(pattern) ~= 'string' or pattern == '' then
    error('better_fzf: pattern is required')
  end
  if pattern:find('[\r\n]') then
    error('better_fzf: pattern must be a single line')
  end
  local globs = opts.globs or {}
  local backend = M.detect(opts.backend)
  if not backend then error('better_fzf: no search backend found (install ripgrep)') end

  local argv
  if backend == 'rg' then
    argv = { 'rg', '--line-number', '--no-heading', '--color', 'never', '--column' }
    if opts.literal then argv[#argv + 1] = '--fixed-strings' end
    local case = opts.case or 'smart'
    if case == 'sensitive' then
      argv[#argv + 1] = '-s'
    elseif case == 'insensitive' then
      argv[#argv + 1] = '-i'
    else
      -- rg is case-sensitive by default; smart-case is opt-in via -S
      argv[#argv + 1] = '-S'
    end
    if opts.respects_ignore == false then argv[#argv + 1] = '--no-ignore' end
    if opts.hidden then argv[#argv + 1] = '--hidden' end
    for _, g in ipairs(globs) do
      argv[#argv + 1] = '-g'
      argv[#argv + 1] = g
    end
    argv[#argv + 1] = '-e'
    argv[#argv + 1] = pattern
    -- explicit path: without one, rg reads stdin when it is not a TTY
    -- (jobstart/pipelines keep stdin open -> hang). '.' keeps cwd search.
    argv[#argv + 1] = '.'
  else
    -- grep fallback: -rE regex, -I skip binary, -n line numbers, no color
    argv = { 'grep', '-rEnI', '--color=never' }
    if opts.literal then argv[#argv + 1] = '-F' end
    local case = opts.case or 'smart'
    if case == 'insensitive' then
      argv[#argv + 1] = '-i'
    elseif case == 'smart' and not pattern:find('%u') then
      argv[#argv + 1] = '-i' -- grep has no smart case; emulate for lowercase patterns
    end
    for _, g in ipairs(globs) do
      if g:sub(1, 1) == '!' then
        argv[#argv + 1] = '--exclude=' .. g:sub(2)
      else
        argv[#argv + 1] = '--include=' .. g
      end
    end
    argv[#argv + 1] = '-e'
    argv[#argv + 1] = pattern
    -- same stdin caveat as rg: grep without paths reads stdin
    argv[#argv + 1] = '.'
  end
  return argv, backend
end

--- Synchronous search. Convenience for scripting/tests.
-- @return rows, backend
function M.search(opts)
  local argv, backend = M.build(opts)
  local out = vim.fn.systemlist(argv)
  local code = vim.v.shell_error
  if code ~= 0 and code ~= 1 then
    error(('better_fzf: %s exited with %d'):format(backend, code))
  end
  local rows = {}
  for _, line in ipairs(out) do
    local r = M.parse_row(line, backend)
    if r then rows[#rows + 1] = r end
  end
  return rows, backend
end

--- Async search for the quickfix path (no UI freeze on big repos).
-- @param opts same as M.build
-- @param on_done function(rows, backend, exit_code)
function M.search_async(opts, on_done)
  local argv, backend = M.build(opts)
  local rows = {}
  local stderr = {}
  local job = vim.fn.jobstart(argv, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do
        local r = M.parse_row(line, backend)
        if r then rows[#rows + 1] = r end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= '' then stderr[#stderr + 1] = line end
      end
    end,
    on_exit = function(_, code)
      -- jobstart callbacks already run on the main loop; no vim.schedule needed
      on_done(rows, backend, code, table.concat(stderr, '\n'))
    end,
  })
  if job <= 0 then error('better_fzf: failed to start ' .. backend) end
end

--- Argv for the file-name picker (rg --files honours ignore rules + globs).
-- opts: { globs?, respects_ignore?, hidden? }
-- @return argv, backend
function M.files_argv(opts)
  local globs = opts.globs or {}
  local backend = M.detect(opts.backend)
  if backend ~= 'rg' then
    error('better_fzf: file picker needs ripgrep (rg --files)')
  end
  local argv = { 'rg', '--files', '--no-messages' }
  if opts.respects_ignore == false then argv[#argv + 1] = '--no-ignore' end
  if opts.hidden then argv[#argv + 1] = '--hidden' end
  for _, g in ipairs(globs) do
    argv[#argv + 1] = '-g'
    argv[#argv + 1] = g
  end
  return argv, backend
end

return M
