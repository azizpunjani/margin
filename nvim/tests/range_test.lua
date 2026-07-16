-- visual-range comments: endLine recorded, anchor at range end, no cursor jump
vim.opt.rtp:prepend(os.getenv 'PLUGIN')
local repo = os.getenv 'REPO' .. '-range'
vim.fn.mkdir(repo .. '/.margin', 'p')
vim.fn.system { 'git', '-C', repo, 'init', '-q' }
vim.fn.writefile({ 'l1', 'l2', 'l3', 'l4', 'l5', 'l6' }, repo .. '/f.txt')
vim.fn.system { 'git', '-C', repo, 'add', '.' }
vim.fn.system { 'git', '-C', repo, 'commit', '-qm', 'i' }
io.open(repo .. '/.margin/review.jsonl', 'w'):close()
vim.cmd.edit(repo .. '/f.txt')
local m = require 'margin'

-- simulate visual selection L2-L4 then M.comment() with stubbed input
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd 'normal! V2j'
local got
vim.ui.input = function(opts, cb) got = opts.prompt cb('range question') end
m.comment()
vim.wait(200, function() return false end) -- let vim.schedule run
assert(vim.fn.mode() == 'n', 'should be back in normal mode, got ' .. vim.fn.mode())
local cur = vim.api.nvim_win_get_cursor(0)
assert(cur[1] >= 2 and cur[1] <= 4, 'cursor jumped to line ' .. cur[1])
assert(got:match 'L2–4', 'prompt missing range hint: ' .. tostring(got))

local rec
for line in io.lines(repo .. '/.margin/review.jsonl') do rec = vim.json.decode(line) end
assert(rec.line == 2 and rec.endLine == 4, ('record range wrong: %s-%s'):format(rec.line, tostring(rec.endLine)))

-- render: anchored at endLine (row 3, 0-indexed), label shows [L2–4]
local ns = vim.api.nvim_create_namespace 'margin'
local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
assert(#marks == 1, 'expected 1 extmark, got ' .. #marks)
assert(marks[1][2] == 3, 'anchor row wrong: ' .. marks[1][2])
assert(vim.inspect(marks):match '%[L2–4%]', 'range label missing')

-- single-line comment unaffected
vim.ui.input = function(_, cb) cb('single') end
vim.api.nvim_win_set_cursor(0, { 6, 0 })
m.comment()
vim.wait(200, function() return false end)
local rec2
for line in io.lines(repo .. '/.margin/review.jsonl') do rec2 = vim.json.decode(line) end
assert(rec2.endLine == nil, 'single-line must have no endLine')
print 'RANGE_OK'
