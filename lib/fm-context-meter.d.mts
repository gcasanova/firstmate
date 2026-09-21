export type ContextUsage = {
  input: number;
  cacheRead: number;
  cacheWrite: number;
};

export type ContextThreshold = {
  tokens: number;
  level: "warning";
  advice: string;
};

export const CONTEXT_THRESHOLDS: readonly ContextThreshold[];
export function promptContextTokens(usage: ContextUsage | unknown): number | null;
export function formatContextTokens(tokens: number): string;
export function createContextMeter(thresholds?: readonly ContextThreshold[]): {
  observe(tokens: number): (ContextThreshold & { message: string }) | null;
  reset(): void;
};
