---
name: margin-review
description: Answer review comments left in margin TUI. Use when user runs margin and wants AI replies to their diff comments.
---

# margin-review

The user is reviewing a diff in the `margin` TUI or in Neovim (margin.nvim) and
leaving comments. Your job: answer every pending comment FAST, then keep
watching for more.

## Protocol

All state lives in `<repo-root>/.margin/review.jsonl` (find repo root with
`git rev-parse --show-toplevel`). Append-only JSONL:

- `{"type":"comment","id":"c1","ts":...,"file":"src/foo.ts","line":42,"side":"new"|"old","excerpt":"the line text","text":"user question","status":"pending"}`
- `{"type":"reply","replyTo":"c1","ts":...,"text":"your answer"}` — add
  `"edit":true` when you changed code to satisfy the comment (see below).
- `{"type":"submit","ids":["c1","c2"],"ts":...,"diffArgs":[...],"cwd":"..."}` — user pressed S / `<leader>ms`; process now.
- `{"type":"review-request","ts":...,"files":["src/a.ts",...],"base":"HEAD","note":"optional"}` —
  appended by YOU (the AI) to ask the user to review files you changed; nvim's
  `:MarginReview` reads it. `files` are repo-root-relative; `base` is the git rev
  to diff against.

A comment is **pending** if no reply line references its id.

## Steps

1. Read `.margin/review.jsonl`. Collect pending comments (comments with no reply).
2. Read all pending comments in ONE pass, then answer them in order — but
   **append each reply IMMEDIATELY as it's composed**, one append per reply, the
   instant that answer is ready. Never hold replies to write together at the
   end — the TUI/nvim render replies one-by-one as they stream in.
3. **First-response priority:** on detecting a submit, answer the FIRST comment
   before anything else (no preamble work, no summarizing, no plan) — the user
   should see the first reply in roughly model-inference time.
4. For each comment:
   - Read the referenced file around `line` (side "new" = current file line number;
     side "old" = pre-change line, check the diff via `diffArgs` if needed).
   - Use `excerpt` to confirm you're looking at the right line.
   - Comments are natural language — decide what's being asked:
     - **Question** ("why is this…", "what does…") → answer in `text`.
     - **Change request** ("rename this", "extract this", "handle null here") →
       MAKE the code edit first, then append the reply with `"edit":true` and a
       short summary of what changed, e.g.
       `{"type":"reply","replyTo":"c1","ts":...,"text":"Renamed fn + updated 3 call sites","edit":true}`.
   - Keep replies short (1-3 sentences). No preamble.
5. Append one valid JSON object per line, **append with `>>`, never rewrite the
   file** (the TUI/nvim live-tail it):
   ```bash
   echo '{"type":"reply","replyTo":"c1","ts":1730000000000,"text":"answer here"}' >> .margin/review.jsonl
   ```
   Escape the JSON properly (prefer writing via a heredoc or `jq -n` if quotes get hairy).
6. Also print each answer in the terminal so the user sees it here too.
7. Then keep watching for further `submit` records — **event-driven, never
   sleep-polling**. Use the Monitor tool on the file if available; otherwise a
   background bash loop: `fswatch -1 .margin/review.jsonl` per iteration if
   `fswatch` exists, else `tail -n0 -f` filtered for submits:
   ```bash
   # background bash: block until the next submit lands, then re-check pending
   while :; do
     if command -v fswatch >/dev/null; then fswatch -1 .margin/review.jsonl >/dev/null
     else tail -n0 -f .margin/review.jsonl | grep -q '"type":"submit"'; fi
     echo "submit detected"   # -> re-read file, answer new pending comments
   done
   ```

## Requesting review of your own changes (nvim)

When you finish making code changes and the user wants to review them:

1. Append a `review-request` record listing **exactly the files you touched**
   (repo-root-relative) and the base rev your changes apply on top of:
   ```bash
   echo '{"type":"review-request","ts":1730000000000,"files":["src/a.ts","src/b.ts"],"base":"HEAD","note":"rename + null handling"}' >> .margin/review.jsonl
   ```
2. Open nvim for the user automatically when running inside herdr:
   ```bash
   # check we're in a herdr pane (prints JSON with pane_id if so)
   herdr pane current
   # open vertical split at the repo, capture new pane id from the JSON result
   herdr pane split --current --direction right --ratio 0.5 --cwd <repo-root>
   # run nvim straight into review mode in that pane
   herdr pane run <new_pane_id> 'nvim +MarginReview'
   ```
   Parse the new `pane_id` from the `herdr pane split` JSON output. If
   `herdr pane current` errors or herdr is not on PATH, fall back to telling the
   user to run `nvim +MarginReview` themselves.
3. Watch `.margin/review.jsonl` for a `submit` record (event-driven pattern
   above) and answer the comments as specified — replies render live in nvim.

## Rules

- Answer FAST — first reply lands before anything else; each subsequent reply is
  appended the moment it's ready.
- Replies render inline within ~50ms of append; keep them short (1-3 sentences).
- Never edit or truncate review.jsonl; append only.
- Don't modify the user's code unless a comment explicitly asks for a change —
  and when you do, mark the reply `"edit":true`.
