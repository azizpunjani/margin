---
name: margin-review
description: Answer review comments left in margin TUI. Use when user runs margin and wants AI replies to their diff comments.
---

# margin-review

The user is reviewing a diff in the `margin` TUI and leaving comments. Your job:
answer every pending comment FAST, then keep watching for more.

## Protocol

All state lives in `<repo-root>/.margin/review.jsonl` (find repo root with
`git rev-parse --show-toplevel`). Append-only JSONL:

- `{"type":"comment","id":"c1","ts":...,"file":"src/foo.ts","line":42,"side":"new"|"old","excerpt":"the line text","text":"user question","status":"pending"}`
- `{"type":"reply","replyTo":"c1","ts":...,"text":"your answer"}`
- `{"type":"submit","ids":["c1","c2"],"ts":...,"diffArgs":[...],"cwd":"..."}` — user pressed S; process now.

A comment is **pending** if no reply line references its id.

## Steps

1. Read `.margin/review.jsonl`. Collect pending comments (comments with no reply).
2. For each pending comment, in ONE batch pass:
   - Read the referenced file around `line` (side "new" = current file line number;
     side "old" = pre-change line, check the diff via `diffArgs` if needed).
   - Use `excerpt` to confirm you're looking at the right line.
   - Write a concise, direct answer. No preamble.
3. Append one reply per comment — one valid JSON object per line, **append with `>>`,
   never rewrite the file** (the TUI live-tails it):
   ```bash
   echo '{"type":"reply","replyTo":"c1","ts":1730000000000,"text":"answer here"}' >> .margin/review.jsonl
   ```
   Escape the JSON properly (prefer writing via a heredoc or `jq -n` if quotes get hairy).
4. Also print each answer in the terminal so the user sees it here too.
5. Then watch for further `submit` records and repeat: use the Monitor tool on the
   file if available, otherwise a background bash polling loop
   (`while sleep 2; do ...; done`) that re-checks for new pending comments.

## Rules

- Answer FAST — batch all pending comments in a single pass, don't process one at a time.
- Replies render inline in the TUI within ~50ms of append; keep them short (1-3 sentences).
- Never edit or truncate review.jsonl; append only.
- Don't modify the user's code unless a comment explicitly asks for a change.
