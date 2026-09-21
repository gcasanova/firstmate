import { CONTEXT_THRESHOLDS, createContextMeter, formatContextTokens } from "./fm-context-meter.mjs";

const RESET_MINIMUM_DROP = 40_000;
const RESET_MAXIMUM_RETAINED_FRACTION = 0.6;

function isFiniteNonNegative(value) {
  return typeof value === "number" && Number.isFinite(value) && value >= 0;
}

/**
 * Returns Claude Code's authoritative current-context estimate from a status-line payload.
 * Claude supplies the current window size and used percentage; session and billing totals are
 * deliberately ignored because they do not measure the current prompt context.
 */
export function claudeContextTokens(status) {
  if (!status || typeof status !== "object") return null;
  const context = status.context_window;
  if (!context || typeof context !== "object") return null;
  const { context_window_size: windowSize, used_percentage: usedPercentage } = context;
  if (!isFiniteNonNegative(windowSize) || !isFiniteNonNegative(usedPercentage) || usedPercentage > 100) return null;
  return Math.round(windowSize * usedPercentage / 100);
}

export function contextReset(previousTokens, currentTokens) {
  return isFiniteNonNegative(previousTokens)
    && isFiniteNonNegative(currentTokens)
    && previousTokens - currentTokens >= RESET_MINIMUM_DROP
    && currentTokens <= previousTokens * RESET_MAXIMUM_RETAINED_FRACTION;
}

function stateFrom(value) {
  if (!value || typeof value !== "object") return { notifiedTokens: [], lastTokens: null };
  return {
    notifiedTokens: Array.isArray(value.notifiedTokens) ? value.notifiedTokens : [],
    lastTokens: isFiniteNonNegative(value.lastTokens) ? value.lastTokens : null,
  };
}

/** Advances the shared meter using compact serializable state for short-lived status commands. */
export function observeClaudeContext(tokens, savedState) {
  if (!isFiniteNonNegative(tokens)) return null;
  const state = stateFrom(savedState);
  const meter = createContextMeter(CONTEXT_THRESHOLDS, { notifiedTokens: state.notifiedTokens });
  const reset = contextReset(state.lastTokens, tokens);
  if (reset) meter.reset();
  const warning = meter.observe(tokens);
  return {
    warning,
    reset,
    state: { ...meter.snapshot(), lastTokens: tokens },
    text: warning ? warning.message : `Captain context: ${formatContextTokens(tokens)}`,
  };
}
