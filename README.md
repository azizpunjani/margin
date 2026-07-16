# margin

AI code review in your editor's margin — powered by one JSONL file.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zero runtime deps](https://img.shields.io/badge/runtime%20deps-zero-brightgreen.svg)](#quickstart)
[![Made with Bun](https://img.shields.io/badge/built%20with-bun-f9f1e1.svg)](https://bun.sh)

You review a diff in Neovim (or a zero-dependency TUI) and leave comments
inline. An AI agent answers threaded in place within seconds — and edits the
code when a comment asks for a change. The entire transport is one append-only
JSONL file: no server, no sockets, no browser. The design thesis is speed —
appending a record takes ~1 ms, the watcher wakes in 0.2 s, rendering takes
under 100 ms. The only real wait in the loop is model inference.

```
  25 // Standard Stripe test card (Mastercard): https://docs.stripe.com/testing
  26 const TEST_CARD = {
  27   number: '5555555555554444',
  28   expiry: '12/34',
  29   cvc: '123',
  30   zip: '94107',
  31 };
     ┃ 💬 [L26–31] what is this code about?
     ┃ 🤖 Stripe's standard test card (docs.stripe.com/testing): 4242… always
     ┃    approves in test mode, never charges real money. The signup spec
     ┃    uses it to pay for the E2E_SIGNUP_PRODUCT (…
     ┃ 👤 ah gotcha
     ┃ 🤖 👍
     ┃ 💬 can you change this to another card that works?
     ┃ ✏️ Swapped to Stripe's Mastercard test card 5555 5555 5555 4444 (also
     ┃    always-approves in test mode, same expiry/cvc/zip fine). Line 27 +
     ┃    comment updated — buffer should have reloa…
```

One thread, seconds apart: question → answer → follow-up → code change. The AI
edited line 27 and the buffer reloaded.

## Features

- **Inline threaded comments** — 💬 you, 🤖 AI, 👤 your follow-ups, interleaved
  in timestamp order under the commented line.
- **AI code edits from comments** — change requests are made in the working
  tree, marked `"edit":true` (✏️), and reloaded into your buffers.
- **AI first-pass observations** — the agent can flag risky lines (💡) before
  you ask.
- **Streaming replies** — long answers arrive as `reply-chunk` records with a
  typing cursor (▌) until the final reply supersedes them.
- **Visual-range comments** — select lines, `<leader>mc`; the thread shows
  `[L26–31]` and the AI reasons about the whole span.
- **Resolve / archive** — `<leader>mx` per thread, `:MarginResolveAll` for all.
- **File picker with comment counts** — `<leader>mf`.
- **Diff review vs any base** — `:MarginReview [base]` opens diff tabs (base
  left, working file right); files that don't exist at base open plain.
- **Gaze priming** — nvim writes `.margin/presence.json` when your cursor
  dwells ~2 s, so the AI pre-reads the code you're looking at before you type.
- **Zero-dependency compiled TUI** — review any git diff from a bare shell.
- **Open, file-based protocol** — anything that can read and append a file can
  integrate.

## Quickstart

```sh
git clone https://github.com/azizpunjani/margin
cd margin && ./install.sh
```

`install.sh` builds the TUI to a single compiled binary, links it at
`~/.local/bin/margin`, installs the `margin-review` Claude Code skill into
`~/.claude/skills/`, and prints the Neovim loader snippet. Idempotent — safe to
re-run after `git pull`.

**Prerequisites:** [bun](https://bun.sh) to build the TUI binary. A
Neovim-only setup needs no build at all — skip the script and add the plugin
to your runtimepath:

```lua
vim.opt.runtimepath:prepend '/path/to/margin/nvim'
```

Then run the TUI against any diff:

```sh
margin                # git diff HEAD (working tree incl. staged)
margin main...        # any git-diff args pass through
margin -- src/foo.ts
```

TUI keys: `j/k` move, `d/u` half page, `g/G` top/bottom, `]/[` next/prev file,
`c` comment, `S` submit, `n/N` next/prev thread, `r` reload, `q` quit.

## Neovim

| Key / command | Action |
|---|---|
| `<leader>mc` (n/v) | Comment on current line (visual mode: whole range) |
| `<leader>mr` | Reply within the thread at / nearest above the cursor |
| `<leader>mx` | Resolve thread at cursor (`:MarginResolveAll` for all) |
| `<leader>ms` | Submit pending comments |
| `<leader>mn` / `<leader>mp` | Jump next / prev thread in buffer |
| `<leader>mq` | All threads to quickfix |
| `<leader>mf` | File picker with comment counts |
| `:MarginReview [base]` | Diff tabs for the latest `review-request` (or all files changed vs `base`); base version left (readonly), working file right |
| `:MarginClear` / `:MarginShow` | Hide / re-show threads in buffer |

Threads render as virt_lines under the commented line (highlight groups
`MarginComment` / `MarginReply`). The plugin watches `review.jsonl` per repo
root (multi-repo safe) and runs `:checktime` so AI edits on disk reload into
your buffers (keep `autoread` on).

## Protocol

All state lives in `<repo-root>/.margin/review.jsonl` — one JSON object per
line, **append-only**. Frontends live-tail it; never rewrite or truncate.

```jsonc
{"type":"comment","id":"c1","ts":1730000000000,"file":"src/pay.ts","line":26,"endLine":31,"side":"new","excerpt":"const TEST_CARD = {","text":"what is this?"}
{"type":"reply-chunk","replyTo":"c1","ts":1730000001000,"text":"reading pay.ts:26… "}   // streamed; rendered with a ▌ cursor
{"type":"reply","replyTo":"c1","ts":1730000002000,"text":"Stripe's test card…"}          // final; supersedes the chunks
{"type":"user-reply","replyTo":"c1","ts":1730000003000,"text":"swap it for a Mastercard"} // reopens the thread
{"type":"reply","replyTo":"c1","ts":1730000009000,"text":"Swapped to 5555…4444","edit":true} // AI changed the code
{"type":"resolve","ids":["c1"],"ts":1730000010000}                                       // archived; skip these
{"type":"submit","ids":["c1"],"ts":1730000011000}                                        // batch marker from S / <leader>ms
{"type":"review-request","ts":1730000020000,"files":["src/pay.ts"],"base":"HEAD","note":"card swap"} // AI asks YOU to review
```

A thread is *pending* when it has no `reply`, or its latest message is a
`user-reply`. A separate ephemeral sidecar, `.margin/presence.json`
(`{"file":…,"line":…,"ts":…}`, overwritten in place — not part of the log),
reports where the user's cursor is dwelling, for priming only.

Because the protocol is just a file, integrating any agent is a tail and an
append:

```sh
tail -f .margin/review.jsonl | while read -r rec; do
  # when rec is a "comment": think, then answer with one append
  echo '{"type":"reply","replyTo":"c1","ts":1730000000000,"text":"…"}' >> .margin/review.jsonl
done
```

## Integrations

- **Claude Code** — the bundled `margin-review` skill (installed by
  `install.sh`) acks comments within a second, streams answers, makes code
  edits on request, primes on `presence.json`, and appends `review-request`
  records for its own changes. Run Claude Code in another terminal in the same
  repo and invoke the skill.
- **Any agent** — implement the protocol above; append-only is the only rule.
- **herdr / tmux (optional)** — when the AI requests a review of its own
  changes, it can auto-open `nvim +MarginReview` in a split pane. Without a
  multiplexer it degrades gracefully: run `nvim +MarginReview` yourself.

## Development

```sh
bun run dev           # run the TUI from source
bun test              # TUI tests
bun run test:nvim     # nvim plugin tests (nvim/tests/run.sh)
bun run build         # compile to dist/margin
```

## License

MIT © Aziz Punjani
