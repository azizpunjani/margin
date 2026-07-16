-- Files new at base render plain (winbar tag, no diff); modified files diff.
local repo = os.getenv 'REPO'
vim.opt.rtp:prepend(os.getenv 'PLUGIN')
vim.fn.writefile({ 'brand new' }, repo .. '/newfile.txt') -- untracked = new at base
vim.cmd.edit(repo .. '/a.txt')
local m = require 'margin'

m.review 'HEAD' -- only a.txt is modified vs HEAD
assert(vim.wo.diff, 'modified file should be in diff mode')
assert(vim.wo.winhighlight:match 'DiffText:MarginDiffText', 'diff winhl missing')

vim.fn.mkdir(repo .. '/.margin', 'p')
local f = assert(io.open(repo .. '/.margin/review.jsonl', 'a'))
f:write '{"type":"review-request","ts":9,"files":["newfile.txt"],"base":"HEAD"}\n'
f:close()
vim.ui.select = function(items, _, cb) cb(items[1], 1) end
m.files()
assert(not vim.wo.diff, 'new file must NOT diff (all-green wash)')
assert(vim.wo.winbar:match 'NEW FILE', 'winbar tag missing: ' .. vim.wo.winbar)
assert(#vim.api.nvim_tabpage_list_wins(0) == 1, 'new file should be a single window')
print 'NEWFILE_OK'
