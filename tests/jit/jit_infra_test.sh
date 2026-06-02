#!/usr/bin/env bash
# jit_infra_test.sh -- infrastructure test suite for the bash JIT compiler.
#
# Each file in infra_cases/ is one test case. The runner sources it, reads the
# require_* declarations at the top, adjusts daemon state, and calls the
# test_<name> function derived from the filename.
#
# Usage:
#   ./tests/jit/jit_infra_test.sh                # run all infra cases
#   ./tests/jit/jit_infra_test.sh --list         # list cases
#   ./tests/jit/jit_infra_test.sh --test CASE    # run a single case
#   ./tests/jit/jit_infra_test.sh --verbose      # forward to cases (unused by default)
#
# --test accepts:
#   - bare name   e.g. "functions"          → infra_cases/functions.sh
#   - rel path    e.g. "infra_cases/pipe.sh"
#   - abs path    e.g. "/tmp/my_case.sh"

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASES_DIR="$SCRIPT_DIR/infra_cases"

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
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Resolve list of case files to run.
resolve_case_path() {
  local arg="$1"
  if [[ -f "$arg" ]]; then
    echo "$arg"
    return
  fi
  if [[ -f "$CASES_DIR/$arg" ]]; then
    echo "$CASES_DIR/$arg"
    return
  fi
  if [[ -f "$CASES_DIR/${arg%.sh}.sh" ]]; then
    echo "$CASES_DIR/${arg%.sh}.sh"
    return
  fi
  echo ""
}

CASES=()
while IFS= read -r f; do CASES+=("$f"); done < <(find "$CASES_DIR" -maxdepth 1 -type f -name '*.sh' | sort)

if [[ $LIST -eq 1 ]]; then
  echo "Infra test cases:"
  for f in "${CASES[@]}"; do
    local_name="${f##*/}"
    echo "  ${local_name%.sh}"
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

# ---- Daemon state tracking ----
# Current state: "unknown" | "running" | "stopped"
DAEMON_STATE="unknown"

ensure_daemon_stopped() {
  if [[ "$DAEMON_STATE" != "stopped" ]]; then
    daemon_stop
    DAEMON_STATE="stopped"
  fi
}

ensure_daemon_running() {
  if [[ "$DAEMON_STATE" != "running" ]]; then
    daemon_start
    DAEMON_STATE="running"
  fi
}

ensure_daemon_fresh() {
  daemon_clean_start
  DAEMON_STATE="running"
}

# ---- Run each case ----
for case_file in "${CASES[@]}"; do
  case_base="${case_file##*/}"
  case_name="${case_base%.sh}"
  func_name="test_$case_name"

  section "Case: $case_name"

  # Reset requirement declarations between cases.
  unset require_daemon require_no_daemon require_fresh_daemon require_llm 2>/dev/null || true

  # shellcheck disable=SC1090
  source "$case_file"

  # Apply requirements (order matters: fresh > no_daemon > daemon).
  if [[ "${require_fresh_daemon:-0}" == "1" ]]; then
    ensure_daemon_fresh
  elif [[ "${require_no_daemon:-0}" == "1" ]]; then
    ensure_daemon_stopped
  elif [[ "${require_daemon:-0}" == "1" ]]; then
    ensure_daemon_running
  fi

  if ! declare -F "$func_name" >/dev/null; then
    fail "$case_name (missing function $func_name)"
    continue
  fi

  # Per-case counters so we can report per-case summary; we still accumulate
  # global counters via pass/fail/skip from test_common.sh.
  local_pass_before=$PASS
  local_fail_before=$FAIL
  local_skip_before=$SKIP

  # Call the test function; don't let set -e propagate out (we didn't set it,
  # but be defensive).
  "$func_name" || true

  ran=$(( (PASS - local_pass_before) + (FAIL - local_fail_before) + (SKIP - local_skip_before) ))
  if [[ $ran -eq 0 ]]; then
    fail "$case_name (no pass/fail/skip recorded)"
  fi
done

# ---- Cleanup ----
daemon_stop 2>/dev/null || true

print_summary
