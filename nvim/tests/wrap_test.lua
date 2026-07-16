-- Long comment/reply text wraps to window width; continuation lines carry the
-- '┃    ' gutter; narrow windows never wrap below the floor.
local repo = os.getenv 'REPO'
vim.opt.rtp:prepend(os.getenv 'PLUGIN')
local nsid = vim.api.nvim_create_namespace 'margin'
local function append(s)
  local f = assert(io.open(repo .. '/.margin/review.jsonl', 'a'))
  f:write(s .. '\n')
  f:close()
end
local function virt_lines()
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, nsid, 0, -1, { details = true })) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      out[#out + 1] = vl[1][1]
    end
  end
  return out
end

vim.fn.mkdir(repo .. '/.margin', 'p')
local long = string.rep('word ', 40):gsub(' $', '') -- 199 cells, must wrap
append('{"type":"comment","id":"c1","ts":1,"file":"a.txt","line":1,"side":"new","excerpt":"line1","text":"' .. long .. '","status":"pending"}')
append('{"type":"reply","replyTo":"c1","ts":2,"text":"' .. long .. '"}')

vim.cmd.edit(repo .. '/a.txt')
vim.api.nvim_win_set_width(0, 60)
require('margin').attach(vim.api.nvim_get_current_buf())

local lines = virt_lines()
assert(#lines > 4, 'long comment + reply should wrap into several lines, got ' .. #lines)
local width = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
width = width.width - width.textoff
local seen_cont = false
for _, l in ipairs(lines) do
  assert(vim.fn.strdisplaywidth(l) <= width, 'line exceeds window width: ' .. l)
  if l:match '^┃    word' then seen_cont = true end
end
assert(seen_cont, 'continuation lines missing gutter prefix')
assert(lines[1]:match '^┃ 💬 word', 'first comment line lost its prefix')

-- streaming chunk wraps too, ▌ on the last line only
append('{"type":"user-reply","replyTo":"c1","ts":3,"text":"more?"}')
append('{"type":"reply-chunk","replyTo":"c1","ts":4,"text":"' .. long .. '"}')
require('margin').render(vim.fs.root(0, '.git'))
lines = virt_lines()
local cursors = 0
for _, l in ipairs(lines) do
  if l:match '▌' then cursors = cursors + 1 end
end
assert(cursors == 1 and lines[#lines]:match '▌$', 'streaming cursor must sit on the final wrapped line')
print 'WRAP_OK'
