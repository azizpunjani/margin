import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

export interface Comment {
  type: "comment"; id: string; ts: number; file: string; line: number;
  side: "new" | "old"; excerpt: string; text: string; status: string;
}
export interface Reply { type: "reply"; replyTo: string; ts: number; text: string }
export interface Thread { comment: Comment; replies: Reply[] }

export function reviewPath(repoRoot: string): string {
  return join(repoRoot, ".margin", "review.jsonl");
}

export function readReview(path: string): Map<string, Thread> {
  const threads = new Map<string, Thread>();
  if (!existsSync(path)) return threads;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (!line.trim()) continue;
    let rec: any;
    try { rec = JSON.parse(line); } catch { continue; }
    if (rec.type === "comment") threads.set(rec.id, { comment: rec, replies: [] });
    else if (rec.type === "reply") threads.get(rec.replyTo)?.replies.push(rec);
  }
  return threads;
}

export function appendRecord(path: string, rec: unknown): void {
  mkdirSync(dirname(path), { recursive: true });
  appendFileSync(path, JSON.stringify(rec) + "\n");
}

export function nextId(threads: Map<string, Thread>): string {
  let max = 0;
  for (const id of threads.keys()) {
    const m = /^c(\d+)$/.exec(id);
    if (m) max = Math.max(max, +m[1]);
  }
  return `c${max + 1}`;
}

export function pendingIds(threads: Map<string, Thread>): string[] {
  return [...threads.values()].filter((t) => t.replies.length === 0).map((t) => t.comment.id);
}
