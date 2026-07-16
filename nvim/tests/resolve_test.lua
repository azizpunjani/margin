-- resolve: record archives thread, extmark removed, pending skips it
local repo = os.getenv 'REPO'
vim.opt.rtp:prepend(os.getenv 'PLUGIN')
vim.cmd 'runtime! plugin/margin.lua'
vim.fn.mkdir(repo .. '/.margin', 'p')
local f = assert(io.open(repo .. '/.margin/review.jsonl', 'w'))
f:write '{"type":"comment","id":"c1","ts":1,"file":"a.txt","line":1,"side":"new","excerpt":"x","text":"q1","status":"pending"}\n'
f:write '{"type":"comment","id":"c2","ts":2,"file":"a.txt","line":1,"endLine":2,"side":"new","excerpt":"y","text":"q2","status":"pending"}\n'
f:close()
vim.cmd.edit(repo .. '/a.txt')
local m = require 'margin'
m.attach(vim.api.nvim_get_current_buf())
local ns = vim.api.nvim_create_namespace 'margin'
assert(#vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) == 2, 'want 2 threads rendered')

-- resolve thread at cursor (line 1 -> c1)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
m.resolve()
local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
assert(#marks == 1, 'want 1 thread after resolve, got ' .. #marks)
assert(vim.inspect(marks):match 'q2', 'remaining thread should be c2')
-- range thread (L1-2, anchored at 2): cursor INSIDE range at line 1 must find it
vim.api.nvim_win_set_cursor(0, { 1, 0 })
m.resolve()
assert(#vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) == 0, 'range thread not resolved from inside range')
local f2 = assert(io.open(repo .. '/.margin/review.jsonl', 'a'))
f2:write '{"type":"comment","id":"c3","ts":3,"file":"a.txt","line":1,"side":"new","excerpt":"x","text":"q3","status":"pending"}\n'
f2:close()
m.render(vim.fs.root(0, '.git'))
local content = table.concat(vim.fn.readfile(repo .. '/.margin/review.jsonl'), '\n')
assert(content:match '"type":"resolve"', 'resolve record missing')

-- resolve all
m.resolve(true)
assert(#vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) == 0, 'want 0 after resolve all')
-- submit finds nothing pending
m.submit()
print 'RESOLVE_OK'
