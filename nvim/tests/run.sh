#!/usr/bin/env bash
# Headless margin.nvim tests: each *_test.lua runs in a fresh throwaway git
# repo (a.txt committed w/ 2 lines then modified, b.txt committed).
set -euo pipefail
cd "$(dirname "$0")"
PLUGIN="$(cd .. && pwd)"
export PLUGIN
fail=0
for t in *_test.lua; do
  tmp="$(mktemp -d)"
  REPO="$tmp/repo"
  mkdir -p "$REPO"
  git -C "$tmp" init -q repo
  printf 'line1\nline2\n' >"$REPO/a.txt"
  printf 'x\n' >"$REPO/b.txt"
  git -C "$REPO" add . >/dev/null
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm init
  printf 'line1\nline2\nline3\n' >"$REPO/a.txt" # working change
  if REPO="$REPO" nvim --clean --headless -l "$t"; then
    echo "PASS $t"
  else
    echo "FAIL $t"
    fail=1
  fi
  rm -rf "$tmp"
done
exit $fail
