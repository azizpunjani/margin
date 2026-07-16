-- Watcher lifecycle: armed while a repo window is visible, stopped by gc()
-- when none remain, re-armed on attach.
local repo = os.getenv 'REPO'
vim.opt.rtp:prepend(os.getenv 'PLUGIN')
local function append(s)
  local f = assert(io.open(repo .. '/.margin/review.jsonl', 'a'))
  f:write(s .. '\n')
  f:close()
end

vim.fn.mkdir(repo .. '/.margin', 'p')
append '{"type":"comment","id":"c1","ts":1,"file":"a.txt","line":1,"side":"new","excerpt":"line1","text":"hm","status":"pending"}'

vim.cmd.edit(repo .. '/a.txt')
local m = require 'margin'
m.attach(vim.api.nvim_get_current_buf())
local root = vim.fs.root(0, '.git')
assert(m.watching(root), 'watcher should arm on attach')

-- Only window switches to a non-repo buffer -> gc stops the watcher.
vim.cmd.enew()
m.gc()
assert(not m.watching(root), 'watcher should stop when no window shows the repo')

-- Coming back re-arms.
vim.cmd.edit(repo .. '/a.txt')
m.attach(vim.api.nvim_get_current_buf())
assert(m.watching(root), 'watcher should re-arm on attach')

-- Repo still visible in another window -> gc keeps it.
vim.cmd.vsplit()
vim.cmd.enew()
m.gc()
assert(m.watching(root), 'watcher must survive while another window shows the repo')
print 'GC_OK'
