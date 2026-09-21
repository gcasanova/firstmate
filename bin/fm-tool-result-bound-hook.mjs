#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isConfirmedCaptainHome } from "../lib/fm-captain-scope.mjs";
import { boundToolResult } from "../lib/fm-tool-result-bound.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function archiveDirFor(stateDir, identifier) {
  const safeIdentifier = typeof identifier === "string" && /^[A-Za-z0-9_-]{1,96}$/.test(identifier)
    ? identifier
    : "unavailable";
  return `${stateDir}/tool-results/${safeIdentifier}`;
}

function textFromResult(toolName, result) {
  if (!result || typeof result !== "object") return null;
  if (toolName === "Bash") {
    if (typeof result.stdout !== "string" || typeof result.stderr !== "string") return null;
    if (result.interrupted !== false || (result.isImage !== undefined && result.isImage !== false)) return null;
    return result.stderr === "" ? result.stdout : `${result.stdout}\n[stderr]\n${result.stderr}`;
  }
  if (result.type !== "text" || !result.file || typeof result.file !== "object") return null;
  return typeof result.file.content === "string" ? result.file.content : null;
}

function replacementForResult(toolName, result, replacementText) {
  if (toolName === "Bash") return { ...result, stdout: replacementText, stderr: "" };
  if (result.type !== "text" || !result.file || typeof result.file !== "object") return null;
  return { ...result, file: { ...result.file, content: replacementText } };
}

function postToolUse(event) {
  if (!event || typeof event !== "object") return;
  if (event.hook_event_name !== "PostToolUse") return;
  if (event.tool_name !== "Bash" && event.tool_name !== "Read") return;

  const fmHome = process.env.FM_HOME;
  const stateDir = process.env.FM_STATE_OVERRIDE || (typeof fmHome === "string" ? `${fmHome}/state` : "");
  if (!isConfirmedCaptainHome({ fmHome, codeRoot: root, stateDir })) return;

  const text = textFromResult(event.tool_name, event.tool_response);
  if (text === null) return;
  const decision = boundToolResult({
    tool: event.tool_name.toLowerCase(),
    text,
    archiveDir: archiveDirFor(stateDir, event.session_id ?? event.tool_use_id),
    correlationId: event.tool_use_id,
  });
  if (decision.kind !== "replace") return;
  const replacement = replacementForResult(event.tool_name, event.tool_response, decision.replacementText);
  if (replacement === null) return;
  return { hookSpecificOutput: { hookEventName: "PostToolUse", updatedToolOutput: replacement } };
}

try {
  const output = postToolUse(JSON.parse(readFileSync(0, "utf8")));
  if (output) process.stdout.write(`${JSON.stringify(output)}\n`);
} catch {
  // A completed tool result must remain available on any uncertainty or failure.
}
