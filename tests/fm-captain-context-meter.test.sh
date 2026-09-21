#!/usr/bin/env bash
# Focused synthetic tests for the Captain-only Pi context meter.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-context-meter.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

test_meter_core() {
  local out status
  out=$(FM_CONTEXT_ROOT="$ROOT" node --input-type=module 2>&1 <<'JS'
const { createContextMeter, promptContextTokens } = await import(`${process.env.FM_CONTEXT_ROOT}/lib/fm-context-meter.mjs`);
const meter = createContextMeter();
const warning = (tokens) => meter.observe(tokens)?.tokens ?? null;

if (warning(40_000) !== null) throw new Error("40k warned");
if (warning(76_000) !== 75_000) throw new Error("76k did not warn at 75k");
if (warning(80_000) !== null || warning(90_000) !== null) throw new Error("75k warning repeated");
if (warning(121_000) !== 120_000 || warning(121_000) !== null) throw new Error("120k warning was not once");
if (warning(161_000) !== 160_000 || warning(170_000) !== null) throw new Error("160k warning was not once");
meter.reset();
if (warning(40_000) !== null || warning(76_000) !== 75_000) throw new Error("reset did not re-arm 75k");

const tokens = promptContextTokens({ input: 70_000, cacheRead: 40_000, cacheWrite: 10_000, output: 999_999, totalTokens: 1_119_999 });
if (tokens !== 120_000) throw new Error(`prompt token formula was ${tokens}`);
if (promptContextTokens({ input: 1, cacheRead: -1, cacheWrite: 1 }) !== null) throw new Error("invalid usage was accepted");
JS
  )
  status=$?
  [ "$status" -eq 0 ] || fail "context meter core failed: $out"
  [ -z "$out" ] || fail "context meter core printed output: $out"
  pass "thresholds notify once, reset re-arms, and output is excluded from prompt context"
}

test_pi_adapter() {
  local repo out status
  repo="$TMP_ROOT/pi"
  mkdir -p "$repo/.pi/extensions" "$repo/lib" "$repo/bin" "$repo/state" "$repo/private-state" "$repo/node_modules/@earendil-works/pi-coding-agent"
  : > "$repo/AGENTS.md"
  cp "$ROOT/.pi/extensions/fm-captain-context-meter.ts" "$repo/.pi/extensions/"
  cp "$ROOT/lib/fm-captain-scope.mjs" "$ROOT/lib/fm-context-meter.mjs" "$repo/lib/"
  printf '%s\n' '{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}' > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json"
  : > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js"
  out=$(FM_HOME="$repo" FM_STATE_OVERRIDE="$repo/private-state" PLUGIN="$repo/.pi/extensions/fm-captain-context-meter.ts" node --input-type=module 2>&1 <<'JS'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

async function load(home, secondmate = false) {
  process.env.FM_HOME = home;
  const marker = `${home}/.fm-secondmate-home`;
  if (secondmate) writeFileSync(marker, "mate\n");
  else if (existsSync(marker)) throw new Error("fixture marker leaked");
  const handlers = new Map();
  const mod = await import(`${pathToFileURL(process.env.PLUGIN).href}?case=${Math.random()}`);
  mod.default({
    on(name, handler) { handlers.set(name, handler); },
    sendMessage() { throw new Error("adapter must not send a context message"); },
    exec() { throw new Error("adapter must not execute anything"); },
  });
  return handlers;
}

const handlers = await load(process.env.FM_HOME);
for (const name of ["session_start", "session_compact", "message_end"]) {
  if (!handlers.has(name)) throw new Error(`missing ${name} handler`);
}
const notifications = [];
const statuses = [];
const ctx = {
  mode: "tui",
  ui: {
    theme: { fg(_color, text) { return text; } },
    notify(message, type) { notifications.push({ message, type }); },
    setStatus(key, value) { statuses.push({ key, value }); },
  },
};
const assistant = (input, cacheRead = 0, cacheWrite = 0) => ({
  message: { role: "assistant", usage: { input, cacheRead, cacheWrite, output: 900_000, totalTokens: 900_000 + input + cacheRead + cacheWrite } },
});
const messageEnd = handlers.get("message_end");
messageEnd(assistant(40_000), ctx);
messageEnd(assistant(76_000), ctx);
messageEnd(assistant(80_000), ctx);
messageEnd(assistant(121_000), ctx);
messageEnd(assistant(161_000), ctx);
messageEnd(assistant(170_000), ctx);
if (notifications.length !== 3) throw new Error(`expected three notifications, got ${notifications.length}`);
if (!notifications[0].message.includes("76k. Context is getting large.")) throw new Error("75k wording missing");
if (!notifications[1].message.includes("121k. Compact at the next safe checkpoint.")) throw new Error("120k wording missing");
if (!notifications[2].message.includes("161k. Strongly recommend compacting")) throw new Error("160k wording missing");
if (!statuses.some(({ value }) => value === "Captain context: 161k")) throw new Error("status meter missing");
handlers.get("session_compact")({}, ctx);
if (statuses.at(-1).value !== undefined) throw new Error("compaction did not clear status");
messageEnd(assistant(76_000), ctx);
if (notifications.length !== 4) throw new Error("compaction did not re-arm warning");
if (messageEnd({ message: { role: "user" } }, ctx) !== undefined) throw new Error("user message was changed");
if (notifications.some(({ message }) => !message.startsWith("Captain context:"))) throw new Error("non-UI notification content");

const second = await load(process.env.FM_HOME, true);
if (second.size !== 0) throw new Error("secondmate registered context meter");
const unknown = await load(`${process.env.FM_HOME}-unknown`);
if (unknown.size !== 0) throw new Error("unconfirmed home registered context meter");
JS
  )
  status=$?
  [ "$status" -eq 0 ] || fail "Pi adapter failed: $out"
  [ -z "$out" ] || fail "Pi adapter printed output: $out"
  pass "Pi adapter is Captain-only, UI-only, and re-arms on Pi compaction"
}

test_meter_core
test_pi_adapter
