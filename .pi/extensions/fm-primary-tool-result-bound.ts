import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isConfirmedCaptainHome } from "../../lib/fm-captain-scope.mjs";
import { boundToolResult } from "../../lib/fm-tool-result-bound.mjs";

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../..");
const explicitFmHome = process.env.FM_HOME;
const fmHome = explicitFmHome || "";
const stateDir = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;

function archiveDirFor(sessionId: unknown): string {
  const session = typeof sessionId === "string" && /^[A-Za-z0-9_-]{1,96}$/.test(sessionId)
    ? sessionId
    : "unavailable";
  return `${stateDir}/tool-results/${session}`;
}

function sessionIdFromContext(context: unknown): unknown {
  try {
    const candidate = context as { sessionManager?: { getSessionId?: () => unknown } };
    return candidate.sessionManager?.getSessionId?.();
  } catch {
    return undefined;
  }
}

function textOnly(content: unknown): string | null {
  if (!Array.isArray(content) || content.length !== 1) return null;
  const [block] = content;
  if (!block || typeof block !== "object") return null;
  const candidate = block as { type?: unknown; text?: unknown };
  return candidate.type === "text" && typeof candidate.text === "string" ? candidate.text : null;
}

export default function registerFirstmatePrimaryToolResultBound(pi: ExtensionAPI): void {
  if (!isConfirmedCaptainHome({ fmHome: explicitFmHome, codeRoot: root, stateDir })) return;
  pi.on("tool_result", (event, context) => {
    if (event.toolName !== "bash" && event.toolName !== "read") return;
    const text = textOnly(event.content);
    if (text === null) return;
    const decision = boundToolResult({
      tool: event.toolName,
      text,
      archiveDir: archiveDirFor(sessionIdFromContext(context)),
      correlationId: event.toolCallId,
    });
    if (decision.kind === "replace") return { content: [{ type: "text", text: decision.replacementText }] };
  });
}
