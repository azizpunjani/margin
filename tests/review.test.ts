import { expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { appendRecord, nextId, pendingIds, readReview } from "../src/review";

test("reader merges appended replies into threads", () => {
  const f = join(mkdtempSync(join(tmpdir(), "margin-")), "review.jsonl");
  appendRecord(f, { type: "comment", id: "c1", ts: 1, file: "a.txt", line: 2, side: "new", excerpt: "TWO", text: "why caps?", status: "pending" });
  appendRecord(f, { type: "comment", id: "c2", ts: 2, file: "a.txt", line: 4, side: "new", excerpt: "four", text: "off by one?", status: "pending" });

  let threads = readReview(f);
  expect(pendingIds(threads)).toEqual(["c1", "c2"]);
  expect(nextId(threads)).toBe("c3");

  // simulate the AI side appending a reply (>> semantics)
  appendRecord(f, { type: "reply", replyTo: "c1", ts: 3, text: "intentional, see #42" });
  threads = readReview(f);
  expect(threads.get("c1")!.replies).toEqual([{ type: "reply", replyTo: "c1", ts: 3, text: "intentional, see #42" }]);
  expect(pendingIds(threads)).toEqual(["c2"]);
});

test("reader skips malformed lines and missing file", () => {
  expect(readReview("/nonexistent/review.jsonl").size).toBe(0);
  const f = join(mkdtempSync(join(tmpdir(), "margin-")), "review.jsonl");
  appendRecord(f, { type: "comment", id: "c1", ts: 1, file: "a", line: 1, side: "new", excerpt: "", text: "x", status: "pending" });
  Bun.spawnSync(["bash", "-c", `echo 'not json' >> ${f}`]);
  expect(readReview(f).size).toBe(1);
});
