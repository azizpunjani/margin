# margin

Fast TUI diff viewer with inline commenting. Zero dependencies (Bun + raw ANSI).
You review a diff and leave comments; a Claude Code session (running the
`margin-review` skill) replies, and replies appear threaded inline, live.

```
margin                # git diff HEAD (working tree incl. staged)
margin main...        # any git-diff args pass through
margin -- src/foo.ts
```

## Keys

| key | action |
|---|---|
| j/k | move line (arrows work too) |
| d/u | half page down/up |
| g/G | top / bottom |
| ]/[ | next / prev file |
| c | comment on current line (Enter save, Esc cancel) |
| S | submit all pending comments |
| n/N | next / prev comment thread |
| r | reload diff |
| q | quit |

## Protocol

Append-only JSONL at `<repo>/.margin/review.jsonl`:

- `comment` — written when you save a comment (`id`, `file`, `line`, `side`, `excerpt`, `text`)
- `submit` — written on `S` with the pending comment ids; signals the AI to process
- `reply` — appended by the AI (`replyTo` links it to a comment); may carry
  `"edit":true` when the AI changed code to satisfy the comment
- `user-reply` — the user continuing a thread (`replyTo`, `ts`, `text`); reopens
  it: a thread is pending when it has no AI reply, or its latest message is a
  user-reply
- `review-request` — appended by the AI (`files` repo-root-relative, `base` git
  rev, optional `note`); asks the human to review those files (`:MarginReview`
  in nvim picks it up)

The TUI watches the file (fs.watch, 50ms debounce) and re-renders threads on change.

## AI side

In another terminal, in the same repo, run Claude Code and invoke the
`margin-review` skill. It reads pending comments, appends reply lines (with `>>`,
never rewriting), and keeps watching for new `submit` records.

## Dev

```
bun run dev        # run from source
bun test           # tests
bun run build      # compile to dist/margin
```

## Neovim

`nvim/` is a zero-dependency plugin frontend to the same protocol — comment
from normal buffers while editing, no TUI needed. Install by putting it on the
runtimepath, e.g.:

```lua
vim.opt.runtimepath:prepend '/path/to/margin/nvim'
```

| key / cmd | action |
|---|---|
| `<leader>mc` (n/v) | comment on current line (visual: range start) |
| `<leader>ms` | submit all pending comments |
| `<leader>mr` | reply within the thread at/nearest above the cursor |
| `<leader>mn` / `<leader>mp` | jump next / prev thread in buffer |
| `<leader>mq` | all threads to quickfix |
| `:MarginReview [base]` | diff tabs for the latest `review-request` (or all files changed vs `base`); base version left (readonly), working file right — comment on the right; `gt`/`gT` switches files |
| `:MarginClear` / `:MarginShow` | hide / re-show thread virt_lines in buffer |

Threads render as virt_lines under the commented line (`┃ 💬` comment, `⏳`
pending, `┃ 🤖` reply, `┃ ✏️` reply where the AI edited code, `┃ 👤` your
threaded replies — highlight groups `MarginComment` / `MarginReply`). Messages
interleave in timestamp order. The plugin watches `review.jsonl` per repo root
(multi-repo safe) and re-renders on change; it also runs `:checktime` so AI
edits to files on disk reload into your buffers (keep `autoread` on).

The plugin also overwrites the ephemeral `.margin/presence.json`
(`{"file":...,"line":...,"ts":...}`) when your cursor dwells ~2 seconds at a
spot (throttled: same file and <10-line moves are skipped) — presence fires
when you linger, so the AI primes on code you're actually reading, before any
comment exists.
