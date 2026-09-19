#!/usr/bin/env bash
# Focused lifecycle and rendering checks for the live Pi quota footer status.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXT="$ROOT/.pi/extensions/fm-quota-status.ts"

run_extension_test() {
  local out status
  out=$(TZ=UTC EXT="$EXT" node --experimental-strip-types --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";

let intervalCallback;
let intervalCleared = false;
globalThis.setInterval = (callback, milliseconds) => {
  if (milliseconds !== 30000) throw new Error(`unexpected refresh cadence: ${milliseconds}`);
  intervalCallback = callback;
  return 1;
};
globalThis.clearInterval = () => {
  intervalCleared = true;
};

const handlers = new Map();
const statuses = [];
const calls = [];
let sample = 0;
const payloads = [
  {
    providers: [{
      provider: "codex",
      windows: [
        { id: "five_hour", label: "session", percentRemaining: 49, resetsAt: "2026-08-31T18:23:00.000Z" },
        { id: "weekly", label: "week", percentRemaining: 89, resetsAt: "2026-09-07T07:54:18.000Z" },
      ],
      state: { status: "fresh", stale: false },
    }],
  },
  {
    providers: [{
      provider: "codex",
      windows: [
        { id: "five_hour", label: "session", percentRemaining: 48.4, resetsAt: "2026-08-31T18:23:00.000Z" },
        { id: "weekly", label: "week", percentRemaining: 88.2, resetsAt: "2026-09-07T07:54:18.000Z" },
      ],
      state: { status: "fresh", stale: false },
    }],
  },
];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async exec(command, args, options) {
    calls.push({ command, args, options });
    const payload = payloads[Math.min(sample, payloads.length - 1)];
    sample += 1;
    return { code: 0, stdout: JSON.stringify(payload), stderr: "", killed: false };
  },
};
const context = {
  mode: "tui",
  model: { provider: "openai-codex", id: "gpt-test" },
  ui: {
    theme: { fg(_color, text) { return text; } },
    setStatus(key, value) { statuses.push({ key, value }); },
  },
};

const extension = await import(`${pathToFileURL(process.env.EXT).href}?test=${Date.now()}`);
extension.default(pi);
for (const event of ["session_start", "model_select", "session_shutdown"]) {
  if (!handlers.has(event)) throw new Error(`missing ${event} handler`);
}

handlers.get("session_start")({ reason: "startup" }, context);
for (let i = 0; i < 100 && !statuses.some((entry) => entry.value === "quota used 5h 51% ↻Aug31 18:23 · week 11% ↻Sep7 07:54"); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 2));
}
if (!statuses.some((entry) => entry.key === "firstmate-quota" && entry.value === "quota used 5h 51% ↻Aug31 18:23 · week 11% ↻Sep7 07:54")) {
  throw new Error(`initial multi-window footer missing: ${JSON.stringify(statuses)}`);
}
if (!intervalCallback) throw new Error("quota refresh interval was not installed");
intervalCallback();
for (let i = 0; i < 100 && !statuses.some((entry) => entry.value === "quota used 5h 52% ↻Aug31 18:23 · week 12% ↻Sep7 07:54"); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 2));
}
if (!statuses.some((entry) => entry.value === "quota used 5h 52% ↻Aug31 18:23 · week 12% ↻Sep7 07:54")) {
  throw new Error(`periodic quota refresh missing: ${JSON.stringify(statuses)}`);
}
if (calls.some((call) =>
  call.command !== "quota-axi" ||
  JSON.stringify(call.args) !== JSON.stringify(["--provider", "codex", "--json", "--no-credential-refresh"]) ||
  call.options?.timeout !== 15000
)) {
  throw new Error(`unexpected quota command: ${JSON.stringify(calls)}`);
}

context.model = { provider: "unsupported", id: "other" };
handlers.get("model_select")({ model: context.model, source: "set" }, context);
for (let i = 0; i < 100 && statuses.at(-1)?.value !== undefined; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 2));
}
if (statuses.at(-1)?.key !== "firstmate-quota" || statuses.at(-1)?.value !== undefined) {
  throw new Error(`unsupported provider did not clear quota status: ${JSON.stringify(statuses.at(-1))}`);
}

handlers.get("session_shutdown")({ reason: "quit" }, context);
if (!intervalCleared) throw new Error("quota refresh interval survived session shutdown");
const callsAfterShutdown = calls.length;
intervalCallback();
await new Promise((resolve) => setTimeout(resolve, 5));
if (calls.length !== callsAfterShutdown) {
  throw new Error("quota refresh continued after session shutdown");
}
JS
)
  status=$?
  [ "$status" -eq 0 ] || fail "Pi quota footer lifecycle failed: $out"
  [ -z "$out" ] || fail "Pi quota footer test printed output: $out"
  pass "Pi quota footer shows and refreshes every active-provider window, switches safely, and stops with the session"
}

run_extension_test
