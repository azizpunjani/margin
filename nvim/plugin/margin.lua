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

vim.api.nvim_create_user_command('MarginClear', m 'clear', { desc = 'Hide margin threads in current buffer' })
vim.api.nvim_create_user_command('MarginShow', m 'show', { desc = 'Show margin threads in current buffer' })
vim.api.nvim_create_user_command('MarginReview', function(o)
  require('margin').review(o.args ~= '' and o.args or nil)
end, { nargs = '?', desc = 'Diff tabs for the latest review-request (or vs <base>)' })

vim.api.nvim_create_autocmd('BufEnter', {
  group = vim.api.nvim_create_augroup('margin', {}),
  desc = 'Margin: render threads + start review.jsonl watcher for this repo',
  callback = function(a) require('margin').attach(a.buf) end,
})
