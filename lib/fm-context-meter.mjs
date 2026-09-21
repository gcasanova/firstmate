export const CONTEXT_THRESHOLDS = Object.freeze([
  Object.freeze({ tokens: 75_000, level: "warning", advice: "Context is getting large." }),
  Object.freeze({ tokens: 120_000, level: "warning", advice: "Compact at the next safe checkpoint." }),
  Object.freeze({ tokens: 160_000, level: "warning", advice: "Strongly recommend compacting before more substantial work." }),
]);

function isTokenCount(value) {
  return typeof value === "number" && Number.isFinite(value) && value >= 0;
}

/** Returns effective prompt context, excluding generated output tokens. */
export function promptContextTokens(usage) {
  if (!usage || typeof usage !== "object") return null;
  const { input, cacheRead, cacheWrite } = usage;
  if (![input, cacheRead, cacheWrite].every(isTokenCount)) return null;
  return input + cacheRead + cacheWrite;
}

export function formatContextTokens(tokens) {
  if (!isTokenCount(tokens)) return "unknown";
  return `${Math.round(tokens / 1_000)}k`;
}

export function createContextMeter(thresholds = CONTEXT_THRESHOLDS) {
  const notified = new Set();

  return {
    observe(tokens) {
      if (!isTokenCount(tokens)) return null;
      const reached = thresholds.filter((threshold) => tokens >= threshold.tokens);
      if (reached.length === 0) return null;

      const highest = reached.at(-1);
      const shouldNotify = !notified.has(highest.tokens);
      for (const threshold of reached) notified.add(threshold.tokens);
      if (!shouldNotify) return null;
      return {
        ...highest,
        message: `Captain context: ${formatContextTokens(tokens)}. ${highest.advice}`,
      };
    },
    reset() {
      notified.clear();
    },
  };
}
