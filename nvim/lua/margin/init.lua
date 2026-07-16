-- margin.nvim: leave review comments on normal buffers; AI replies render live
-- as virt_lines. Shares the append-only JSONL protocol at
-- <repo>/.margin/review.jsonl with the margin TUI and the margin-review skill.
local M = {}

local uv = vim.uv
local ns = vim.api.nvim_create_namespace 'margin'
local repos = {} -- repo root -> { watcher = uv_fs_event, timer = uv_timer }
local hidden = {} -- bufnr -> true while :MarginClear'd
local markids = {} -- "<buf>:<comment id>" -> extmark id

vim.api.nvim_set_hl(0, 'MarginComment', { default = true, link = 'DiagnosticVirtualTextWarn' })
vim.api.nvim_set_hl(0, 'MarginReply', { default = true, fg = '#c678dd', italic = true })

-- GitHub-dark-style diff colors on near-black backgrounds; applied
-- window-locally in review tabs only (global colorscheme untouched).
vim.api.nvim_set_hl(0, 'MarginDiffAdd', { default = true, bg = '#12331d' })
vim.api.nvim_set_hl(0, 'MarginDiffDelete', { default = true, bg = '#2d1215', fg = '#6e3b40' })
vim.api.nvim_set_hl(0, 'MarginDiffChange', { default = true, bg = '#131f2e' })
vim.api.nvim_set_hl(0, 'MarginDiffText', { default = true, bg = '#1f4468', bold = true })

local DIFF_WINHL = 'DiffAdd:MarginDiffAdd,DiffDelete:MarginDiffDelete,DiffChange:MarginDiffChange,DiffText:MarginDiffText'

local function root_of(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or vim.bo[buf].buftype ~= '' then return nil end
  return vim.fs.root(buf, '.git')
end

local function repo_root()
  return root_of(vim.api.nvim_get_current_buf()) or vim.fs.root(uv.cwd(), '.git')
end

local function review_path(root)
  return root .. '/.margin/review.jsonl'
end

-- Parse the whole JSONL file. Returns ordered thread list and the latest
-- review-request record (or nil).
local function read_records(root)
  local threads, byid, request = {}, {}, nil
  local f = io.open(review_path(root), 'r')
  if not f then return threads, nil end
  for line in f:lines() do
    local ok, rec = pcall(vim.json.decode, line)
    if ok and type(rec) == 'table' then
      if rec.type == 'comment' then
        local t = { comment = rec, replies = {} }
        byid[rec.id] = t
        threads[#threads + 1] = t
      elseif rec.type == 'reply' and byid[rec.replyTo] then
        table.insert(byid[rec.replyTo].replies, rec)
      elseif rec.type == 'review-request' then
        request = rec
      end
    end
  end
  f:close()
  return threads, request
end

local function next_id(threads)
  local max = 0
  for _, t in ipairs(threads) do
    local n = tonumber(t.comment.id:match '^c(%d+)$')
    if n and n > max then max = n end
  end
  return 'c' .. (max + 1)
end

local function append(root, rec)
  vim.fn.mkdir(root .. '/.margin', 'p')
  local f = assert(io.open(review_path(root), 'a'))
  f:write(vim.json.encode(rec) .. '\n')
  f:close()
end

local function virt_block(t)
  local vl, pending = {}, #t.replies == 0
  for i, l in ipairs(vim.split(t.comment.text, '\n')) do
    vl[#vl + 1] = { { '┃ 💬 ' .. l .. (pending and i == 1 and ' ⏳' or ''), 'MarginComment' } }
  end
  for _, r in ipairs(t.replies) do
    local prefix = r.edit and '┃ ✏️ ' or '┃ 🤖 ' -- edit:true = AI changed code
    for _, l in ipairs(vim.split(r.text, '\n')) do
      vl[#vl + 1] = { { prefix .. l, 'MarginReply' } }
    end
  end
  return vl
end

local function render_buf(buf, root, threads)
  if hidden[buf] or not vim.api.nvim_buf_is_loaded(buf) then return end
  local rel = vim.api.nvim_buf_get_name(buf):sub(#root + 2)
  local last = vim.api.nvim_buf_line_count(buf) - 1
  for _, t in ipairs(threads) do
    if t.comment.file == rel then
      local key = buf .. ':' .. t.comment.id
      local id = markids[key]
      local pos = id and vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, {})
      local row = (pos and pos[1]) or math.min(math.max(t.comment.line - 1, 0), last)
      markids[key] = vim.api.nvim_buf_set_extmark(buf, ns, math.min(row, last), 0, { id = id, virt_lines = virt_block(t) })
    end
  end
end

-- Re-render every loaded buffer belonging to this repo root.
function M.render(root)
  local threads = read_records(root)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if root_of(buf) == root then render_buf(buf, root, threads) end
  end
end

local function ensure_watch(root)
  local st = repos[root] or {}
  repos[root] = st
  if st.watcher or not uv.fs_stat(review_path(root)) then return end
  st.timer = uv.new_timer()
  st.watcher = uv.new_fs_event()
  st.watcher:start(review_path(root), {}, function()
    -- debounce ~80ms, then reparse + re-render on the main loop
    st.timer:start(80, 0, vim.schedule_wrap(function()
      vim.cmd 'silent! checktime' -- pick up AI edits to files on disk (autoread)
      M.render(root)
    end))
  end)
end

-- BufEnter: pick up existing reviews lazily (multi-repo safe: keyed by root).
function M.attach(buf)
  local root = root_of(buf)
  if not root or not uv.fs_stat(review_path(root)) then return end
  ensure_watch(root)
  render_buf(buf, root, read_records(root))
end

-- Internal, testable core: append a comment record for buf:line.
function M.add_comment(text, buf, line)
  buf = buf or vim.api.nvim_get_current_buf()
  local root = root_of(buf)
  if not root then return vim.notify('margin: buffer not in a git repo', vim.log.levels.WARN) end
  line = line or vim.api.nvim_win_get_cursor(0)[1]
  local rec = {
    type = 'comment',
    id = next_id(read_records(root)),
    ts = os.time() * 1000,
    file = vim.api.nvim_buf_get_name(buf):sub(#root + 2),
    line = line,
    side = 'new',
    excerpt = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or '',
    text = text,
    status = 'pending',
  }
  append(root, rec)
  ensure_watch(root)
  hidden[buf] = nil
  render_buf(buf, root, read_records(root)) -- places the tracking extmark now
  return rec
end

function M.comment()
  local buf, line = vim.api.nvim_get_current_buf(), vim.fn.line '.'
  if vim.fn.mode():match '^[vV\22]' then
    line = math.min(line, vim.fn.line 'v')
    vim.api.nvim_feedkeys(vim.keycode '<Esc>', 'n', false)
  end
  vim.ui.input({ prompt = 'Margin comment: ' }, function(text)
    if text and text ~= '' then M.add_comment(text, buf, line) end
  end)
end

function M.submit()
  local root = repo_root()
  if not root then return vim.notify('margin: no git repo', vim.log.levels.WARN) end
  local ids = {}
  for _, t in ipairs(read_records(root)) do
    if #t.replies == 0 then ids[#ids + 1] = t.comment.id end
  end
  if #ids == 0 then return vim.notify 'margin: no pending comments' end
  append(root, { type = 'submit', ids = ids, ts = os.time() * 1000, diffArgs = {}, cwd = root })
  vim.notify(('margin: submitted %d comment%s'):format(#ids, #ids == 1 and '' or 's'))
end

-- Jump to next (dir=1) / prev (dir=-1) thread line in the current buffer.
function M.jump(dir)
  local rows = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})) do
    rows[#rows + 1] = m[2] + 1
  end
  table.sort(rows)
  if #rows == 0 then return vim.notify 'margin: no threads in buffer' end
  local cur, target = vim.api.nvim_win_get_cursor(0)[1], nil
  if dir > 0 then
    for _, r in ipairs(rows) do
      if r > cur then target = r break end
    end
  else
    for i = #rows, 1, -1 do
      if rows[i] < cur then target = rows[i] break end
    end
  end
  vim.api.nvim_win_set_cursor(0, { target or rows[dir > 0 and 1 or #rows], 0 }) -- wraps
end

function M.quickfix()
  local root = repo_root()
  if not root then return end
  local items = {}
  for _, t in ipairs(read_records(root)) do
    items[#items + 1] = { filename = root .. '/' .. t.comment.file, lnum = t.comment.line, text = t.comment.text:sub(1, 60) }
  end
  vim.fn.setqflist({}, ' ', { title = 'margin threads', items = items })
  vim.cmd.copen()
end

function M.clear(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  hidden[buf] = true
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

function M.show(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  hidden[buf] = nil
  local root = root_of(buf)
  if root then render_buf(buf, root, read_records(root)) end
end

local function open_review_tab(root, file, base)
  vim.cmd.tabedit(vim.fn.fnameescape(root .. '/' .. file))
  local old = vim.fn.systemlist { 'git', '-C', root, 'show', base .. ':' .. file }
  if vim.v.shell_error ~= 0 then old = {} end -- file new at base
  vim.cmd 'leftabove vertical new'
  local lbuf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(lbuf, 0, -1, false, old)
  vim.api.nvim_buf_set_name(lbuf, 'margin://' .. base .. ':' .. file)
  vim.bo[lbuf].buftype, vim.bo[lbuf].bufhidden, vim.bo[lbuf].swapfile = 'nofile', 'wipe', false
  vim.bo[lbuf].modifiable, vim.bo[lbuf].readonly = false, true
  vim.bo[lbuf].filetype = vim.filetype.match { filename = file } or ''
  vim.cmd.diffthis()
  vim.wo.winhighlight = DIFF_WINHL
  vim.cmd.wincmd 'p' -- back to the real file, where comments go
  vim.cmd.diffthis()
  vim.wo.winhighlight = DIFF_WINHL
end

-- :MarginFiles — pick a review file (comment counts inline), jump to its tab
-- or open it. Scales past what gt/gT can handle.
function M.files()
  local root = repo_root()
  if not root then return vim.notify('margin: no git repo', vim.log.levels.WARN) end
  local threads, req = read_records(root)
  if not req or not req.files or #req.files == 0 then
    return vim.notify('margin: no review-request record', vim.log.levels.WARN)
  end
  local counts = {}
  for _, t in ipairs(threads) do
    local c = counts[t.comment.file] or { total = 0, pending = 0 }
    c.total, c.pending = c.total + 1, c.pending + (#t.replies == 0 and 1 or 0)
    counts[t.comment.file] = c
  end
  local labels = {}
  for i, f in ipairs(req.files) do
    local c = counts[f]
    labels[i] = f .. (c and ('  💬 ' .. c.total .. (c.pending > 0 and ' ⏳' or '')) or '')
  end
  vim.ui.select(labels, { prompt = 'Margin files' }, function(_, idx)
    if not idx then return end
    local path = root .. '/' .. req.files[idx]
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == path then
          vim.api.nvim_set_current_tabpage(tab)
          vim.api.nvim_set_current_win(win)
          return
        end
      end
    end
    open_review_tab(root, req.files[idx], req.base or 'HEAD')
  end)
end

-- :MarginReview [base] — one tab per file: git-show base on the left (readonly
-- scratch), the real working file on the right; both in diff mode. Comment on
-- the right buffer as usual. Switch files with gt/gT or the <leader>mf picker.
function M.review(base)
  local root = repo_root()
  if not root then return vim.notify('margin: no git repo', vim.log.levels.WARN) end
  local _, req = read_records(root)
  local files
  if base then
    files = vim.fn.systemlist { 'git', '-C', root, 'diff', '--name-only', base }
    if vim.v.shell_error ~= 0 then return vim.notify('margin: git diff failed: ' .. table.concat(files, ' '), vim.log.levels.ERROR) end
  elseif req then
    files, base = req.files, req.base or 'HEAD'
  else
    return vim.notify('margin: no review-request record; use :MarginReview <base>', vim.log.levels.WARN)
  end
  if not files or #files == 0 then return vim.notify 'margin: nothing to review' end
  for _, file in ipairs(files) do
    open_review_tab(root, file, base)
  end
  vim.notify(('margin: reviewing %d file(s) vs %s — gt/gT or <leader>mf to switch'):format(#files, base))
end

return M
