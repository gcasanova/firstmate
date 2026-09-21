#!/usr/bin/env bash
# Behavior tests for the compact scout-report handoff boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-scout-report-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-scout-report-contract)

test_compact_report_passes() {
  local report status=0
  report="$TMP_ROOT/compact.md"
  printf '# Findings\n\nConcise evidence and next action.\n' > "$report"
  "$CHECK" --text "$report" >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "a compact scout report must pass"
  pass "a compact scout report passes the handoff boundary"
}

test_oversized_report_is_rejected_without_echoing_it() {
  local report out status=0
  report="$TMP_ROOT/oversized.md"
  head -c 6145 /dev/zero | tr '\0' x > "$report"
  out=$("$CHECK" --text "$report" 2>&1) || status=$?
  expect_code 1 "$status" "an oversized scout report must be rejected"
  assert_contains "$out" "may not exceed 6144 bytes" "the refusal must name the compact handoff limit"
  assert_not_contains "$out" "xxxxxxxx" "the refusal must not forward raw report text"
  pass "oversized scout output is rejected without forwarding raw content"
}

test_non_report_invocation_refuses() {
  local out status=0
  out=$("$CHECK" --text "$TMP_ROOT/missing.md" 2>&1) || status=$?
  expect_code 2 "$status" "a missing scout report must refuse"
  assert_contains "$out" "no such report" "missing-report refusal must identify the contract input"
  pass "the report checker fails closed for a missing report"
}

test_compact_report_passes
test_oversized_report_is_rejected_without_echoing_it
test_non_report_invocation_refuses
