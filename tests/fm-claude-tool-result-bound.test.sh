#!/usr/bin/env bash
# Focused synthetic tests for Claude Code PostToolUse result replacement.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-tool-result-bound.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

out=$(FM_TEST_ROOT="$ROOT" FM_TEST_TMP="$TMP_ROOT" node --input-type=module <<'JS'
import { cpSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const root = process.env.FM_TEST_ROOT;
const tmp = process.env.FM_TEST_TMP;
const hook = join(root, "bin/fm-tool-result-bound-hook.mjs");
function home(name, secondmate = false) {
  const value = join(tmp, name);
  mkdirSync(join(value, "bin"), { recursive: true });
  mkdirSync(join(value, "lib"), { recursive: true });
  mkdirSync(join(value, "state"), { recursive: true });
  writeFileSync(join(value, "AGENTS.md"), "# fixture\n");
  cpSync(hook, join(value, "bin", "fm-tool-result-bound-hook.mjs"));
  cpSync(join(root, "lib", "fm-captain-scope.mjs"), join(value, "lib", "fm-captain-scope.mjs"));
  cpSync(join(root, "lib", "fm-tool-result-bound.mjs"), join(value, "lib", "fm-tool-result-bound.mjs"));
  if (secondmate) writeFileSync(join(value, ".fm-secondmate-home"), "fixture\n");
  return value;
}
const captain = home("captain");
function invoke(event, options = {}) {
  const fmHome = options.fmHome ?? captain;
  const child = spawnSync("node", [join(fmHome, "bin", "fm-tool-result-bound-hook.mjs")], {
    input: options.rawInput ?? JSON.stringify(event), encoding: "utf8",
    env: { ...process.env, FM_HOME: fmHome, FM_STATE_OVERRIDE: options.state ?? join(captain, "state") },
  });
  if (child.status !== 0 || child.stderr) throw new Error(`hook failed: ${child.stderr}`);
  return child.stdout ? JSON.parse(child.stdout) : undefined;
}
function bounded(event) {
  const output = invoke(event);
  if (!output || Object.keys(output).length !== 1 || output.hookSpecificOutput?.hookEventName !== "PostToolUse") throw new Error("invalid hook JSON");
  return output.hookSpecificOutput.updatedToolOutput;
}
const common = { hook_event_name: "PostToolUse", session_id: "captain-session" };
const smallBash = { ...common, tool_use_id: "small-bash", tool_name: "Bash", tool_response: { stdout: "small Bash", stderr: "", interrupted: false, isImage: false, metadata: "kept" } };
if (invoke(smallBash) !== undefined) throw new Error("small Bash changed");
const bashText = `bash-head-${"b".repeat(12 * 1024)}-bash-tail`;
const bash = bounded({ ...common, tool_use_id: "large-bash", tool_name: "Bash", tool_response: { stdout: bashText, stderr: "", interrupted: false, isImage: false, metadata: "kept" } });
if (bash.stderr !== "" || bash.interrupted || bash.isImage || bash.metadata !== "kept" || Buffer.byteLength(bash.stdout) > 5 * 1024) throw new Error("Bash native fields were not preserved");
const bashArchive = bash.stdout.match(/^archive: (.+)$/m)?.[1];
if (!bashArchive || readFileSync(bashArchive, "utf8") !== bashText) throw new Error("Bash archive is not exact");
const bashWithStderr = `bash-stdout-${"s".repeat(12 * 1024)}`;
const stderrBound = bounded({ ...common, tool_use_id: "large-bash-stderr", tool_name: "Bash", tool_response: { stdout: bashWithStderr, stderr: "warning", interrupted: false, isImage: false, metadata: "kept" } });
if (stderrBound.stderr !== "" || stderrBound.metadata !== "kept" || Buffer.byteLength(stderrBound.stdout) > 5 * 1024) throw new Error("Bash stderr result was not bounded");
const stderrArchive = stderrBound.stdout.match(/^archive: (.+)$/m)?.[1];
if (!stderrArchive || readFileSync(stderrArchive, "utf8") !== `${bashWithStderr}\n[stderr]\nwarning`) throw new Error("Bash stderr archive is not exact");
const smallRead = { ...common, tool_use_id: "small-read", tool_name: "Read", tool_response: { type: "text", file: { filePath: "/tmp/small.txt", content: "small Read", numLines: 1, startLine: 1, totalLines: 1 } } };
if (invoke(smallRead) !== undefined) throw new Error("small Read changed");
const readText = `read-head-${"r".repeat(12 * 1024)}-read-tail`;
const read = bounded({ ...common, tool_use_id: "large-read", tool_name: "Read", tool_response: { type: "text", file: { filePath: "/tmp/example.txt", content: readText, numLines: 3, startLine: 1, totalLines: 3, truncatedByTokenCap: false }, artifactRead: { slug: "fixture", ver: "1" } } });
if (read.type !== "text" || read.file.filePath !== "/tmp/example.txt" || read.file.numLines !== 3 || read.file.startLine !== 1 || read.file.totalLines !== 3 || read.file.truncatedByTokenCap || read.artifactRead.slug !== "fixture" || Buffer.byteLength(read.file.content) > 5 * 1024) throw new Error("Read native fields were not preserved");
const readArchive = read.file.content.match(/^archive: (.+)$/m)?.[1];
if (!readArchive || readFileSync(readArchive, "utf8") !== readText) throw new Error("Read archive is not exact");
if (invoke({ ...common, tool_use_id: "unsupported", tool_name: "Read", tool_response: { type: "image", file: {} } }) !== undefined) throw new Error("unsupported result changed");
if (invoke({}, { rawInput: "{not-json" }) !== undefined) throw new Error("malformed input changed output");
if (invoke({ ...common, tool_use_id: "second", tool_name: "Bash", tool_response: { stdout: bashText, stderr: "", interrupted: false, isImage: false } }, { fmHome: home("second", true), state: join(tmp, "second", "state") }) !== undefined) throw new Error("secondmate changed");
const unconfirmed = home("unconfirmed"); unlinkSync(join(unconfirmed, "AGENTS.md"));
if (invoke({ ...common, tool_use_id: "unconfirmed", tool_name: "Bash", tool_response: { stdout: bashText, stderr: "", interrupted: false, isImage: false } }, { fmHome: unconfirmed, state: join(unconfirmed, "state") }) !== undefined) throw new Error("unconfirmed scope changed");
const failedState = join(tmp, "failed-state"); mkdirSync(failedState); writeFileSync(join(failedState, "tool-results"), "not a directory\n");
if (invoke({ ...common, tool_use_id: "archive-failure", tool_name: "Bash", tool_response: { stdout: bashText, stderr: "", interrupted: false, isImage: false } }, { state: failedState }) !== undefined) throw new Error("archive failure changed result");
JS
) || fail "Claude tool-result bound tests failed: $out"
[ -z "$out" ] || fail "Claude tool-result bound test printed output: $out"
pass "Claude PostToolUse hook bounds Bash/Read text and fails open"
