# Instructions for AI agents

## Working on this repo

- TUI source: `src/` (TypeScript, Bun, zero npm deps — keep it that way).
- Neovim plugin: `nvim/lua/margin/` + `nvim/plugin/margin.lua` (no plugin deps).
- Tests must pass before any commit: `bun test` (TUI) and
  `bun run test:nvim` (plugin; each test runs headless in a throwaway repo).
- Build: `bun run build` → `dist/margin` (never commit `dist/` or `*.bun-build`).
- The protocol is append-only JSONL. Never add a record type that requires
  rewriting the file; frontends must skip unknown record types.

## Acting as a margin review agent

The complete playbook is `skill/SKILL.md` (installed for Claude Code as the
`margin-review` skill). The contract in brief:

1. Watch `<repo-root>/.margin/review.jsonl` for new `comment` / `user-reply`
   records (poll the record count; the file is append-only).
2. Answer immediately: first append a `reply-chunk` ack, then the final
   `reply` — one JSON object per line, **append with `>>`, never rewrite**.
3. A comment asking for a change means: edit the code, then reply with
   `"edit":true` summarizing the change.
4. Skip `resolve`d threads and your own `author:"ai"` observations unless a
   `user-reply` reopens them.
5. `.margin/presence.json` (sidecar, overwritten in place) is where the user's
   cursor is dwelling — use it to pre-read code; never reply to it.

Record shapes and the pending rule are documented in README.md → Protocol.
