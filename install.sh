#!/usr/bin/env bash
# margin installer: build TUI, link binary, install Claude Code skill, print
# the nvim loader snippet. Idempotent — safe to re-run after git pull.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

command -v bun >/dev/null || { echo "bun required: https://bun.sh (brew install oven-sh/bun/bun)"; exit 1; }

echo "→ building TUI…"
bun install --frozen-lockfile 2>/dev/null || true
bun run build

BIN="$HOME/.local/bin"
mkdir -p "$BIN"
ln -sf "$ROOT/dist/margin" "$BIN/margin"
echo "→ linked $BIN/margin ($(du -h dist/margin | cut -f1))"

SKILL="$HOME/.claude/skills/margin-review"
mkdir -p "$SKILL"
cp skill/SKILL.md "$SKILL/SKILL.md"
echo "→ installed Claude Code skill: margin-review"

cat <<EOF

Done. Two manual steps if not done yet:

1. PATH: ensure $BIN is on your PATH.

2. Neovim — add a loader (e.g. ~/.config/nvim/lua/custom/plugins/margin.lua):

   -- margin.nvim: local plugin from the margin repo
   vim.opt.rtp:prepend('$ROOT/nvim')

Keys: <leader>mc comment · <leader>mr thread reply · <leader>mx resolve
      <leader>mf file picker · <leader>mn/mp jump · :MarginReview [base]
EOF
