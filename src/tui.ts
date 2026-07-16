// Pure rendering: (state, width, height) -> lines. No IO in this module.
import type { Diff, DLine } from "./diff";
import type { Thread } from "./review";

const R = "\x1b[0m";

export type Row =
  | { t: "file"; path: string; fileIdx: number }
  | { t: "hunk"; text: string; fileIdx: number }
  | { t: "line"; line: DLine; path: string; fileIdx: number }
  | { t: "comment"; text: string; fileIdx: number; head?: boolean; ai?: boolean };

export interface State {
  rows: Row[];
  cursor: number;
  scroll: number;
  mode: "normal" | "input";
  input: string;
  fileCount: number;
  pendingCount: number;
  message: string;
}

export function buildRows(diff: Diff, threads: Map<string, Thread>): Row[] {
  const rows: Row[] = [];
  diff.files.forEach((f, fileIdx) => {
    rows.push({ t: "file", path: f.path, fileIdx });
    for (const h of f.hunks) {
      rows.push({ t: "hunk", text: h.header, fileIdx });
      for (const line of h.lines) {
        rows.push({ t: "line", line, path: f.path, fileIdx });
        for (const th of threads.values()) {
          const c = th.comment;
          const no = c.side === "new" ? line.newNo : line.oldNo;
          if (c.file !== f.path || no === null || no !== c.line) continue;
          const pending = th.replies.length === 0;
          rows.push({ t: "comment", head: true, text: `${pending ? "⏳ " : ""}${c.text}`, fileIdx });
          for (const r of th.replies) rows.push({ t: "comment", ai: true, text: r.text, fileIdx });
        }
      }
    }
  });
  return rows;
}

function clip(s: string, w: number): string {
  return s.length > w ? s.slice(0, Math.max(0, w - 1)) + "…" : s;
}

function renderRow(row: Row, cur: boolean, width: number): string {
  const g = cur ? "\x1b[1m▸ " + R : "  ";
  const w = width - 2;
  switch (row.t) {
    case "file":
      return g + `\x1b[1;7m ${clip(row.path, w - 2)} ` + R;
    case "hunk":
      return g + "\x1b[36m" + clip(row.text, w) + R;
    case "line": {
      const l = row.line;
      const nums = `${l.oldNo ?? ""}`.padStart(4) + " " + `${l.newNo ?? ""}`.padStart(4) + " ";
      const sign = l.kind === "add" ? "+" : l.kind === "del" ? "-" : " ";
      const col = l.kind === "add" ? "\x1b[32m" : l.kind === "del" ? "\x1b[31m" : "";
      return g + "\x1b[2m" + nums + R + col + clip(sign + l.text, w - 10) + R;
    }
    case "comment": {
      const box = "\x1b[2;33m┃ " + R;
      const body = row.ai
        ? "\x1b[35m🤖 " + R + "\x1b[2m" + clip(row.text, w - 16) + R
        : "\x1b[2;33m" + clip(row.text, w - 13) + R;
      return g + "          " + box + body;
    }
  }
}

function statusBar(st: State, width: number): string {
  let s: string;
  if (st.mode === "input") {
    s = ` Comment: ${st.input}▏   (Enter save · Esc cancel)`;
  } else {
    const fi = st.fileCount ? (st.rows[st.cursor]?.fileIdx ?? 0) + 1 : 0;
    s = ` file ${fi}/${st.fileCount} │ ${st.pendingCount} pending │ j/k d/u g/G ]/[ file  c comment  S submit  n/N thread  r reload  q quit`;
    if (st.message) s += ` │ ${st.message}`;
  }
  return "\x1b[7m" + clip(s, width).padEnd(width) + R;
}

export function render(st: State, width: number, height: number): string[] {
  const out: string[] = [];
  for (let i = st.scroll; i < st.scroll + height - 1; i++) {
    const row = st.rows[i];
    out.push(row ? renderRow(row, i === st.cursor, width) : "\x1b[2m~" + R);
  }
  out.push(statusBar(st, width));
  return out;
}
