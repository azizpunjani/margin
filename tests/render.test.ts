import { expect, test } from "bun:test";
import type { Diff } from "../src/diff";
import type { Thread } from "../src/review";
import { buildRows, render, type State } from "../src/tui";

const diff: Diff = {
  files: [{
    path: "a.txt",
    hunks: [{
      header: "@@ -1,3 +1,3 @@",
      lines: [
        { kind: "ctx", oldNo: 1, newNo: 1, text: "one" },
        { kind: "del", oldNo: 2, newNo: null, text: "two" },
        { kind: "add", oldNo: null, newNo: 2, text: "TWO" },
      ],
    }],
  }],
};

const threads = new Map<string, Thread>([
  ["c1", {
    comment: { type: "comment", id: "c1", ts: 1, file: "a.txt", line: 2, side: "new", excerpt: "TWO", text: "why caps?", status: "pending" },
    replies: [{ type: "reply", replyTo: "c1", ts: 2, text: "shouting is load-bearing" }],
  }],
]);

test("render produces one frame with diff lines and threaded comment", () => {
  const rows = buildRows(diff, threads);
  const st: State = { rows, cursor: 0, scroll: 0, mode: "normal", input: "", fileCount: 1, pendingCount: 0, message: "" };
  const frame = render(st, 100, 15);

  expect(frame.length).toBe(15); // exactly height lines
  const text = frame.join("\n");
  expect(text).toContain("a.txt");
  expect(text).toContain("@@ -1,3 +1,3 @@");
  expect(text).toContain("+TWO");
  expect(text).toContain("-two");
  expect(text).toContain("why caps?");        // comment thread under the line
  expect(text).toContain("🤖");               // AI reply prefix
  expect(text).toContain("shouting is load-bearing");
  expect(frame[14]).toContain("0 pending");   // status bar
});

test("pending comment shows hourglass; thread rows sit under their line", () => {
  const pend = new Map<string, Thread>([
    ["c2", { comment: { type: "comment", id: "c2", ts: 1, file: "a.txt", line: 2, side: "new", excerpt: "TWO", text: "hm", status: "pending" }, replies: [] }],
  ]);
  const rows = buildRows(diff, pend);
  const addIdx = rows.findIndex((r) => r.t === "line" && r.line.kind === "add");
  expect(rows[addIdx + 1].t).toBe("comment");
  const st: State = { rows, cursor: 0, scroll: 0, mode: "normal", input: "", fileCount: 1, pendingCount: 1, message: "" };
  expect(render(st, 100, 10).join("\n")).toContain("⏳ hm");
});
