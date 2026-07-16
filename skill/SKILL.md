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

- `{"type":"comment","id":"c1","ts":...,"file":"src/foo.ts","line":42,"side":"new"|"old","excerpt":"the line text","text":"user question","status":"pending"}` — may
  carry `"endLine":N` (visual-range comment): read and reason about the WHOLE
  `line..endLine` span, not just `line`.
- `{"type":"reply","replyTo":"c1","ts":...,"text":"your answer"}` — add
  `"edit":true` when you changed code to satisfy the comment (see below).
- `{"type":"reply-chunk","replyTo":"c1","ts":...,"text":"partial..."}` — streamed
  fragment of an in-progress reply; frontends concatenate chunks and show a
  typing cursor until the final `reply` record for that id supersedes them.
- `{"type":"user-reply","replyTo":"c1","ts":...,"text":"follow-up"}` — the USER
  continuing a thread (nvim `<leader>mr`); it reopens the thread: answer it like
  a comment, using the full thread history (comment + prior replies) as context.
- `{"type":"submit","ids":["c1","c2"],"ts":...,"diffArgs":[...],"cwd":"..."}` — user pressed S / `<leader>ms`; process now.
- `{"type":"review-request","ts":...,"files":["src/a.ts",...],"base":"HEAD","note":"optional"}` —
  appended by YOU (the AI) to ask the user to review files you changed; nvim's
  `:MarginReview` reads it. `files` are repo-root-relative; `base` is the git rev
  to diff against.

A thread is **pending** if it has no `reply` at all, OR its latest message
(by ts, among `reply`/`user-reply`) is a `user-reply`.

There is also an ephemeral sidecar file `.margin/presence.json` (a single JSON
object, overwritten in place — NOT part of the jsonl):
`{"file":"src/foo.ts","line":42,"ts":...}` — where the user's cursor is
dwelling in nvim right now. Use it for priming (below); never reply to it.

## Steps

1. Read `.margin/review.jsonl`. Collect pending threads (no reply yet, or the
   user posted a `user-reply` after your last reply — answer those with the full
   thread history as context).
2. Read all pending comments in ONE pass, then answer them in order — but
   **append each reply IMMEDIATELY as it's composed**, one append per reply, the
   instant that answer is ready. Never hold replies to write together at the
   end — the TUI/nvim render replies one-by-one as they stream in.
3. **First-response priority:** on detecting a submit, your VERY FIRST tool call
   must append an ack chunk for the first pending comment — before reading any
   files — so the user sees life within a second of your wake-up:
   ```bash
   echo '{"type":"reply-chunk","replyTo":"c3","ts":...,"text":"reading gmail.ts:32… "}' >> .margin/review.jsonl
   ```
   (Combine it with the `cat` of review.jsonl in one bash call if you already
   know the pending id from the watcher output.) Then compose the real answer
   and append the final `reply` record — it replaces the chunk display. For
   long multi-part answers, append additional reply-chunk fragments as you go.
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
7. Then keep watching with a background bash task (run_in_background) that
   EXITS when a new COMMENT **or** SUBMIT lands — its completion notification
   wakes you. Use this exact pattern (fast poll on record counts):
   ```bash
   # background bash: exits (-> wakes Claude) on any new comment or submit
   F=<repo-root>/.margin/review.jsonl
   N=$(grep -c '"type":"\(comment\|user-reply\|submit\)"' "$F")
   while :; do
     C=$(grep -c '"type":"\(comment\|user-reply\|submit\)"' "$F" 2>/dev/null || echo 0)
     [ "$C" -gt "$N" ] && { echo "WAKE ($C records)"; exit 0; }
     sleep 0.2
   done
   ```
   **Priming:** when the wake is a comment WITHOUT a submit yet, do NOT reply.
   Instead read the referenced file around the commented line, work out your
   answer, and state the draft in your own turn text (it stays in conversation
   context). Then re-arm the watcher. When the submit wake arrives, append the
   pre-drafted replies immediately — near-zero thinking time.
   Restart the watcher after every wake. Do NOT use `tail -f | grep -q ...` —
   grep exits on match but the shell keeps waiting on the immortal `tail`, so
   the task never completes and you never wake (verified failure). `fswatch -1`
   in a loop is fine IF fswatch is installed (it isn't by default here).

## Presence priming (gaze-based)

nvim overwrites `.margin/presence.json` whenever the user's cursor dwells ~2s
somewhere in the repo — i.e. code they are actually READING, before any comment
exists. Run a SECOND, slower background watcher on it:

```bash
# background bash: exits (-> wakes Claude) when the user's gaze moves
P=<repo-root>/.margin/presence.json
LAST="$(cat "$P" 2>/dev/null)"
while :; do
  CUR="$(cat "$P" 2>/dev/null)"
  [ -n "$CUR" ] && [ "$CUR" != "$LAST" ] && { echo "PRESENCE $CUR"; exit 0; }
  sleep 1
done
```

On a presence wake: if it's a new file, or the line jumped >30 from the location
you last primed on, pre-read ~60 lines around `file:line` and state a brief
draft context in your own turn text (what this code does, likely questions) so
it's already in conversation context when a real comment arrives. Then re-arm
both watchers. **NEVER append a reply (or any record) from a presence wake** —
presence is not a question.

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
