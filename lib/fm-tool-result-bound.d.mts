export type BoundRequest = {
  tool: string;
  text: string;
  archiveDir: string;
  thresholdBytes?: number;
  replacementBytes?: number;
  correlationId?: string;
};

export type BoundDecision =
  | { kind: "pass" }
  | { kind: "replace"; archivePath: string; originalBytes: number; replacementText: string };

export const DEFAULT_TOOL_RESULT_THRESHOLD_BYTES: number;
export const DEFAULT_TOOL_RESULT_REPLACEMENT_BYTES: number;
export function boundToolResult(request: BoundRequest): BoundDecision;
