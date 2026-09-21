#!/usr/bin/env bash
# Enforce the compact scout-report boundary before a scout result becomes a
# completed Firstmate artifact.
#
# Usage: fm-scout-report-check.sh --text <report.md>
#
# A scout may investigate broadly in private, but its durable handoff is at
# most 6 KiB. This prevents raw research output from becoming Captain context
# through the normal report-completion path. The research-routing procedure and
# report sections are owned by .agents/skills/task-lifecycle/SKILL.md.
set -eu

MAX_BYTES=6144

usage() {
  sed -n '2,8{s/^# \{0,1\}//;p;}' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --text)
    REPORT=${2:-}
    [ -n "$REPORT" ] || { echo "error: --text needs a report path" >&2; exit 2; }
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    ;;
  *) usage >&2; exit 2 ;;
esac

[ -f "$REPORT" ] || { echo "error: no such report: $REPORT" >&2; exit 2; }
BYTES=$(wc -c < "$REPORT" | tr -d ' ')

if [ "$BYTES" -gt "$MAX_BYTES" ]; then
  printf 'scout-report: FAIL - %s is %s bytes; compact handoffs may not exceed %s bytes.\n' \
    "$REPORT" "$BYTES" "$MAX_BYTES" >&2
  printf 'Archive detailed evidence separately and return only distilled findings with targeted references.\n' >&2
  exit 1
fi

printf 'scout-report: ok - %s bytes (limit %s)\n' "$BYTES" "$MAX_BYTES"
