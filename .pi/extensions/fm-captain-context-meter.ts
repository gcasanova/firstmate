import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { isConfirmedCaptainHome } from "../../lib/fm-captain-scope.mjs";
import { createContextMeter, formatContextTokens, promptContextTokens } from "../../lib/fm-context-meter.mjs";

const STATUS_KEY = "firstmate-captain-context";
const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../..");
const explicitFmHome = process.env.FM_HOME;
const fmHome = explicitFmHome || "";
const stateDir = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;

function clearStatus(ctx: ExtensionContext): void {
  if (ctx.mode === "tui") ctx.ui.setStatus(STATUS_KEY, undefined);
}

export default function registerCaptainContextMeter(pi: ExtensionAPI): void {
  if (!isConfirmedCaptainHome({ fmHome: explicitFmHome, codeRoot: root, stateDir })) return;
  const meter = createContextMeter();

  pi.on("session_start", (_event, ctx) => {
    meter.reset();
    clearStatus(ctx);
  });

  pi.on("session_compact", (_event, ctx) => {
    meter.reset();
    clearStatus(ctx);
  });

  pi.on("message_end", (event, ctx) => {
    if (ctx.mode !== "tui" || event.message.role !== "assistant") return;
    const tokens = promptContextTokens(event.message.usage);
    if (tokens === null) return;

    ctx.ui.setStatus(STATUS_KEY, ctx.ui.theme.fg("dim", `Captain context: ${formatContextTokens(tokens)}`));
    const warning = meter.observe(tokens);
    if (warning) ctx.ui.notify(warning.message, warning.level);
  });
}
