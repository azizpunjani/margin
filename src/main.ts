#!/usr/bin/env bun
import { mkdirSync, watch } from "node:fs";
import { dirname } from "node:path";
import { gitDiff, parseDiff, type Diff } from "./diff";
import { appendRecord, nextId, pendingIds, readReview, reviewPath, type Thread } from "./review";
import { buildRows, render, type Row, type State } from "./tui";

const HELP = `margin — fast TUI diff viewer with inline commenting

usage: margin [git-diff-args...]        (no args = git diff HEAD)
   ex: margin main...    margin HEAD~2    margin -- src/foo.ts

keys:
  j/k       move line          d/u   half page down/up
  g/G       top/bottom         ]/[   next/prev file
  c         comment on line    S     submit pending comments
  n/N       next/prev thread   r     reload diff
  q         quit

Comments append to .margin/review.jsonl; AI replies (via the
margin-review Claude Code skill) render threaded inline, live.`;

const diffArgs = process.argv.slice(2);
if (diffArgs.includes("--help") || diffArgs.includes("-h")) {
  console.log(HELP);
  process.exit(0);
}

const rootProc = Bun.spawnSync(["git", "rev-parse", "--show-toplevel"]);
if (rootProc.exitCode !== 0) {
  console.error("margin: not a git repository");
  process.exit(1);
}
const root = rootProc.stdout.toString().trim();
const rpath = reviewPath(root);

let diff: Diff = parseDiff(await gitDiff(diffArgs));
let threads: Map<string, Thread> = readReview(rpath);
if (!diff.files.length) {
  console.log("margin: no changes");
  process.exit(0);
}
if (!process.stdin.isTTY) {
  console.error("margin: stdin is not a TTY");
  process.exit(1);
}

const st: State = {
  rows: buildRows(diff, threads), cursor: 0, scroll: 0,
  mode: "normal", input: "", fileCount: diff.files.length,
  pendingCount: pendingIds(threads).length, message: "",
};

const out = process.stdout;
const size = () => ({ w: out.columns || 80, h: out.rows || 24 });

function paint() {
  const { w, h } = size();
  const body = h - 1;
  if (st.cursor < st.scroll) st.scroll = st.cursor;
  if (st.cursor >= st.scroll + body) st.scroll = st.cursor - body + 1;
  st.scroll = Math.max(0, Math.min(st.scroll, Math.max(0, st.rows.length - body)));
  out.write("\x1b[H" + render(st, w, h).map((l) => l + "\x1b[K").join("\r\n"));
}

function rebuild() {
  st.rows = buildRows(diff, threads);
  st.fileCount = diff.files.length;
  st.pendingCount = pendingIds(threads).length;
  st.cursor = Math.min(st.cursor, Math.max(0, st.rows.length - 1));
}

function reloadReview() {
  threads = readReview(rpath);
  rebuild();
}

function move(d: number) {
  st.cursor = Math.max(0, Math.min(st.rows.length - 1, st.cursor + d));
}

function jumpFile(dir: 1 | -1) {
  const target = (st.rows[st.cursor]?.fileIdx ?? 0) + dir;
  const i = st.rows.findIndex((r) => r.t === "file" && r.fileIdx === target);
  if (i >= 0) st.cursor = i;
}

function jumpThread(dir: 1 | -1) {
  for (let i = st.cursor + dir; i >= 0 && i < st.rows.length; i += dir) {
    const r = st.rows[i];
    if (r.t === "comment" && r.head) { st.cursor = i; return; }
  }
  st.message = "no more threads";
}

function saveComment(text: string) {
  const row = st.rows[st.cursor];
  if (row?.t !== "line") return;
  const side = row.line.newNo !== null ? "new" : "old";
  appendRecord(rpath, {
    type: "comment", id: nextId(threads), ts: Date.now(), file: row.path,
    line: side === "new" ? row.line.newNo : row.line.oldNo, side,
    excerpt: row.line.text, text, status: "pending",
  });
  reloadReview();
  st.message = "comment saved";
}

function submit() {
  const ids = pendingIds(threads);
  if (!ids.length) { st.message = "no pending comments"; return; }
  appendRecord(rpath, { type: "submit", ids, ts: Date.now(), diffArgs, cwd: root });
  st.message = `submitted ${ids.length} comment(s)`;
}

function quit(code = 0): never {
  out.write("\x1b[?25h\x1b[?1049l");
  try { process.stdin.setRawMode(false); } catch {}
  process.exit(code);
}

function onKey(k: string) {
  st.message = "";
  if (st.mode === "input") {
    if (k === "\r") { if (st.input.trim()) saveComment(st.input.trim()); st.mode = "normal"; st.input = ""; }
    else if (k.startsWith("\x1b")) { st.mode = "normal"; st.input = ""; }
    else if (k === "\x7f" || k === "\b") st.input = st.input.slice(0, -1);
    else if (k >= " ") st.input += k;
    return paint();
  }
  const half = Math.max(1, Math.floor((size().h - 1) / 2));
  switch (k) {
    case "q": case "\x03": quit(0);
    case "j": case "\x1b[B": move(1); break;
    case "k": case "\x1b[A": move(-1); break;
    case "d": move(half); break;
    case "u": move(-half); break;
    case "g": st.cursor = 0; break;
    case "G": st.cursor = Math.max(0, st.rows.length - 1); break;
    case "]": jumpFile(1); break;
    case "[": jumpFile(-1); break;
    case "n": jumpThread(1); break;
    case "N": jumpThread(-1); break;
    case "c":
      if (st.rows[st.cursor]?.t === "line") { st.mode = "input"; st.input = ""; }
      else st.message = "move to a diff line to comment";
      break;
    case "S": submit(); break;
    case "r":
      st.message = "reloading…";
      gitDiff(diffArgs, root).then((t) => { diff = parseDiff(t); rebuild(); st.message = ""; paint(); })
        .catch((e) => { st.message = String(e.message ?? e); paint(); });
      break;
  }
  paint();
}

// enter TUI
out.write("\x1b[?1049h\x1b[?25l");
process.stdin.setRawMode(true);
process.stdin.resume();
process.stdin.on("data", (buf) => onKey(buf.toString()));
process.on("SIGINT", () => quit(130));
process.on("SIGTERM", () => quit(143));
out.on("resize", paint);

// live-reload replies: watch .margin dir (file may not exist yet), debounce 50ms
mkdirSync(dirname(rpath), { recursive: true });
let debounce: ReturnType<typeof setTimeout> | undefined;
watch(dirname(rpath), (_ev, name) => {
  if (name && name !== "review.jsonl") return;
  clearTimeout(debounce);
  debounce = setTimeout(() => { reloadReview(); paint(); }, 50);
});

paint();
