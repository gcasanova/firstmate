#!/usr/bin/env bash
# Focused behavior tests for Firstmate's shared tool-result bound and Pi adapter.
set -u

# This intentionally does not source tests/lib.sh: its process-identity fixture
# requires ps ancestry, while this pure Node test needs no process fixtures.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-tool-result-bound.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
expect_code() { [ "$1" -eq "$2" ] || fail "$3 (exit $2)"; }

run_node() {
  node --input-type=module 2>&1
}

test_core() {
  local out status
  out=$(FM_BOUND_ROOT="$ROOT" FM_BOUND_TMP="$TMP_ROOT/core" run_node <<'JS'
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
const { boundToolResult } = await import(`${process.env.FM_BOUND_ROOT}/lib/fm-tool-result-bound.mjs`);

const archiveDir = join(process.env.FM_BOUND_TMP, "archive");
const small = boundToolResult({ tool: "bash", text: "small", archiveDir });
if (small.kind !== "pass" || existsSync(archiveDir)) throw new Error("small result changed filesystem");

const original = `HEAD-${"a".repeat(12 * 1024)}-TAIL`;
const bounded = boundToolResult({ tool: "../../bash", text: original, archiveDir, replacementBytes: 1024, correlationId: "../../unsafe" });
if (bounded.kind !== "replace") throw new Error("oversized result was not replaced");
if (!readFileSync(bounded.archivePath).equals(Buffer.from(original))) throw new Error("archive differs from original");
if (Buffer.byteLength(bounded.replacementText, "utf8") > 1024) throw new Error("replacement exceeded budget");
for (const fragment of ["HEAD-", "-TAIL", "[omitted", "tool: ../../bash"]) {
  if (!bounded.replacementText.includes(fragment)) throw new Error(`replacement missing ${fragment}`);
}
if (bounded.archivePath.includes("..") || !/tool-result-bash-[a-f0-9]{64}\.txt$/.test(bounded.archivePath)) {
  throw new Error("archive filename was not safe");
}
const failed = boundToolResult({ tool: "bash", text: original, archiveDir: "/dev/null/tool-results" });
if (failed.kind !== "pass") throw new Error("archive failure did not fail open");
JS
  )
  status=$?
  [ "$status" -eq 0 ] || fail "tool-result core failed: $out"
  expect_code 0 "$status" "tool-result core behavior"
  [ -z "$out" ] || fail "tool-result core printed output: $out"
  pass "tool-result core archives exact oversized text and fails open"
}

test_pi_adapter() {
  local repo out status
  repo="$TMP_ROOT/pi"
  mkdir -p "$repo/.pi/extensions" "$repo/lib" "$repo/bin" "$repo/state" "$repo/private-state" "$repo/node_modules/@earendil-works/pi-coding-agent"
  : > "$repo/AGENTS.md"
  cp "$ROOT/.pi/extensions/fm-primary-tool-result-bound.ts" "$repo/.pi/extensions/"
  cp "$ROOT/lib/fm-tool-result-bound.mjs" "$ROOT/lib/fm-captain-scope.mjs" "$repo/lib/"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  : > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js"
  out=$(FM_HOME="$repo" FM_STATE_OVERRIDE="$repo/private-state" PLUGIN="$repo/.pi/extensions/fm-primary-tool-result-bound.ts" run_node <<'JS'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

async function load(home, marker = false) {
  if (marker) writeFileSync(`${home}/.fm-secondmate-home`, "mate\n");
  else if (existsSync(`${home}/.fm-secondmate-home`)) throw new Error("fixture marker leaked");
  let handler = null;
  const mod = await import(`${pathToFileURL(process.env.PLUGIN).href}?case=${Math.random()}`);
  mod.default({ on(name, candidate) { if (name === "tool_result") handler = candidate; } });
  return handler;
}
const text = "small bash";
let handler = await load(process.env.FM_HOME);
if (!handler) throw new Error("Captain adapter did not register");
const small = { toolName: "bash", toolCallId: "small", content: [{ type: "text", text }], isError: false, details: { exitCode: 7 } };
const smallPatch = handler(small, { sessionManager: { getSessionId: () => "captain-session" } });
if (smallPatch !== undefined || small.content[0].text !== text || small.details.exitCode !== 7) throw new Error("small bash changed");

for (const toolName of ["bash", "read"]) {
  const event = { toolName, toolCallId: `${toolName}-session`, content: [{ type: "text", text: `${toolName}-head-${"x".repeat(12 * 1024)}-${toolName}-tail` }], isError: true, details: { preserved: true } };
  const patch = handler(event, { sessionManager: { getSessionId: () => "captain-session" } });
  if (!patch || Object.keys(patch).length !== 1 || !patch.content[0].text.includes("[Firstmate bounded tool result]") || event.content[0].text.includes("[Firstmate bounded tool result]") || !event.isError || !event.details.preserved) throw new Error(`${toolName} was not bounded through a content-only return patch`);
  if (!patch.content[0].text.includes("/private-state/tool-results/captain-session/")) throw new Error("FM_STATE_OVERRIDE archive location was not used");
}
const nonText = { toolName: "bash", toolCallId: "image", content: [{ type: "image", data: "x", mimeType: "image/png" }], isError: false };
if (handler(nonText, {}) !== undefined || nonText.content[0].type !== "image") throw new Error("non-text changed");

const second = `${process.env.FM_HOME}-second`; writeFileSync(`${process.env.FM_HOME}/.fm-secondmate-home`, "mate\n");
handler = await load(process.env.FM_HOME, true);
if (handler) throw new Error("secondmate registered adapter");
process.env.FM_HOME = second;
handler = await load(process.env.FM_HOME);
if (handler) throw new Error("unconfirmed scope registered adapter");
JS
  )
  status=$?
  [ "$status" -eq 0 ] || fail "Pi adapter failed: $out"
  expect_code 0 "$status" "Pi Captain tool-result adapter behavior"
  [ -z "$out" ] || fail "Pi adapter printed output: $out"
  pass "Pi adapter bounds Captain bash/read text only and leaves secondmates unchanged"
}

test_core
test_pi_adapter
