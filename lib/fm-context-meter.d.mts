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

export type ContextMeterOptions = {
  notifiedTokens?: readonly number[];
};

export type ContextMeterState = {
  notifiedTokens: number[];
};

export type ContextMeter = {
  observe(tokens: number): (ContextThreshold & { message: string }) | null;
  reset(): void;
  snapshot(): ContextMeterState;
};

export const CONTEXT_THRESHOLDS: readonly ContextThreshold[];
export function promptContextTokens(usage: ContextUsage | unknown): number | null;
export function formatContextTokens(tokens: number): string;
export function createContextMeter(
  thresholds?: readonly ContextThreshold[],
  options?: ContextMeterOptions,
): ContextMeter;
