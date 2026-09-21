#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isConfirmedCaptainHome } from "../lib/fm-captain-scope.mjs";
import { boundToolResult } from "../lib/fm-tool-result-bound.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function safeSessionId(value) {
  return typeof value === "string" && /^[A-Za-z0-9_-]{1,96}$/.test(value)
    ? value
    : null;
}

function archiveDirFor(event) {
  const sessionId = safeSessionId(event.session_id);
  if (!sessionId) return null;

  const fmHome = process.env.FM_HOME || "";
  const stateDir = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
  if (fmHome && isConfirmedCaptainHome({ fmHome, codeRoot: root, stateDir })) {
    return `${stateDir}/tool-results/${sessionId}`;
  }
  if (fmHome) return null;
  return resolve(homedir(), ".codex", "tool-results", sessionId);
}

function readEvent() {
  try {
    const event = JSON.parse(readFileSync(0, "utf8"));
    if (!event || typeof event !== "object" || Array.isArray(event)) return null;
    if (event.hook_event_name !== "PostToolUse" || event.tool_name !== "Bash") return null;
    if (typeof event.tool_response !== "string") return null;
    if (typeof event.tool_use_id !== "string" || !event.tool_use_id) return null;
    return event;
  } catch {
    return null;
  }
}

const event = readEvent();
if (event) {
  const archiveDir = archiveDirFor(event);
  if (archiveDir) {
    const decision = boundToolResult({
      tool: "Bash",
      text: event.tool_response,
      archiveDir,
      correlationId: event.tool_use_id,
    });
    if (decision.kind === "replace") {
      process.stdout.write(`${JSON.stringify({ continue: false, systemMessage: decision.replacementText })}\n`);
    }
  }
}
