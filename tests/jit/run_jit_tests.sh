#!/usr/bin/env bash
# run_jit_tests.sh -- run all three JIT test suites in sequence.
#
# Suites:
#   1. jit_infra_test.sh    -- infrastructure (always runs)
#   2. jit_cached_tests.sh  -- cached execution (always runs)
#   3. jit_llm_test.sh      -- LLM integration (skipped without API key)
#
# Exit code is 0 only if every suite that ran passed. A missing API key
# causes the LLM suite to be skipped (not a failure).
#
# Usage:
#   ./tests/jit/run_jit_tests.sh           # run all eligible suites
#   ./tests/jit/run_jit_tests.sh --verbose # forward --verbose to each suite

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --verbose|-v) ARGS+=(--verbose) ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg (only --verbose supported)" >&2; exit 2 ;;
  esac
done

# Aggregate counters across suites.
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
SUITES_PASSED=0
SUITES_FAILED=0
SUITES_SKIPPED=0

# Run a suite, surface its summary line, and update aggregates.
# Args: suite_name  suite_script
run_suite() {
  local name="$1"
  local script="$2"

  echo ""
  echo "################################################################"
  echo "# Suite: $name"
  echo "################################################################"

  local output rc
  output=$("$script" "${ARGS[@]}" 2>&1)
  rc=$?
  echo "$output"

  # Pull the "Total: ..." summary line (last one in the output).
  local summary
  summary=$(echo "$output" | grep '^Total:' | tail -1)

  if [[ -n "$summary" ]]; then
    local p f s
    p=$(echo "$summary" | sed -n 's/.*Passed:[[:space:]]*\([0-9]*\).*/\1/p')
    f=$(echo "$summary" | sed -n 's/.*Failed:[[:space:]]*\([0-9]*\).*/\1/p')
    s=$(echo "$summary" | sed -n 's/.*Skipped:[[:space:]]*\([0-9]*\).*/\1/p')
    TOTAL_PASS=$((TOTAL_PASS + ${p:-0}))
    TOTAL_FAIL=$((TOTAL_FAIL + ${f:-0}))
    TOTAL_SKIP=$((TOTAL_SKIP + ${s:-0}))
  fi

  if [[ $rc -eq 0 ]]; then
    SUITES_PASSED=$((SUITES_PASSED + 1))
  else
    SUITES_FAILED=$((SUITES_FAILED + 1))
  fi
}

# Skip LLM suite gracefully if there's no API key — running it would just
# produce a hard error from the suite itself.
llm_eligible=1
if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
  llm_eligible=0
fi

run_suite "infra"  "$SCRIPT_DIR/jit_infra_test.sh"
run_suite "cached" "$SCRIPT_DIR/jit_cached_tests.sh"

if [[ $llm_eligible -eq 1 ]]; then
  run_suite "llm" "$SCRIPT_DIR/jit_llm_test.sh"
else
  echo ""
  echo "################################################################"
  echo "# Suite: llm"
  echo "################################################################"
  echo "Skipping LLM suite — no ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN set."
  SUITES_SKIPPED=$((SUITES_SKIPPED + 1))
fi

# ---- Grand summary ----
echo ""
echo "################################################################"
echo "# Grand Summary"
echo "################################################################"
echo "Suites: passed=$SUITES_PASSED  failed=$SUITES_FAILED  skipped=$SUITES_SKIPPED"
echo "Tests:  passed=$TOTAL_PASS  failed=$TOTAL_FAIL  skipped=$TOTAL_SKIP"

if [[ $SUITES_FAILED -gt 0 ]] || [[ $TOTAL_FAIL -gt 0 ]]; then
  echo ""
  echo "Some tests FAILED!"
  exit 1
fi

echo ""
echo "All tests passed!"
exit 0
