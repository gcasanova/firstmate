#!/usr/bin/env node
import { lstatSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isConfirmedCaptainHome } from "../lib/fm-captain-scope.mjs";
import { claudeContextTokens, observeClaudeContext } from "../lib/fm-claude-context-meter.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const LOCK_STALE_MS = 60_000;

function readState(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return undefined;
  }
}

function writeState(path, state) {
  try {
    mkdirSync(dirname(path), { recursive: true });
    const temporary = `${path}.${process.pid}.tmp`;
    writeFileSync(temporary, `${JSON.stringify(state)}\n`, { encoding: "utf8", mode: 0o600 });
    renameSync(temporary, path);
    return true;
  } catch {
    return false;
  }
}

function isExistingDirectory(error) {
  return error && typeof error === "object" && "code" in error && error.code === "EEXIST";
}

function recoverStaleLock(lockPath) {
  let lock;
  try {
    lock = lstatSync(lockPath);
  } catch {
    return false;
  }
  if (!lock.isDirectory() || !Number.isFinite(lock.mtimeMs) || Date.now() - lock.mtimeMs < LOCK_STALE_MS) return false;
  try {
    rmSync(lockPath, { recursive: true, force: false });
    return true;
  } catch {
    return false;
  }
}

function acquireStateLock(lockPath) {
  try {
    mkdirSync(lockPath, { mode: 0o700 });
    return true;
  } catch (error) {
    if (!isExistingDirectory(error) || !recoverStaleLock(lockPath)) return false;
  }
  try {
    mkdirSync(lockPath, { mode: 0o700 });
    return true;
  } catch {
    return false;
  }
}

function withStateLock(path, action) {
  const lockPath = `${path}.lock`;
  if (!acquireStateLock(lockPath)) return null;
  try {
    return action();
  } finally {
    try {
      rmSync(lockPath, { recursive: true, force: true });
    } catch {
      // A later invocation may reclaim this lock only after its stale age.
    }
  }
}

function main(raw) {
  let status;
  try {
    status = JSON.parse(raw);
  } catch {
    return;
  }
  const fmHome = process.env.FM_HOME;
  const stateDir = process.env.FM_STATE_OVERRIDE || (typeof fmHome === "string" ? `${fmHome}/state` : "");
  if (!isConfirmedCaptainHome({ fmHome, codeRoot: root, stateDir })) return;
  const tokens = claudeContextTokens(status);
  if (tokens === null) return;
  const statePath = `${stateDir}/claude-context-meter.json`;
  const observation = withStateLock(statePath, () => {
    const next = observeClaudeContext(tokens, readState(statePath));
    return next && writeState(statePath, next.state) ? next : null;
  });
  if (!observation) return;
  process.stdout.write(observation.text);
}

try {
  main(readFileSync(0, "utf8"));
} catch {
  // A status line must fail inert: it is observational UI only.
}
