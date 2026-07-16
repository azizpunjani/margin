-- reply-chunk streaming: ▌ cursor, superseded by final reply, and streaming
-- still works after a user-reply reopens the thread.
local repo = os.getenv 'REPO'
vim.opt.rtp:prepend(os.getenv 'PLUGIN')
local nsid = vim.api.nvim_create_namespace 'margin'
local function marks()
  return vim.inspect(vim.api.nvim_buf_get_extmarks(0, nsid, 0, -1, { details = true }))
end
local function append(s)
  local f = assert(io.open(repo .. '/.margin/review.jsonl', 'a'))
  f:write(s .. '\n')
  f:close()
end

vim.fn.mkdir(repo .. '/.margin', 'p')
append '{"type":"comment","id":"c1","ts":1,"file":"a.txt","line":1,"side":"new","excerpt":"line1","text":"hm","status":"pending"}'
append '{"type":"reply-chunk","replyTo":"c1","ts":2,"text":"thinking about "}'
append '{"type":"reply-chunk","replyTo":"c1","ts":3,"text":"line1..."}'
vim.cmd.edit(repo .. '/a.txt')
local m = require 'margin'
m.attach(vim.api.nvim_get_current_buf())
local t = marks()
assert(t:match 'thinking about line1%.%.%. ▌', 'chunk stream not rendered: ' .. t)
assert(not t:match '⏳', 'no pending marker while streaming')

append '{"type":"reply","replyTo":"c1","ts":4,"text":"final answer"}'
local root = vim.fs.root(0, '.git')
m.render(root)
t = marks()
assert(t:match 'final answer' and not t:match '▌', 'final reply should supersede chunks')

-- user-reply reopens the thread; new chunks must stream again after it
append '{"type":"user-reply","replyTo":"c1","ts":5,"text":"and what about line2?"}'
m.render(root)
assert(marks():match '⏳', 'user-reply should reopen pending')
append '{"type":"reply-chunk","replyTo":"c1","ts":6,"text":"checking line2 "}'
m.render(root)
t = marks()
assert(t:match 'checking line2 +▌', 'chunks after user-reply not streamed: ' .. t)
assert(t:match '👤 and what about line2', 'user reply line missing')
assert(not t:match '⏳', 'pending marker should hide while streaming')

append '{"type":"reply","replyTo":"c1","ts":7,"text":"line2 is fine"}'
m.render(root)
t = marks()
assert(t:match 'line2 is fine' and not t:match '▌', 'second final reply should supersede chunks')
print 'CHUNK_OK'
