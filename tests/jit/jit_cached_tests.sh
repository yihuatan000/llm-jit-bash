#!/usr/bin/env bash
# jit_cached_tests.sh -- JIT smoke tests with BASH_JIT=1 enabled.
#
# Each *.sh file in cached_cases/ is treated as a bash script. The runner
# executes each under our JIT-enabled bash, captures output, and compares it
# against running the same script with JIT disabled. The two outputs must
# match — this catches cases where the JIT path corrupts execution.
#
# Usage:
#   ./tests/jit/jit_cached_tests.sh                # run all
#   ./tests/jit/jit_cached_tests.sh --list         # list cases
#   ./tests/jit/jit_cached_tests.sh --test CASE    # single case (name / rel / abs)
#   ./tests/jit/jit_cached_tests.sh --verbose      # print extra detail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASES_DIR="$SCRIPT_DIR/cached_cases"

# shellcheck source=lib/test_common.sh
source "$SCRIPT_DIR/lib/test_common.sh"

VERBOSE=0
SINGLE=""
LIST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list|-l)    LIST=1; shift ;;
    --test|-t)    SINGLE="$2"; shift 2 ;;
    --verbose|-v) VERBOSE=1; shift ;;
    -h|--help)    sed -n '2,14p' "$0"; exit 0 ;;
    *)            echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -x "$BASH_BIN" ]]; then
  echo "ERROR: bash not found at $BASH_BIN" >&2
  exit 1
fi

resolve_case_path() {
  local arg="$1"
  if [[ -f "$arg" ]]; then
    echo "$arg"; return
  fi
  if [[ -f "$CASES_DIR/$arg" ]]; then
    echo "$CASES_DIR/$arg"; return
  fi
  if [[ -f "$CASES_DIR/${arg%.sh}.sh" ]]; then
    echo "$CASES_DIR/${arg%.sh}.sh"; return
  fi
  echo ""
}

CASES=()
while IFS= read -r f; do CASES+=("$f"); done < <(find "$CASES_DIR" -maxdepth 1 -type f -name '*.sh' | sort)

if [[ $LIST -eq 1 ]]; then
  echo "Cached test cases:"
  for f in "${CASES[@]}"; do
    echo "  ${f##*/}"
  done
  exit 0
fi

if [[ -n "$SINGLE" ]]; then
  resolved=$(resolve_case_path "$SINGLE")
  if [[ -z "$resolved" ]]; then
    echo "ERROR: case not found: $SINGLE" >&2
    exit 2
  fi
  CASES=("$resolved")
fi

create_tmpdir

# ---- Setup: start daemon ----
section "Setup"
daemon_start
status=$("$JIT_CLI" status 2>&1)
if echo "$status" | grep -q "Daemon PID"; then
  pass "daemon started"
else
  fail "daemon failed to start"
  exit 1
fi

# ---- Run each cached case ----
section "Cached Execution Tests"

run_cached_case() {
  local case_path="$1"
  local case_file="${case_path##*/}"
  local case_name="${case_file%.sh}"

  echo "  Testing: $case_name"

  # Run with JIT disabled → baseline output.
  local baseline jit_out base_rc jit_rc
  baseline=$("$BASH_BIN" "$case_path" 2>&1)
  base_rc=$?
  if [[ $base_rc -ne 0 ]]; then
    fail "$case_name (baseline failed rc=$base_rc)"
    return
  fi

  # Run with JIT enabled — output must match baseline.
  jit_out=$(BASH_JIT=1 BASH_JIT_DAEMON="$DAEMON_PATH" "$BASH_BIN" "$case_path" 2>&1)
  jit_rc=$?

  if [[ $VERBOSE -eq 1 ]]; then
    echo "    baseline (rc=$base_rc, ${#baseline} chars):"
    echo "$baseline" | sed 's/^/      /'
    echo "    jit_out (rc=$jit_rc, ${#jit_out} chars):"
    echo "$jit_out" | sed 's/^/      /'
  fi

  if [[ "$baseline" != "$jit_out" ]]; then
    fail "$case_name (output differs with BASH_JIT=1)"
    return
  fi
  if [[ $jit_rc -ne 0 ]]; then
    fail "$case_name (JIT run returned rc=$jit_rc)"
    return
  fi

  pass "$case_name (output identical with/without JIT)"
}

for case_file in "${CASES[@]}"; do
  run_cached_case "$case_file"
done

# ---- Cache structure sanity check ----
section "Cache Structure Test"

cache_count=$(find "$JIT_DAEMON_CACHE_DIR" -maxdepth 1 -type d 2>/dev/null | wc -l)
# Subtract 1 for the cache root itself.
cache_entries=$((cache_count > 0 ? cache_count - 1 : 0))
echo "  Cache entries after run: $cache_entries"
echo "  Cache dir: $JIT_DAEMON_CACHE_DIR"

# At least the daemon's counters file should exist; we don't strictly require
# cache entries (some snippets may not be eligible for JIT).
if [[ -d "$JIT_DAEMON_CACHE_DIR" ]]; then
  pass "cache directory exists"
else
  fail "cache directory missing"
fi

# ---- Cleanup ----
section "Cleanup"
daemon_stop

print_summary
