-- E325 guard: a stale/competing swapfile must not abort :MarginReview.
local repo = os.getenv 'REPO'
vim.opt.rtp:prepend(os.getenv 'PLUGIN')

-- Hold a.txt open in a second nvim sharing the same (--clean) swap dir.
local job = vim.fn.jobstart {
  'nvim', '--clean', '--headless', repo .. '/a.txt', '-c', 'sleep 30',
}
assert(job > 0, 'could not start competing nvim')
vim.wait(2000, function() -- wait until its swapfile actually exists
  return #vim.fn.glob(vim.fn.stdpath 'state' .. '/swap/*a.txt*', true, true) > 0
end, 50)

vim.cmd.cd(repo) -- review() resolves the repo from cwd when no repo buffer is open
local ok, err = pcall(require('margin').review, 'HEAD')
vim.fn.jobstop(job)
assert(ok, 'MarginReview aborted on swapfile: ' .. tostring(err))
local found = false
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(buf):match 'a%.txt$' and vim.bo[buf].buftype == '' then found = true end
end
assert(found, 'a.txt did not open despite swapfile')
print 'SWAP_OK'
