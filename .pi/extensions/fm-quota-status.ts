// Firstmate's live Pi quota footer status.
//
// The stock footer's context percentage is session context consumption, not vendor
// quota. This extension keeps the stock footer and adds every quota-axi window for
// the active Pi provider, refreshed from a passive read every 30 seconds.
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";

type QuotaWindow = {
  id?: string;
  label?: string;
  kind?: string;
  percentRemaining?: number;
  resetsAt?: string;
};

type QuotaProvider = {
  provider?: string;
  windows?: QuotaWindow[];
  state?: {
    status?: string;
    stale?: boolean;
  };
};

type QuotaResponse = {
  providers?: QuotaProvider[];
};

const STATUS_KEY = "firstmate-quota";
const DEFAULT_REFRESH_MS = 30_000;
const PROVIDER_MAP: Readonly<Record<string, string>> = {
  anthropic: "claude",
  claude: "claude",
  "openai-codex": "codex",
  codex: "codex",
  cursor: "cursor",
  "github-copilot": "copilot",
  copilot: "copilot",
  grok: "grok",
  kimi: "kimi",
  zai: "zai",
  "opencode-go": "opencode-go",
};

function quotaProviderFor(ctx: ExtensionContext): string | undefined {
  const provider = ctx.model?.provider;
  return provider ? PROVIDER_MAP[provider] : undefined;
}

function windowLabel(window: QuotaWindow): string {
  if (window.id === "five_hour") return "5h";
  if (window.id === "weekly") return "week";
  return (window.label || window.kind || window.id || "quota").replaceAll("_", " ");
}

function resetLabel(resetsAt: string | undefined): string | undefined {
  if (!resetsAt) return undefined;
  const reset = new Date(resetsAt);
  if (!Number.isFinite(reset.getTime())) return undefined;
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const hour = String(reset.getHours()).padStart(2, "0");
  const minute = String(reset.getMinutes()).padStart(2, "0");
  return `${months[reset.getMonth()]}${reset.getDate()} ${hour}:${minute}`;
}

function statusText(ctx: ExtensionContext, provider: QuotaProvider): string {
  const windows = (provider.windows ?? []).filter(
    (window): window is QuotaWindow & { percentRemaining: number } =>
      typeof window.percentRemaining === "number" && Number.isFinite(window.percentRemaining),
  );
  if (windows.length === 0) return ctx.ui.theme.fg("dim", "quota unavailable");

  const stale = provider.state?.stale === true ? "~" : "";
  const parts = windows.map((window) => {
    const used = 100 - Math.max(0, Math.min(100, Math.round(window.percentRemaining)));
    const color: "error" | "warning" | "success" =
      used >= 90 ? "error" : used >= 75 ? "warning" : "success";
    const reset = resetLabel(window.resetsAt);
    return (
      ctx.ui.theme.fg("dim", `${windowLabel(window)} `) +
      ctx.ui.theme.fg(color, `${stale}${used}%`) +
      (reset ? ctx.ui.theme.fg("dim", ` ↻${reset}`) : "")
    );
  });
  return ctx.ui.theme.fg("dim", "quota used ") + parts.join(ctx.ui.theme.fg("dim", " · "));
}

export default function (pi: ExtensionAPI) {
  let active = false;
  let timer: ReturnType<typeof setInterval> | undefined;
  let latestContext: ExtensionContext | undefined;
  let refreshRunning = false;
  let refreshRequested = false;

  const refresh = async (): Promise<void> => {
    if (!active || refreshRunning || !latestContext) return;
    refreshRunning = true;
    try {
      do {
        refreshRequested = false;
        const ctx = latestContext;
        const providerName = quotaProviderFor(ctx);
        if (!providerName) {
          ctx.ui.setStatus(STATUS_KEY, undefined);
          continue;
        }

        const result = await pi.exec(
          "quota-axi",
          ["--provider", providerName, "--json", "--no-credential-refresh"],
          { timeout: 15_000 },
        );
        if (!active || ctx !== latestContext) {
          refreshRequested = active;
          continue;
        }
        if (result.code !== 0) {
          ctx.ui.setStatus(STATUS_KEY, ctx.ui.theme.fg("dim", "quota unavailable"));
          continue;
        }

        try {
          const response = JSON.parse(result.stdout) as QuotaResponse;
          const provider = response.providers?.find((candidate) => candidate.provider === providerName);
          ctx.ui.setStatus(
            STATUS_KEY,
            provider
              ? statusText(ctx, provider)
              : ctx.ui.theme.fg("dim", "quota unavailable"),
          );
        } catch {
          ctx.ui.setStatus(STATUS_KEY, ctx.ui.theme.fg("dim", "quota unavailable"));
        }
      } while (active && refreshRequested);
    } finally {
      refreshRunning = false;
    }
  };

  const requestRefresh = (ctx: ExtensionContext): void => {
    latestContext = ctx;
    refreshRequested = true;
    void refresh();
  };

  pi.on("session_start", (_event, ctx) => {
    if (ctx.mode !== "tui") return;
    active = true;
    requestRefresh(ctx);
    timer = setInterval(() => {
      if (latestContext) requestRefresh(latestContext);
    }, DEFAULT_REFRESH_MS);
  });

  pi.on("model_select", (_event, ctx) => {
    if (!active || ctx.mode !== "tui") return;
    requestRefresh(ctx);
  });

  pi.on("session_shutdown", (_event, ctx) => {
    active = false;
    refreshRequested = false;
    latestContext = undefined;
    if (timer) clearInterval(timer);
    timer = undefined;
    ctx.ui.setStatus(STATUS_KEY, undefined);
  });
}
