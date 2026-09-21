#!/usr/bin/env bash
# Focused synthetic tests for Codex PostToolUse Bash result bounding.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/bin/fm-codex-post-tool-use.mjs"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-tool-result-bound.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

run_event() { # <home> <fm-home-or-empty> <state-or-empty> <json>
  local home=$1 fm_home=$2 state=$3 payload=$4
  HOME="$home" FM_HOME="$fm_home" FM_STATE_OVERRIDE="$state" node "$RUNNER" <<<"$payload"
}

test_direct_codex() {
  local home="$TMP_ROOT/direct-home" payload out archive replacement
  mkdir -p "$home"
  payload='{"session_id":"direct-session","turn_id":"turn-1","tool_use_id":"small","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"printf small"},"tool_response":"small output","cwd":"/tmp","model":"test","permission_mode":"dontAsk","transcript_path":null}'
  out=$(run_event "$home" '' '' "$payload") || fail "small direct event failed"
  [ -z "$out" ] || fail "small Bash did not use Codex no-op output"

  # shellcheck disable=SC2016 # Node expands the quoted template literal, not the shell.
  payload=$(node -e 'process.stdout.write(JSON.stringify({session_id:"direct-session",turn_id:"turn-2",tool_use_id:"large",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"failing-command"},tool_response:`HEAD-${"x".repeat(12 * 1024)}-TAIL`,cwd:"/tmp",model:"test",permission_mode:"dontAsk",transcript_path:null}))')
  out=$(run_event "$home" '' '' "$payload") || fail "oversized direct event failed"
  node -e 'const value = JSON.parse(process.argv[1]); if (value.continue !== false || typeof value.systemMessage !== "string" || Object.keys(value).length !== 2) process.exit(1); if (Buffer.byteLength(value.systemMessage, "utf8") > 5 * 1024) process.exit(1); for (const text of ["original UTF-8 bytes: 12298", "HEAD-", "-TAIL", "[omitted", "archive:"]) if (!value.systemMessage.includes(text)) process.exit(1)' "$out" || fail "replacement was not valid bounded Codex feedback"
  archive=$(node -e 'const { resolve } = require("node:path"); process.stdout.write(resolve(process.argv[1], ".codex", "tool-results", "direct-session"))' "$home")
  [ -d "$archive" ] || fail "ordinary direct Codex archive was not created"
  [ "$(find "$archive" -type f | wc -l | tr -d ' ')" = 1 ] || fail "direct archive did not contain exactly one result"
  replacement=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).systemMessage)' "$out")
  grep -Fq "$archive/" <<<"$replacement" || fail "replacement did not name direct archive"
  grep -Fq 'HEAD-' "$archive"/* || fail "archive did not preserve exact head"
  grep -Fq -- '-TAIL' "$archive"/* || fail "archive did not preserve exact tail"
  pass "direct Codex passes small Bash and replaces oversized Bash with archived bounded feedback"
}

test_captain_and_workers() {
  local captain="$TMP_ROOT/captain" second="$TMP_ROOT/second" captain_runner payload out
  mkdir -p "$captain/bin" "$captain/lib" "$captain/state" "$captain/private-state" "$second/bin" "$second/state"
  : > "$captain/AGENTS.md"; : > "$second/AGENTS.md"; : > "$second/.fm-secondmate-home"
  cp "$RUNNER" "$captain/bin/"
  cp "$ROOT/lib/fm-captain-scope.mjs" "$ROOT/lib/fm-tool-result-bound.mjs" "$captain/lib/"
  captain_runner="$captain/bin/$(basename "$RUNNER")"
  # shellcheck disable=SC2016 # Node expands the quoted template literal, not the shell.
  payload=$(node -e 'process.stdout.write(JSON.stringify({session_id:"captain-session",turn_id:"turn-3",tool_use_id:"failed",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"false"},tool_response:`ERROR-HEAD-${"e".repeat(12 * 1024)}-ERROR-TAIL`,cwd:"/tmp",model:"test",permission_mode:"dontAsk",transcript_path:null}))')
  out=$(FM_HOME="$captain" FM_STATE_OVERRIDE="$captain/private-state" node "$captain_runner" <<<"$payload") || fail "captain failed Bash event failed"
  local captain_archive
  captain_archive=$(node -e 'const { resolve } = require("node:path"); process.stdout.write(resolve(process.argv[1], "tool-results", "captain-session"))' "$captain/private-state")
  grep -Fq "$captain_archive/" <<<"$out" || fail "captain did not use FM_STATE_OVERRIDE"
  grep -Fq 'ERROR-HEAD-' <<<"$out" || fail "failed Bash textual context was not retained"
  out=$(FM_HOME="$second" FM_STATE_OVERRIDE="$second/state" node "$captain_runner" <<<"$payload") || fail "secondmate event failed"
  [ -z "$out" ] || fail "confirmed secondmate was modified"
  [ ! -d "$second/state/tool-results" ] || fail "secondmate archive was created"
  out=$(FM_HOME="$TMP_ROOT/unconfirmed" node "$captain_runner" <<<"$payload") || fail "unconfirmed worker event failed"
  [ -z "$out" ] || fail "unconfirmed FM_HOME context was modified"
  pass "captain uses Firstmate state while secondmate and unconfirmed worker contexts pass through"
}

test_fail_open_and_validation() {
  local home="$TMP_ROOT/fail-home" payload out
  mkdir -p "$home"
  payload=$(node -e 'process.stdout.write(JSON.stringify({session_id:"bad-session",turn_id:"turn-4",tool_use_id:"archive-fail",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"echo"},tool_response:"x".repeat(12 * 1024),cwd:"/tmp",model:"test",permission_mode:"dontAsk",transcript_path:null}))')
  out=$(HOME=/dev/null FM_HOME='' node "$RUNNER" <<<"$payload") || fail "archive failure did not fail open"
  [ -z "$out" ] || fail "archive failure replaced original processing"
  out=$(run_event "$home" '' '' '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":42}') || fail "malformed event failed"
  [ -z "$out" ] || fail "malformed event was modified"
  out=$(run_event "$home" '' '' '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_response":"x"}') || fail "unsupported event failed"
  [ -z "$out" ] || fail "unsupported event was modified"
  pass "archive failures and malformed or unsupported events use exact Codex no-op behavior"
}

test_direct_codex
test_captain_and_workers
test_fail_open_and_validation
echo '# all fm-codex-tool-result-bound tests passed'
