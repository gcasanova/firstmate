#!/usr/bin/env bash
# Composes the Claude Code statusLine for a firstmate-home session.
#
# Registered in tracked .claude/settings.json as the statusLine command when
# FM_HOME is set. Claude Code's statusLine renders a single line, so this
# script reads the statusLine JSON payload from stdin once, feeds the same
# payload to both the user's own global statusLine command (read from
# $HOME/.claude/settings.json) and bin/fm-claude-context-status.mjs, and
# joins whichever of their outputs are non-empty. Either source is optional:
# a user with no global statusLine configured, or whose configured command
# fails or exits nonzero, still gets the firstmate meter alone, matching
# fm-claude-context-status.mjs's own fail-inert posture.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
payload="$(cat)"

global_command=""
if [ -n "${HOME:-}" ] && [ -r "$HOME/.claude/settings.json" ]; then
  global_command="$(jq -r '.statusLine.command // empty' "$HOME/.claude/settings.json" 2>/dev/null)"
fi

global_line=""
if [ -n "$global_command" ]; then
  global_line="$(printf '%s' "$payload" | bash -c "$global_command" 2>/dev/null)"
fi

fm_line="$(printf '%s' "$payload" | "$root"/bin/fm-claude-context-status.mjs 2>/dev/null)"

if [ -n "$global_line" ] && [ -n "$fm_line" ]; then
  printf '%s | %s\n' "$global_line" "$fm_line"
elif [ -n "$global_line" ]; then
  printf '%s\n' "$global_line"
elif [ -n "$fm_line" ]; then
  printf '%s\n' "$fm_line"
fi
exit 0
