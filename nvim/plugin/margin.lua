-- margin.nvim entry: keymaps, commands, autocmds. Logic lives in lua/margin.
if vim.g.loaded_margin then return end
vim.g.loaded_margin = 1

local function m(fn, ...)
  local args = { ... }
  return function() require('margin')[fn](unpack(args)) end
end

vim.keymap.set({ 'n', 'x' }, '<leader>mc', m 'comment', { desc = 'Margin: comment on line' })
vim.keymap.set('n', '<leader>ms', m 'submit', { desc = 'Margin: submit pending comments' })
vim.keymap.set('n', '<leader>mn', m('jump', 1), { desc = 'Margin: next thread' })
vim.keymap.set('n', '<leader>mp', m('jump', -1), { desc = 'Margin: prev thread' })
vim.keymap.set('n', '<leader>mq', m 'quickfix', { desc = 'Margin: threads to quickfix' })
vim.keymap.set('n', '<leader>mf', m 'files', { desc = 'Margin: pick review file' })
vim.keymap.set('n', '<leader>mr', m 'reply', { desc = 'Margin: reply to thread at/above cursor' })

vim.keymap.set('n', '<leader>mx', m 'resolve', { desc = 'Margin: resolve thread at/above cursor' })

vim.api.nvim_create_user_command('MarginFiles', m 'files', { desc = 'Pick a review file to jump to' })
vim.api.nvim_create_user_command('MarginReply', m 'reply', { desc = 'Reply to margin thread at/above cursor' })
vim.api.nvim_create_user_command('MarginResolve', m 'resolve', { desc = 'Resolve margin thread at/above cursor' })
vim.api.nvim_create_user_command('MarginResolveAll', m('resolve', true), { desc = 'Resolve all margin threads' })

vim.api.nvim_create_user_command('MarginClear', m 'clear', { desc = 'Hide margin threads in current buffer' })
vim.api.nvim_create_user_command('MarginShow', m 'show', { desc = 'Show margin threads in current buffer' })
vim.api.nvim_create_user_command('MarginReview', function(o)
  require('margin').review(o.args ~= '' and o.args or nil)
end, { nargs = '?', desc = 'Diff tabs for the latest review-request (or vs <base>)' })

local grp = vim.api.nvim_create_augroup('margin', {})

vim.api.nvim_create_autocmd('BufEnter', {
  group = grp,
  desc = 'Margin: render threads + start review.jsonl watcher for this repo',
  callback = function(a) require('margin').attach(a.buf) end,
})

vim.api.nvim_create_autocmd({ 'WinClosed', 'TabClosed' }, {
  group = grp,
  desc = 'Margin: stop watchers for repos no window shows anymore',
  callback = function() vim.schedule(function() require('margin').gc() end) end,
})

vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
  group = grp,
  desc = 'Margin: re-wrap thread text to new window width',
  callback = function() require('margin').attach(vim.api.nvim_get_current_buf()) end,
})

-- Presence: write .margin/presence.json when the cursor DWELLS ~2s at a spot —
-- reading, not scrolling — so the AI primes on code you're actually looking at.
-- Each CursorMoved resets the timer; the write itself is throttled in M.presence.
local ptimer = vim.uv.new_timer()
vim.api.nvim_create_autocmd('CursorMoved', {
  group = grp,
  desc = 'Margin: dwell-debounced presence write',
  callback = function()
    ptimer:start(2000, 0, vim.schedule_wrap(function() require('margin').presence() end))
  end,
})
if vim.o.updatetime <= 2000 then -- CursorHold only helps if it fires sooner than the dwell timer
  vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
    group = grp,
    desc = 'Margin: presence write on cursor hold',
    callback = function() require('margin').presence() end,
  })
end
