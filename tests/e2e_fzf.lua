-- End-to-end: drive the real fzf UI (termopen gives fzf a pty even headless).
-- Usage: TERM=xterm-256color BFZF_REPO=... BFZF_FIXTURE=... nvim --headless -u NONE -l tests/e2e_fzf.lua

local repo = os.getenv('BFZF_REPO')
local fix = os.getenv('BFZF_FIXTURE')
assert(repo and fix, 'BFZF_REPO / BFZF_FIXTURE not set')

vim.opt.rtp:append(repo)
vim.opt.shadafile = 'NONE'
vim.opt.swapfile = false
vim.cmd('runtime plugin/better_fzf.vim')
vim.fn.chdir(fix)

local bf = require('better_fzf')

-- neutral starting file
vim.cmd('edit sub/nothing.txt')

local job_id = nil
vim.schedule(function()
  bf.grep({
    pattern = 'hello',
    types = 'go',
    on_spawn = function(j)
      job_id = j
    end,
  })
end)

local fails = 0
local function t(name, cond, extra)
  if cond then
    io.write('PASS  ' .. name .. '\n')
  else
    fails = fails + 1
    io.write('FAIL  ' .. name .. '\n')
    if extra ~= nil then io.write('      ' .. tostring(extra) .. '\n') end
  end
end

-- 1. picker job spawned
local got_job = vim.wait(5000, function()
  return job_id ~= nil
end)
t('picker terminal job spawned', got_job)
if not got_job then
  io.write('RESULT E2E ABORT (no job)\n')
  os.exit(1)
end

-- 2. let fzf initialize, then narrow the list to hello_test.go and accept
vim.wait(600, function() return false end)
vim.fn.chansend(job_id, 'hello_test')
vim.wait(250, function() return false end)
vim.fn.chansend(job_id, '\r')

-- 3. selection should edit hello_test.go and land the cursor on 'hello'
local got_file = vim.wait(6000, function()
  return vim.fn.expand('%'):find('hello_test%.go') ~= nil
end)
t('selection opened hello_test.go', got_file, 'current file: ' .. vim.fn.expand('%'))

vim.wait(150, function() return false end) -- settle after cursor placement
local cur = vim.api.nvim_win_get_cursor(0)
local content = vim.fn.getline(cur[1])
-- smart case: 'hello' matches 'Hello' inside TestHello first (byte 10 -> col 9)
local expect_col0 = content:lower():find('hello', 1, true)
expect_col0 = expect_col0 and expect_col0 - 1 or -1
io.write(('      opened=%s line=%d col0=%d expect_col0=%d\n'):format(vim.fn.expand('%'), cur[1], cur[2], expect_col0))
t('cursor on match line', cur[1] == 1)
t('cursor on match column', cur[2] == expect_col0, 'got ' .. cur[2])

io.write(('RESULT %s\n'):format(fails == 0 and 'E2E PASS' or (fails .. ' FAILURE(S)')))
os.exit(fails == 0 and 0 or 1)
