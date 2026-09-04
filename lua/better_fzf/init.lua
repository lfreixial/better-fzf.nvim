-- better_fzf — fzf with regex grep and file-type scoping, minus the bloat.
--
--   :BFzf "hello" go            find "hello" in *.go files (regex)
--   :BFzf "func .*Error" ts,go  regex across Go + TypeScript files
--   :BFzf "hello"               search "hello" across ALL file types
--   :BFzf                       prompt for pattern, then file types (Enter = all)
--   :BFzfFile go,ts             pick a file from *.go and *.ts (fuzzy)
--
-- Lua API:
--   require('better_fzf').setup({ ... })
--   require('better_fzf').grep({ pattern = 'hello', types = { 'go' } })
--   require('better_fzf').files({ types = 'go,ts' })

local backend = require('better_fzf.backend')
local picker = require('better_fzf.picker')
local api = vim.api

local M = {}

local DEFAULTS = {
  backend = 'auto', -- "auto" | "rg" | "grep"
  case = 'smart', -- "smart" | "sensitive" | "insensitive"
  default_types = nil, -- e.g. { "go", "ts" } when the user gives none (nil = all)
  literal = false, -- treat pattern as fixed string instead of regex
  respects_ignore = true, -- rg honours .gitignore/.ignore
  hidden = false, -- include hidden files
  layout = 'float', -- "float" | "split"
  width = 0.9, -- float width as fraction of columns
  height = 0.6, -- height as fraction of lines
  border = 'rounded',
  preview_lines = 3, -- context lines shown above/below a match (0 = off)
  preview_window = 'right,40%',
  extra_fzf_args = {}, -- e.g. { "--no-multi" }
  driver = 'auto', -- "auto" | "fzf" | "qf" (qf = straight to quickfix)
  open = 'edit', -- how to open a single match: "edit" | "split" | "vsplit" | "tabedit"
  center = true, -- zz after jumping to a match
  file_preview = false, -- show a preview pane in :BFzfFile
}

local cfg = vim.deepcopy(DEFAULTS)

--- Merge user config over defaults.
function M.setup(user)
  cfg = vim.tbl_deep_extend('force', vim.deepcopy(DEFAULTS), user or {})
  return M
end

--- Current effective config (read-only use).
function M.config()
  return cfg
end

-- ------------------------------------------------ helpers

--- Tokenize command args, honouring "double quoted", 'single quoted' and
--- backslash escapes so patterns with spaces work: :BFzf "hello world" go
local function parse_cli(raw)
  raw = raw or ''
  local out = {}
  local i, n = 1, #raw
  while i <= n do
    local c = raw:sub(i, i)
    if c == ' ' or c == '\t' then
      i = i + 1
    elseif c == '"' or c == "'" then
      local q = c
      local j = i + 1
      local buf = {}
      while j <= n do
        local ch = raw:sub(j, j)
        if ch == '\\' and j < n then
          local nx = raw:sub(j + 1, j + 1)
          if nx == q or nx == '\\' then
            buf[#buf + 1] = nx
            j = j + 2
          else
            buf[#buf + 1] = ch
            j = j + 1
          end
        elseif ch == q then
          break
        else
          buf[#buf + 1] = ch
          j = j + 1
        end
      end
      out[#out + 1] = table.concat(buf)
      i = j + 1
    else
      local j = i
      while j <= n and not raw:sub(j, j):match('[ \t]') do
        j = j + 1
      end
      out[#out + 1] = raw:sub(i, j - 1)
      i = j
    end
  end
  return out
end

--- vim.fn.input wrapper that returns '' on <Esc>.
local function prompt(question, default)
  local ok, res = pcall(vim.fn.input, { prompt = question, default = default or '' })
  if not ok or res == nil then return '' end
  return res
end

local OPEN_CMDS = { edit = 'edit', split = 'split', vsplit = 'vsplit', tabedit = 'tabedit' }

local function open_cmd(how)
  return OPEN_CMDS[how] or 'edit'
end

-- ------------------------------------------------ quickfix

local function fill_qf(rows, title)
  local items = {}
  for _, r in ipairs(rows) do
    items[#items + 1] = { filename = r.file, lnum = r.line, col = r.col, text = r.text }
  end
  vim.fn.setqflist({}, 'r', { title = title or 'better_fzf', items = items })
  pcall(vim.cmd, 'copen')
end

-- ------------------------------------------------ open results

--- Open a parsed row in the configured way and land the cursor on the match.
local function open_row(r, o)
  vim.cmd(('%s %s'):format(open_cmd(o.open), vim.fn.fnameescape(r.file)))
  api.nvim_win_set_cursor(0, { r.line or 1, math.max((r.col or 1) - 1, 0) })
  if o.center then vim.cmd('normal! zz') end
end

--- Dispatch fzf selections: 1 line -> jump, many -> quickfix.
local function on_grep_lines(lines, o, backend_name)
  if #lines == 1 then
    local r = backend.parse_row(lines[1], backend_name)
    if r then
      open_row(r, o)
      return
    end
  end
  local rows = {}
  for _, l in ipairs(lines) do
    local r = backend.parse_row(l, backend_name)
    if r then rows[#rows + 1] = r end
  end
  fill_qf(rows)
end

-- ------------------------------------------------ grep

--- Grep content. opts: { pattern?, types?, prompt_types?, literal?, case?, driver?, ... }
function M.grep(opts)
  local o = vim.tbl_deep_extend('force', cfg, opts or {})

  if type(o.pattern) ~= 'string' or o.pattern == '' then
    o.pattern = prompt('Search pattern (regex): ')
    if o.pattern == '' then return end
  end

  local globs = backend.parse_types(o.types)
  if #globs == 0 and o.default_types then
    globs = backend.parse_types(o.default_types)
  end
  if #globs == 0 and o.prompt_types then
    local raw = prompt('File types (comma-sep, empty = all): ')
    if raw ~= '' then globs = backend.parse_types(raw) end
  end

  local search = {
    pattern = o.pattern,
    globs = globs,
    literal = o.literal,
    case = o.case,
    respects_ignore = o.respects_ignore,
    hidden = o.hidden,
    backend = o.backend,
  }

  local driver = o.driver == 'auto' and (vim.fn.executable('fzf') == 1 and 'fzf' or 'qf') or o.driver

  if driver == 'qf' then
    local ok, err = pcall(backend.search_async, search, function(rows, _, code, errmsg)
      if code and code > 1 then
        vim.notify(('better_fzf: search failed (%s)'):format(errmsg or code), vim.log.levels.ERROR)
      elseif #rows == 0 then
        vim.notify('better_fzf: no matches', vim.log.levels.INFO)
      else
        fill_qf(rows)
      end
    end)
    if not ok then vim.notify('better_fzf: ' .. tostring(err), vim.log.levels.ERROR) end
    return
  end

  if vim.fn.executable('fzf') ~= 1 then
    vim.notify('better_fzf: fzf not found on $PATH', vim.log.levels.ERROR)
    return
  end

  local ok, argv, backend_name = pcall(backend.build, search)
  if not ok then
    vim.notify('better_fzf: ' .. tostring(argv), vim.log.levels.ERROR)
    return
  end

  picker.pick({
    argv = argv,
    cfg = o,
    title = ('grep: %s'):format(o.pattern),
    preview = picker.context_preview(o.preview_lines),
    delimiter = ':',
    on_spawn = o.on_spawn,
    on_select = function(lines)
      on_grep_lines(lines, o, backend_name)
    end,
    on_cancel = function()
      vim.notify('better_fzf: cancelled', vim.log.levels.INFO)
    end,
  })
end

-- ------------------------------------------------ file picker

--- Pick a file (fuzzy by name). types scope the file set; default = all.
function M.files(opts)
  local o = vim.tbl_deep_extend('force', cfg, opts or {})

  local globs = backend.parse_types(o.types)
  if #globs == 0 and o.default_types then
    globs = backend.parse_types(o.default_types)
  end

  local ok, argv = pcall(backend.files_argv, {
    globs = globs,
    respects_ignore = o.respects_ignore,
    hidden = o.hidden,
    backend = o.backend,
  })
  if not ok then
    vim.notify('better_fzf: ' .. tostring(argv), vim.log.levels.ERROR)
    return
  end

  local driver = o.driver == 'auto' and (vim.fn.executable('fzf') == 1 and 'fzf' or 'qf') or o.driver

  if driver == 'qf' then
    local out = vim.fn.systemlist(argv)
    if vim.v.shell_error ~= 0 then
      vim.notify('better_fzf: rg --files failed', vim.log.levels.ERROR)
      return
    end
    local rows = {}
    for _, f in ipairs(out) do
      if f ~= '' then rows[#rows + 1] = { file = f, line = 1, col = 1, text = f } end
    end
    if #rows == 0 then
      vim.notify('better_fzf: no files', vim.log.levels.INFO)
      return
    end
    fill_qf(rows, 'better_fzf files')
    return
  end

  if vim.fn.executable('fzf') ~= 1 then
    vim.notify('better_fzf: fzf not found on $PATH', vim.log.levels.ERROR)
    return
  end

  local preview = o.file_preview and ('head -n %d {}'):format(math.max(o.preview_lines, 1) * 4) or nil
  picker.pick({
    argv = argv,
    cfg = o,
    title = 'files',
    preview = preview,
    on_spawn = o.on_spawn,
    on_select = function(lines)
      if #lines == 1 then
        open_row({ file = lines[1], line = 1, col = 1 }, o)
      else
        local rows = {}
        for _, f in ipairs(lines) do
          rows[#rows + 1] = { file = f, line = 1, col = 1, text = f }
        end
        fill_qf(rows, 'better_fzf files')
      end
    end,
  })
end

-- ------------------------------------------------ commands

local COMMANDS = {
  BetterFzf = { fn = 'cmd', desc = 'Regex-grep with fzf; optional file types' },
  BFzf = { fn = 'cmd', desc = 'Regex-grep with fzf; optional file types' },
  BfzfGrep = { fn = 'cmd', desc = 'Alias of BFzf' },
  BetterFzfFile = { fn = 'file_cmd', desc = 'Fuzzy file picker; optional file types' },
  BFzfFile = { fn = 'file_cmd', desc = 'Fuzzy file picker; optional file types' },
}

local registered = false

--- Register :BFzf / :BFzfFile user commands (idempotent).
-- Registered via nvim_create_user_command so double-quoted patterns survive:
-- legacy `command!` defs treat `"` in args as a comment and drop them.
-- Any pre-existing placeholder (e.g. lazy.nvim cmd stubs) is replaced.
function M.register_commands()
  if registered then return M end
  registered = true
  for name, spec in pairs(COMMANDS) do
    pcall(vim.api.nvim_del_user_command, name)
    vim.api.nvim_create_user_command(name, function(a)
      M[spec.fn](a.args)
    end, { nargs = '*', desc = 'better-fzf.nvim: ' .. spec.desc })
  end
  return M
end

--- :BFzf [pattern] [types...]
function M.cmd(raw)
  local tokens = parse_cli(raw)
  if #tokens == 0 then
    M.grep({ prompt_types = true })
    return
  end
  local pattern = tokens[1]
  local types
  if #tokens > 1 then
    local rest = {}
    for i = 2, #tokens do
      rest[#rest + 1] = tokens[i]
    end
    types = table.concat(rest, ',')
  end
  M.grep({ pattern = pattern, types = types })
end

--- :BFzfFile [types...]
function M.file_cmd(raw)
  local tokens = parse_cli(raw)
  if #tokens > 0 then
    M.files({ types = table.concat(tokens, ',') })
  else
    M.files({})
  end
end

M.register_commands()

return M
