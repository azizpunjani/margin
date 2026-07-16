export type Kind = "ctx" | "add" | "del";
export interface DLine { kind: Kind; oldNo: number | null; newNo: number | null; text: string }
export interface Hunk { header: string; lines: DLine[] }
export interface FileDiff { path: string; hunks: Hunk[] }
export interface Diff { files: FileDiff[] }

export function parseDiff(raw: string): Diff {
  const files: FileDiff[] = [];
  let file: FileDiff | null = null;
  let hunk: Hunk | null = null;
  let oldNo = 0, newNo = 0, oldLeft = 0, newLeft = 0;

  for (const line of raw.split("\n")) {
    if (line.startsWith("diff --git ")) {
      file = { path: line.slice(11).split(" b/").pop() ?? line.slice(11), hunks: [] };
      files.push(file);
      hunk = null;
    } else if (line.startsWith("+++ ") && !hunk) {
      if (file && line !== "+++ /dev/null") file.path = line.slice(4).replace(/^b\//, "");
    } else if (line.startsWith("@@") && file) {
      const m = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(line);
      if (!m) continue;
      oldNo = +m[1]; oldLeft = m[2] === undefined ? 1 : +m[2];
      newNo = +m[3]; newLeft = m[4] === undefined ? 1 : +m[4];
      hunk = { header: line, lines: [] };
      file.hunks.push(hunk);
    } else if (hunk && (oldLeft > 0 || newLeft > 0)) {
      const c = line[0];
      if (c === "+") { hunk.lines.push({ kind: "add", oldNo: null, newNo: newNo++, text: line.slice(1) }); newLeft--; }
      else if (c === "-") { hunk.lines.push({ kind: "del", oldNo: oldNo++, newNo: null, text: line.slice(1) }); oldLeft--; }
      else if (c === "\\") { /* "\ No newline at end of file" */ }
      else { hunk.lines.push({ kind: "ctx", oldNo: oldNo++, newNo: newNo++, text: line.slice(1) }); oldLeft--; newLeft--; }
    }
  }
  return { files };
}

export async function gitDiff(args: string[], cwd?: string): Promise<string> {
  const a = args.length ? args : ["HEAD"];
  const proc = Bun.spawn(["git", "diff", "--no-color", "-U3", ...a], { cwd, stdout: "pipe", stderr: "pipe" });
  const [out, err, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  if (code > 1) throw new Error(err.trim() || `git diff exited ${code}`);
  return out;
}
