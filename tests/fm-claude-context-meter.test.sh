#!/usr/bin/env bash
# Focused synthetic tests for the Claude Code Captain context status line.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-context-meter.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

out=$(FM_TEST_ROOT="$ROOT" FM_TEST_TMP="$TMP_ROOT" node --input-type=module <<'JS'
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, unlinkSync, utimesSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const root = process.env.FM_TEST_ROOT;
const tmp = process.env.FM_TEST_TMP;
function home(name, secondmate = false) {
  const value = join(tmp, name);
  mkdirSync(join(value, "bin"), { recursive: true });
  mkdirSync(join(value, "lib"), { recursive: true });
  mkdirSync(join(value, "state"), { recursive: true });
  writeFileSync(join(value, "AGENTS.md"), "# fixture\n");
  for (const file of ["fm-claude-context-status.mjs"]) cpSync(join(root, "bin", file), join(value, "bin", file));
  for (const file of ["fm-captain-scope.mjs", "fm-context-meter.mjs", "fm-claude-context-meter.mjs"]) cpSync(join(root, "lib", file), join(value, "lib", file));
  if (secondmate) writeFileSync(join(value, ".fm-secondmate-home"), "fixture\n");
  return value;
}
const captain = home("captain");
function payload(used, size = 200000) {
  return { context_window: { context_window_size: size, used_percentage: used, total_input_tokens: 99999999, total_output_tokens: 99999999 } };
}
function invoke(status, options = {}) {
  const fmHome = options.fmHome ?? captain;
  const result = spawnSync("node", [join(fmHome, "bin", "fm-claude-context-status.mjs")], {
    input: options.raw ?? JSON.stringify(status), encoding: "utf8",
    env: { ...process.env, FM_HOME: fmHome, FM_STATE_OVERRIDE: join(fmHome, "state") },
  });
  if (result.status !== 0 || result.stderr) throw new Error(`status command failed: ${result.stderr}`);
  return result.stdout;
}
if (invoke(payload(37.0)) !== "Captain context: 74k") throw new Error("below 75k did not render context only");
if (!invoke(payload(38.0)).includes("76k. Context is getting large.")) throw new Error("75k warning missing");
if (invoke(payload(40.0)) !== "Captain context: 80k") throw new Error("75k warning repeated");
if (!invoke(payload(60.5)).includes("121k. Compact at the next safe checkpoint.")) throw new Error("120k warning missing");
if (!invoke(payload(80.5)).includes("161k. Strongly recommend compacting")) throw new Error("160k warning missing");
if (invoke(payload(85.0)) !== "Captain context: 170k") throw new Error("160k warning repeated");
if (invoke(payload(80.0)) !== "Captain context: 160k") throw new Error("small/non-reset state changed unexpectedly");
if (!invoke(payload(10.0)).includes("20k")) throw new Error("reset observation did not render");
if (!invoke(payload(38.0)).includes("76k. Context is getting large.")) throw new Error("reset did not re-arm 75k");
const state = JSON.parse(readFileSync(join(captain, "state", "claude-context-meter.json"), "utf8"));
if (JSON.stringify(state) !== JSON.stringify({ notifiedTokens: [75000], lastTokens: 76000 })) throw new Error(`unexpected persistent state ${JSON.stringify(state)}`);
mkdirSync(join(captain, "state", "claude-context-meter.json.lock"));
if (invoke(payload(60.5)) !== "") throw new Error("a concurrent status update was not inert");
rmSync(join(captain, "state", "claude-context-meter.json.lock"), { recursive: true });
const staleLock = join(captain, "state", "claude-context-meter.json.lock");
mkdirSync(staleLock);
utimesSync(staleLock, new Date(Date.now() - 61_000), new Date(Date.now() - 61_000));
if (!invoke(payload(60.5)).includes("121k. Compact at the next safe checkpoint.")) throw new Error("stale lock was not recovered");
if (existsSync(staleLock)) throw new Error("recovered stale lock was not cleaned up");
const recoveredState = JSON.parse(readFileSync(join(captain, "state", "claude-context-meter.json"), "utf8"));
if (JSON.stringify(recoveredState) !== JSON.stringify({ notifiedTokens: [75000, 120000], lastTokens: 121000 })) throw new Error("stale recovery did not update state");
if (invoke({ context_window: { context_window_size: 200000, used_percentage: 101 } }) !== "") throw new Error("invalid percentage was accepted");
if (invoke({ context_window: { context_window_size: 200000 } }) !== "") throw new Error("missing usage was accepted");
if (invoke({}, { raw: "not-json" }) !== "") throw new Error("malformed JSON was accepted");
if (invoke(payload(38), { fmHome: home("second", true) }) !== "") throw new Error("secondmate was not inert");
const unknown = home("unknown");
unlinkSync(join(unknown, "AGENTS.md"));
if (invoke(payload(38), { fmHome: unknown }) !== "") throw new Error("unconfirmed home was not inert");
JS
) || fail "Claude context meter tests failed: $out"
[ -z "$out" ] || fail "Claude context meter tests printed output: $out"
pass "Claude status line is Captain-only, UI-only, persistent, and threshold-safe"
