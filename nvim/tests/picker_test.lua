-- MarginFiles picker: labels with counts, open-or-jump behavior.
local repo = os.getenv 'REPO'
vim.opt.rtp:prepend(os.getenv 'PLUGIN')
vim.fn.mkdir(repo .. '/.margin', 'p')
local f = assert(io.open(repo .. '/.margin/review.jsonl', 'w'))
f:write '{"type":"review-request","ts":1,"files":["a.txt","b.txt"],"base":"HEAD"}\n'
f:write '{"type":"comment","id":"c1","ts":2,"file":"a.txt","line":1,"side":"new","excerpt":"line1","text":"hm","status":"pending"}\n'
f:close()

vim.cmd.edit(repo .. '/a.txt')
local m = require 'margin'
local got
vim.ui.select = function(items, _, cb)
  got = items
  cb(items[2], 2) -- pick b.txt (not open anywhere -> opens review tab)
end
m.files()
assert(got and got[1]:match 'a%.txt  💬 1 ⏳' and got[2] == 'b.txt', 'labels wrong: ' .. vim.inspect(got))
assert(vim.wo.diff and vim.api.nvim_buf_get_name(0):match 'b%.txt$', 'should open b.txt in diff mode')
assert(vim.wo.winhighlight:match 'DiffAdd:MarginDiffAdd', 'diff winhl missing: ' .. vim.wo.winhighlight)

local tabs = #vim.api.nvim_list_tabpages()
vim.ui.select = function(items, _, cb) cb(items[1], 1) end -- a.txt already open -> jump
m.files()
assert(#vim.api.nvim_list_tabpages() == tabs, 'should jump, not open a new tab')
assert(vim.api.nvim_buf_get_name(0):match 'a%.txt$', 'did not jump to a.txt')
print 'PICKER_OK'
