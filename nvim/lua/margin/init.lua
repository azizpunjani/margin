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

-- High-contrast diff colors on near-black backgrounds (user-picked); applied
-- window-locally in review tabs only (global colorscheme untouched).
vim.api.nvim_set_hl(0, 'MarginDiffAdd', { default = true, bg = '#0f3a1f' })
vim.api.nvim_set_hl(0, 'MarginDiffDelete', { default = true, bg = '#46141c', fg = '#7d3a3f' })
vim.api.nvim_set_hl(0, 'MarginDiffChange', { default = true, bg = '#0e1a2e' })
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
        local t = { comment = rec, replies = {}, chunks = {} }
        byid[rec.id] = t
        threads[#threads + 1] = t
      elseif (rec.type == 'reply' or rec.type == 'user-reply') and byid[rec.replyTo] then
        table.insert(byid[rec.replyTo].replies, rec) -- file order == ts order (append-only)
        if rec.type == 'reply' then byid[rec.replyTo].chunks = {} end -- final reply supersedes chunks
      elseif rec.type == 'reply-chunk' and byid[rec.replyTo] then
        table.insert(byid[rec.replyTo].chunks, rec.text)
      elseif rec.type == 'resolve' then
        for _, id in ipairs(rec.ids or {}) do
          if byid[id] then byid[id].resolved = true end
        end
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

-- Pending = needs an AI answer: no reply at all, or the latest thread message
-- (chronologically last, i.e. last in file order) is a user-reply.
-- AI-authored observations (author == "ai") are never pending on their own —
-- only a user-reply reopens them.
local function is_pending(t)
  if t.resolved then return false end
  local last = t.replies[#t.replies]
  if t.comment.author == 'ai' then return last ~= nil and last.type ~= 'reply' end
  return not last or last.type ~= 'reply'
end

-- Word-wrap text to `width` display cells (words longer than width stay whole).
local function wrap(s, width)
  local out = {}
  for _, raw in ipairs(vim.split(s, '\n')) do
    local cur = ''
    for word in raw:gmatch '%S+' do
      if cur == '' then
        cur = word
      elseif vim.fn.strdisplaywidth(cur .. ' ' .. word) <= width then
        cur = cur .. ' ' .. word
      else
        out[#out + 1] = cur
        cur = word
      end
    end
    out[#out + 1] = cur -- '' keeps intentional blank lines
  end
  return out
end

local function virt_block(t, width)
  width = math.max((width or 100) - 6, 20) -- 6 ≈ '┃ 💬 ' prefix cells; never wrap absurdly narrow
  local streaming = #t.chunks > 0 -- chunks are cleared by each final reply
  local vl, pending = {}, is_pending(t) and not streaming
  local function emit(prefix, text, hl, tail)
    local lines = wrap(text, width)
    for i, l in ipairs(lines) do
      vl[#vl + 1] = { { (i == 1 and prefix or '┃    ') .. l .. (i == #lines and tail or ''), hl } }
    end
  end
  local cprefix = t.comment.author == 'ai' and '┃ 💡 ' or '┃ 💬 ' -- 💡 = AI observation
  local range = t.comment.endLine and ('[L%d–%d] '):format(t.comment.line, t.comment.endLine) or ''
  emit(cprefix, range .. t.comment.text, 'MarginComment', pending and ' ⏳' or '')
  for _, r in ipairs(t.replies) do -- interleaved AI/user messages, ts order
    local prefix, hl = r.edit and '┃ ✏️ ' or '┃ 🤖 ', 'MarginReply'
    if r.type == 'user-reply' then prefix, hl = '┃ 👤 ', 'MarginComment' end
    emit(prefix, r.text, hl, '')
  end
  if streaming then -- in-progress reply streamed as reply-chunk records
    emit('┃ 🤖 ', table.concat(t.chunks, ''), 'MarginReply', ' ▌')
  end
  return vl
end

-- Usable text width of the (first) window showing buf, for wrapping virt_lines.
local function buf_text_width(buf)
  local win = vim.fn.win_findbuf(buf)[1]
  local wi = win and vim.fn.getwininfo(win)[1]
  return wi and (wi.width - wi.textoff) or nil
end

local function render_buf(buf, root, threads)
  if hidden[buf] or not vim.api.nvim_buf_is_loaded(buf) then return end
  local rel = vim.api.nvim_buf_get_name(buf):sub(#root + 2)
  local width = buf_text_width(buf)
  local last = vim.api.nvim_buf_line_count(buf) - 1
  for _, t in ipairs(threads) do
    if t.comment.file == rel then
      local key = buf .. ':' .. t.comment.id
      local id = markids[key]
      if t.resolved then
        if id then
          vim.api.nvim_buf_del_extmark(buf, ns, id)
          markids[key] = nil
        end
      else
        local pos = id and vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, {})
        local anchor = t.comment.endLine or t.comment.line -- range comments hang under the range
        local row = (pos and pos[1]) or math.min(math.max(anchor - 1, 0), last)
        markids[key] = vim.api.nvim_buf_set_extmark(buf, ns, math.min(row, last), 0, { id = id, virt_lines = virt_block(t, width) })
      end
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

local function teardown(root)
  local st = repos[root]
  if not st then return end
  if st.watcher then st.watcher:stop() st.watcher:close() end
  if st.timer then st.timer:stop() st.timer:close() end
  repos[root] = nil
end

-- Stop watchers for repos no window shows anymore (tab/window closed);
-- BufEnter re-arms via attach if the user comes back.
function M.gc()
  for root in pairs(repos) do
    local visible = false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if root_of(vim.api.nvim_win_get_buf(win)) == root then
        visible = true
        break
      end
    end
    if not visible then teardown(root) end
  end
end

function M.watching(root)
  return repos[root] ~= nil
end

-- BufEnter: pick up existing reviews lazily (multi-repo safe: keyed by root).
function M.attach(buf)
  local root = root_of(buf)
  if not root or not uv.fs_stat(review_path(root)) then return end
  ensure_watch(root)
  render_buf(buf, root, read_records(root))
end

-- Internal, testable core: append a comment record for buf:line (optionally
-- spanning to end_line for visual-range comments).
function M.add_comment(text, buf, line, end_line)
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
    endLine = end_line, -- nil for single-line comments (key omitted in JSON)
    text = text,
    status = 'pending',
  }
  append(root, rec)
  ensure_watch(root)
  hidden[buf] = nil
  render_buf(buf, root, read_records(root)) -- places the tracking extmark now
  return rec
end

-- Internal, testable core: append a user-reply continuing thread `id`.
function M.add_user_reply(text, id, root)
  root = root or repo_root()
  if not root then return end
  local rec = { type = 'user-reply', replyTo = id, ts = os.time() * 1000, text = text }
  append(root, rec)
  M.render(root)
  return rec
end

-- <leader>mr: reply within the thread anchored at/nearest-above the cursor.
-- Unresolved thread anchored at/nearest-above the cursor; returns id, root.
local function thread_at_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local root = root_of(buf)
  if not root then return nil end
  local rel = vim.api.nvim_buf_get_name(buf):sub(#root + 2)
  local cur = vim.api.nvim_win_get_cursor(0)[1] - 1
  local best_id, best_row
  for _, t in ipairs(read_records(root)) do
    if t.comment.file == rel and not t.resolved then
      local id = markids[buf .. ':' .. t.comment.id]
      local pos = id and vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, {})
      local span = (t.comment.endLine or t.comment.line) - t.comment.line
      local anchor = (pos and pos[1]) or (t.comment.line - 1 + span)
      local start = anchor - span -- range threads anchor at endLine; match from their first line
      if start <= cur and (not best_row or start > best_row) then best_id, best_row = t.comment.id, start end
    end
  end
  return best_id, root
end

function M.reply()
  local best_id, root = thread_at_cursor()
  if not root then return vim.notify('margin: buffer not in a git repo', vim.log.levels.WARN) end
  if not best_id then return vim.notify 'margin: no thread at or above cursor' end
  vim.ui.input({ prompt = 'Margin reply (' .. best_id .. '): ' }, function(text)
    if text and text ~= '' then M.add_user_reply(text, best_id, root) end
  end)
end

-- Resolve = archive: appends a resolve record; rendering and pending skip
-- resolved threads (append-only file preserved, so nothing is lost).
function M.resolve(all)
  local root = repo_root()
  if not root then return vim.notify('margin: no git repo', vim.log.levels.WARN) end
  local ids
  if all then
    ids = {}
    for _, t in ipairs(read_records(root)) do
      if not t.resolved then ids[#ids + 1] = t.comment.id end
    end
  else
    local id = thread_at_cursor()
    if not id then return vim.notify 'margin: no thread at or above cursor' end
    ids = { id }
  end
  if #ids == 0 then return vim.notify 'margin: nothing to resolve' end
  append(root, { type = 'resolve', ids = ids, ts = os.time() * 1000 })
  M.render(root)
  vim.notify(('margin: resolved %d thread%s'):format(#ids, #ids == 1 and '' or 's'))
end

-- Presence: overwrite .margin/presence.json with where the user is looking so
-- the AI can pre-read that code. Only for repos with an active review file;
-- throttled (same file + <10 line move = skip). Returns true when written.
local last_presence = {}
function M.presence(buf, line)
  buf = buf or vim.api.nvim_get_current_buf()
  local root = root_of(buf)
  if not root or not uv.fs_stat(review_path(root)) then return end
  line = line or vim.api.nvim_win_get_cursor(0)[1]
  local file = vim.api.nvim_buf_get_name(buf):sub(#root + 2)
  local lp = last_presence
  if lp.root == root and lp.file == file and math.abs(line - lp.line) < 10 then return end
  last_presence = { root = root, file = file, line = line }
  local f = assert(io.open(root .. '/.margin/presence.json', 'w'))
  f:write(vim.json.encode { file = file, line = line, ts = os.time() * 1000 })
  f:close()
  return true
end

function M.comment()
  local buf, line, end_line = vim.api.nvim_get_current_buf(), vim.fn.line '.', nil
  if vim.fn.mode():match '^[vV\22]' then
    local vline = vim.fn.line 'v'
    line, end_line = math.min(line, vline), math.max(line, vline)
    if end_line == line then end_line = nil end
    vim.cmd 'normal! \27' -- leave visual synchronously: no stray keys, no cursor jump
  end
  vim.schedule(function() -- input opens after mode change settles
    local hint = end_line and (' (L%d–%d)'):format(line, end_line) or ''
    vim.ui.input({ prompt = 'Margin comment' .. hint .. ': ' }, function(text)
      if text and text ~= '' then M.add_comment(text, buf, line, end_line) end
    end)
  end)
end

function M.submit()
  local root = repo_root()
  if not root then return vim.notify('margin: no git repo', vim.log.levels.WARN) end
  local ids = {}
  for _, t in ipairs(read_records(root)) do
    if is_pending(t) then ids[#ids + 1] = t.comment.id end
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
  -- Stale swapfiles (nvim killed mid-review) otherwise abort the whole
  -- :MarginReview loop with E325; open anyway and say so.
  local au = vim.api.nvim_create_autocmd('SwapExists', {
    once = true,
    callback = function()
      vim.v.swapchoice = 'e'
      vim.schedule(function()
        vim.notify('margin: swapfile existed for ' .. file .. ' — opened anyway', vim.log.levels.WARN)
      end)
    end,
  })
  local ok, err = pcall(vim.cmd.tabedit, vim.fn.fnameescape(root .. '/' .. file))
  pcall(vim.api.nvim_del_autocmd, au)
  if not ok then
    return vim.notify('margin: could not open ' .. file .. ': ' .. err, vim.log.levels.ERROR)
  end
  local old = vim.fn.systemlist { 'git', '-C', root, 'show', base .. ':' .. file }
  if vim.v.shell_error ~= 0 or #old == 0 then
    -- New at base: a diff would paint every line DiffAdd (unreadable, zero
    -- signal). Show the file plain with a winbar tag instead.
    vim.wo.winbar = '%#DiffAdd# ● NEW FILE %*' .. ' ' .. file
    return
  end
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
    c.total, c.pending = c.total + 1, c.pending + (is_pending(t) and 1 or 0)
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
