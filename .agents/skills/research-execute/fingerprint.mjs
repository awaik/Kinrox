#!/usr/bin/env node
// Fingerprint dirty checkout paths (hash, permissions, symlink target).
// This detects changes; it is not a backup of file contents.
// Usage: fingerprint.mjs snapshot|diff <repo> <snapshot.json>
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { lstatSync, readFileSync, readlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";

function dirtyPaths(repo) {
  const out = execFileSync(
    "git",
    ["-C", repo, "-c", "core.quotepath=off", "status", "--porcelain=v1", "-z", "-uall"],
    { encoding: "utf8", maxBuffer: 256 * 1024 * 1024 },
  );
  const fields = out.split("\0").filter(Boolean);
  const paths = [];
  for (let i = 0; i < fields.length; i += 1) {
    const entry = fields[i];
    paths.push(entry.slice(3));
    // Renames and copies include the original path in the next field.
    if (entry[0] === "R" || entry[0] === "C") paths.push(fields[++i]);
  }
  return [...new Set(paths)].sort();
}

function fingerprintOf(repo, path) {
  const abs = join(repo, path);
  let stat;
  try {
    stat = lstatSync(abs);
  } catch {
    return "deleted";
  }
  if (stat.isSymbolicLink()) return `symlink:${readlinkSync(abs)}`;
  if (stat.isDirectory()) return "dir";
  const hash = createHash("sha256").update(readFileSync(abs)).digest("hex");
  return `${(stat.mode & 0o777).toString(8)}:${hash}`;
}

function snapshot(repo) {
  return Object.fromEntries(dirtyPaths(repo).map((path) => [path, fingerprintOf(repo, path)]));
}

const [command, repo, file] = process.argv.slice(2);
if (!repo || !file || !["snapshot", "diff"].includes(command)) {
  process.stderr.write("usage: fingerprint.mjs snapshot|diff <repo> <file.json>\n");
  process.exit(2);
}

if (command === "snapshot") {
  writeFileSync(file, `${JSON.stringify(snapshot(repo), null, 1)}\n`);
  process.exit(0);
}

const before = JSON.parse(readFileSync(file, "utf8"));
const now = snapshot(repo);
const lines = [];
for (const path of [...new Set([...Object.keys(before), ...Object.keys(now)])].sort()) {
  const was = before[path];
  const is = now[path];
  if (was === is) continue;
  if (was === undefined) lines.push(`- changed since startup: \`${path}\`${is === "deleted" ? " (deleted)" : ""}`);
  else if (is === undefined) lines.push(`- WARNING: a pre-existing change disappeared (path returned to HEAD): \`${path}\``);
  else lines.push(`- changed over a pre-existing edit: \`${path}\`${is === "deleted" ? " (deleted)" : ""}`);
}
process.stdout.write(lines.length ? `${lines.join("\n")}\n` : "- no changes since startup\n");
