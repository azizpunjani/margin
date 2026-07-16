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
- `reply` — appended by the AI (`replyTo` links it to a comment)

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
