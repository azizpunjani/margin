import { expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gitDiff, parseDiff } from "../src/diff";

function sh(cwd: string, ...cmd: string[]) {
  const p = Bun.spawnSync(cmd, { cwd });
  if (p.exitCode !== 0) throw new Error(p.stderr.toString());
}

test("parses a real git diff from a throwaway repo", async () => {
  const dir = mkdtempSync(join(tmpdir(), "margin-"));
  sh(dir, "git", "init", "-q");
  sh(dir, "git", "config", "user.email", "t@t");
  sh(dir, "git", "config", "user.name", "t");
  writeFileSync(join(dir, "a.txt"), "one\ntwo\nthree\n");
  sh(dir, "git", "add", ".");
  sh(dir, "git", "commit", "-qm", "init");
  writeFileSync(join(dir, "a.txt"), "one\nTWO\nthree\nfour\n");

  const diff = parseDiff(await gitDiff([], dir)); // no args -> git diff HEAD

  expect(diff.files.length).toBe(1);
  expect(diff.files[0].path).toBe("a.txt");
  const lines = diff.files[0].hunks[0].lines;
  expect(lines[0]).toEqual({ kind: "ctx", oldNo: 1, newNo: 1, text: "one" });
  expect(lines.find((l) => l.kind === "del")).toEqual({ kind: "del", oldNo: 2, newNo: null, text: "two" });
  const adds = lines.filter((l) => l.kind === "add");
  expect(adds.map((l) => [l.text, l.newNo])).toEqual([["TWO", 2], ["four", 4]]);
});

test("parses new files", () => {
  const raw = [
    "diff --git a/new.txt b/new.txt", "new file mode 100644", "index 0000000..5e1c309",
    "--- /dev/null", "+++ b/new.txt", "@@ -0,0 +1 @@", "+hello", "",
  ].join("\n");
  const d = parseDiff(raw);
  expect(d.files[0].path).toBe("new.txt");
  expect(d.files[0].hunks[0].lines).toEqual([{ kind: "add", oldNo: null, newNo: 1, text: "hello" }]);
});
