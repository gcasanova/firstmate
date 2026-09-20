import { createHash, randomBytes } from "node:crypto";
import { closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, unlinkSync, writeSync } from "node:fs";
import { join } from "node:path";

export const DEFAULT_TOOL_RESULT_THRESHOLD_BYTES = 10 * 1024;
export const DEFAULT_TOOL_RESULT_REPLACEMENT_BYTES = 5 * 1024;

function positiveByteLimit(value, fallback) {
  return Number.isSafeInteger(value) && value > 0 ? value : fallback;
}

function safeToolLabel(tool) {
  const normalized = String(tool).replace(/[^A-Za-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "");
  return normalized.slice(0, 48) || "tool";
}

function utf8Prefix(text, maxBytes) {
  const bytes = Buffer.from(text, "utf8");
  if (bytes.length <= maxBytes) return text;
  let end = maxBytes;
  while (end > 0 && (bytes[end] & 0xc0) === 0x80) end -= 1;
  return bytes.subarray(0, end).toString("utf8");
}

function utf8Suffix(text, maxBytes) {
  const bytes = Buffer.from(text, "utf8");
  if (bytes.length <= maxBytes) return text;
  let start = bytes.length - maxBytes;
  while (start < bytes.length && (bytes[start] & 0xc0) === 0x80) start += 1;
  return bytes.subarray(start).toString("utf8");
}

function buildReplacement(tool, text, originalBytes, archivePath, budget) {
  const header = [
    "[Firstmate bounded tool result]",
    `tool: ${tool}`,
    `original UTF-8 bytes: ${originalBytes}`,
    `archive: ${archivePath}`,
    "head:",
  ].join("\n");
  const footer = [
    "",
    "... [omitted; inspect the archive with targeted rg, sed, or a bounded read] ...",
    "tail:",
    "",
    "Inspect the archive with targeted rg, sed, or a bounded read.",
  ].join("\n");
  const fixedBytes = Buffer.byteLength(`${header}\n${footer}`, "utf8");
  const excerptBudget = Math.max(0, budget - fixedBytes);
  const headBudget = Math.floor(excerptBudget / 2);
  const tailBudget = excerptBudget - headBudget;
  return `${header}\n${utf8Prefix(text, headBudget)}${footer}${utf8Suffix(text, tailBudget)}`;
}

function fsyncDirectory(directory) {
  let fd;
  try {
    fd = openSync(directory, "r");
    fsyncSync(fd);
  } catch (error) {
    // Directory fsync is unavailable on some supported platforms and filesystems.
    if (!(error && typeof error === "object" && "code" in error && ["EINVAL", "ENOTSUP", "EPERM", "EISDIR"].includes(error.code))) {
      throw error;
    }
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

function writeDurableTempFile(path, text) {
  const bytes = Buffer.from(text, "utf8");
  const fd = openSync(path, "wx", 0o600);
  try {
    let offset = 0;
    while (offset < bytes.length) {
      const written = writeSync(fd, bytes, offset, bytes.length - offset);
      if (written <= 0) throw new Error("short write while archiving tool result");
      offset += written;
    }
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
}

/**
 * Bounds an oversized UTF-8 tool result by archiving it and returning a compact
 * model-facing replacement. Any filesystem error deliberately fails open.
 */
export function boundToolResult(request) {
  let thresholdBytes;
  let replacementBytes;
  let originalBytes;
  try {
    if (!request || typeof request.text !== "string") return { kind: "pass" };
    thresholdBytes = positiveByteLimit(request.thresholdBytes, DEFAULT_TOOL_RESULT_THRESHOLD_BYTES);
    replacementBytes = positiveByteLimit(request.replacementBytes, DEFAULT_TOOL_RESULT_REPLACEMENT_BYTES);
    originalBytes = Buffer.byteLength(request.text, "utf8");
  } catch {
    return { kind: "pass" };
  }
  if (originalBytes <= thresholdBytes) return { kind: "pass" };

  let tempPath;
  try {
    const correlation = typeof request.correlationId === "string" ? request.correlationId : "";
    const digest = createHash("sha256")
      .update(String(request.tool))
      .update("\0")
      .update(correlation)
      .update("\0")
      .update(request.text, "utf8")
      .digest("hex");
    const archivePath = join(request.archiveDir, `tool-result-${safeToolLabel(request.tool)}-${digest}.txt`);
    mkdirSync(request.archiveDir, { recursive: true, mode: 0o700 });

    if (existsSync(archivePath)) {
      if (!readFileSync(archivePath).equals(Buffer.from(request.text, "utf8"))) return { kind: "pass" };
    } else {
      tempPath = join(request.archiveDir, `.tool-result-${randomBytes(16).toString("hex")}.tmp`);
      writeDurableTempFile(tempPath, request.text);
      renameSync(tempPath, archivePath);
      tempPath = undefined;
      fsyncDirectory(request.archiveDir);
    }
    return {
      kind: "replace",
      archivePath,
      originalBytes,
      replacementText: buildReplacement(String(request.tool), request.text, originalBytes, archivePath, replacementBytes),
    };
  } catch {
    if (tempPath) {
      try { unlinkSync(tempPath); } catch {}
    }
    return { kind: "pass" };
  }
}
