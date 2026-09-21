#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
# Missing projects and legacy registry lines with no bracketed posture default
# to direct-PR; an explicit malformed or unsupported posture is an error.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (task-lifecycle).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> direct-PR off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (explicit opt-in)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: task-lifecycle
#                          owns its per-task resolution. Mechanical output maps
#                          it to no-mistakes so sync, seeding, and initialization
#                          preserve the explicitly configured pipeline capability.
# yolo (orthogonal) = merge authority only: when on, firstmate merges green,
#   in-scope work itself (AGENTS.md section 7).
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# An unknown or missing project falls back to "direct-PR off". An explicit
# malformed or unsupported mode is refused, so invalid configuration never
# silently changes delivery semantics.
# Usage: fm-project-mode.sh [--raw] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
if [ "${1:-}" = "--raw" ]; then
  RAW=1
  shift
fi
NAME=${1:?usage: fm-project-mode.sh [--raw] <project-name>}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to direct-PR off" >&2
  echo "direct-PR off"
  exit 0
fi

# awk emits "<mode> <yolo>" (one line) or nothing if the project is absent.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="direct-PR"; yolo="off";
    if ($3 ~ /^\[/) {
      s=""; closed=0;
      for (i=3; i<=NF; i++) {
        s = s (s==""?"":" ") $i;
        if ($i ~ /\]$/) { closed=1; break }
      }
      if (!closed) { print "__invalid__ unclosed bracketed delivery posture"; exit }
      gsub(/^\[|\]$/, "", s);
      k = split(s, a, " ");
      if (a[1] == "") { print "__invalid__ empty bracketed delivery posture"; exit }
      start=2;
      if (a[1] == "+yolo") { yolo="on"; start=2 } else mode=a[1];
      for (j=start; j<=k; j++) {
        if (a[j] == "+yolo" && yolo == "off") yolo="on";
        else { print "__invalid__ unsupported delivery posture token " a[j]; exit }
      }
    }
    print mode, yolo; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to direct-PR off" >&2
  echo "direct-PR off"
  exit 0
fi

mode=${parsed%% *}
yolo=${parsed#* }
if [ "$mode" = __invalid__ ]; then
  echo "error: invalid delivery mode configuration for $NAME: ${parsed#* }" >&2
  exit 2
fi
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "error: unsupported delivery mode \"$mode\" for $NAME" >&2; exit 2 ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
