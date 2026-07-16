-- Core protocol: comment ids, submit, threaded user replies, pending, presence.
local repo = os.getenv 'REPO'
vim.opt.rtp:prepend(os.getenv 'PLUGIN')
vim.cmd 'runtime! plugin/margin.lua'
assert(vim.fn.exists ':MarginReply' == 2 and vim.fn.exists ':MarginReview' == 2, 'commands missing')

vim.fn.mkdir(repo .. '/.margin', 'p')
local f = assert(io.open(repo .. '/.margin/review.jsonl', 'w'))
f:write '{"type":"comment","id":"c3","ts":1,"file":"a.txt","line":1,"side":"new","excerpt":"line1","text":"seed","status":"pending"}\n'
f:close()

vim.cmd.edit(repo .. '/a.txt')
local m = require 'margin'
vim.api.nvim_win_set_cursor(0, { 2, 0 })
local rec = m.add_comment 'why two?'
assert(rec.id == 'c4', 'id should continue sequence, got ' .. rec.id)

-- AI answers c4 -> not pending
f = assert(io.open(repo .. '/.margin/review.jsonl', 'a'))
f:write '{"type":"reply","replyTo":"c4","ts":2,"text":"because"}\n'
f:close()
m.show()

-- user replies within thread via <leader>mr path (cursor below c4 anchor)
vim.api.nvim_win_set_cursor(0, { 3, 0 })
vim.ui.input = function(_, cb) cb 'but why though' end
m.reply()
local lines = vim.fn.readfile(repo .. '/.margin/review.jsonl')
local ur = vim.json.decode(lines[#lines])
assert(ur.type == 'user-reply' and ur.replyTo == 'c4' and ur.text == 'but why though' and type(ur.ts) == 'number', 'user-reply record wrong: ' .. lines[#lines])

-- render: interleaved ts order (comment, AI, user) + pending marker back on c4
local nsid = vim.api.nvim_get_namespaces().margin
local block
for _, mk in ipairs(vim.api.nvim_buf_get_extmarks(0, nsid, 0, -1, { details = true })) do
  local s = ''
  for _, vl in ipairs(mk[4].virt_lines or {}) do
    s = s .. vl[1][1] .. '\n'
  end
  if s:find('why two?', 1, true) then block = s end
end
assert(block, 'c4 thread not rendered')
assert(block:find('💬 why two? ⏳', 1, true), 'user-reply should reopen pending: ' .. block)
local ai, user = block:find('🤖 because', 1, true), block:find('👤 but why though', 1, true)
assert(ai and user and ai < user, 'messages not interleaved in order: ' .. block)

-- submit picks up c3 (never answered) and c4 (reopened by user-reply)
m.submit()
lines = vim.fn.readfile(repo .. '/.margin/review.jsonl')
local sub = vim.json.decode(lines[#lines])
assert(sub.type == 'submit' and vim.deep_equal(sub.ids, { 'c3', 'c4' }), 'submit ids wrong: ' .. lines[#lines])

-- presence: write, <10-line throttle, >=10 rewrite, per-file
assert(m.presence(0, 1) == true, 'first presence write')
local p = vim.json.decode(table.concat(vim.fn.readfile(repo .. '/.margin/presence.json')))
assert(p.file == 'a.txt' and p.line == 1 and type(p.ts) == 'number', 'presence shape wrong')
assert(m.presence(0, 5) == nil, 'moved <10 lines: must skip')
assert(vim.json.decode(table.concat(vim.fn.readfile(repo .. '/.margin/presence.json'))).line == 1, 'throttled write mutated file')
assert(m.presence(0, 40) == true, 'moved >=10 lines: must write')
assert(vim.json.decode(table.concat(vim.fn.readfile(repo .. '/.margin/presence.json'))).line == 40, 'presence not updated')
vim.cmd.edit(repo .. '/b.txt')
assert(m.presence(0, 1) == true, 'different file: must write')
assert(vim.json.decode(table.concat(vim.fn.readfile(repo .. '/.margin/presence.json'))).file == 'b.txt', 'presence file not updated')

print 'PROTOCOL_OK'
