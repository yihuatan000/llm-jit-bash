#!/usr/bin/env bash
# test_common.sh -- shared infrastructure for JIT test suites.
#
# Sourced by jit_infra_test.sh and jit_cached_tests.sh (not jit_llm_test.sh,
# which is data-driven and doesn't use pass/fail/skip).
#
# Provides:
#   - Counters and reporting: PASS/FAIL/SKIP, pass/fail/skip/section
#   - Path resolution: BASH_BIN, JIT_CLI, PROJECT_DIR
#   - Tmpdir: create_tmpdir / TMPDIR
#   - Daemon lifecycle: daemon_start/stop/restart/clean_start
#   - Test helpers: make_script, measure_ms, print_summary

# ---- Counters ----
PASS=0
FAIL=0
SKIP=0

pass()   { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail()   { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
skip()   { SKIP=$((SKIP + 1)); echo "  SKIP: $1"; }
section() { echo ""; echo "=== $1 ==="; }

# ---- Path resolution (idempotent) ----
TESTS_JIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_JIT_DIR/../.." && pwd)"
BASH_BIN="${BASH_BIN:-$HOME/local/bash-jit/bin/bash}"
JIT_CLI="${JIT_CLI:-$PROJECT_DIR/scripts/jit}"
DAEMON_PATH="${BASH_JIT_DAEMON:-$PROJECT_DIR/scripts/bash_jitd}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/bash_jit"

export BASH_BIN JIT_CLI PROJECT_DIR CACHE_DIR DAEMON_PATH

# ---- Tmpdir ----
TMPDIR=""

create_tmpdir() {
  TMPDIR=$(mktemp -d)
  trap 'rm -rf "$TMPDIR"' EXIT
}

# ---- Daemon lifecycle ----
# Uses JIT_DAEMON_CACHE_DIR for BASH_JIT_CACHE_DIR if set, else a tmpdir.
_ensure_daemon_cache_dir() {
  if [[ -z "${JIT_DAEMON_CACHE_DIR:-}" ]]; then
    JIT_DAEMON_CACHE_DIR=$(mktemp -d)
    export JIT_DAEMON_CACHE_DIR
  fi
}

daemon_start() {
  _ensure_daemon_cache_dir
  if ! BASH_JIT_CACHE_DIR="$JIT_DAEMON_CACHE_DIR" "$JIT_CLI" start >/dev/null; then
    echo "daemon_start: '$JIT_CLI start' exited non-zero" >&2
  fi
  sleep 0.5
}

daemon_stop() {
  "$JIT_CLI" stop 2>/dev/null || true
  # Wait for the socket to disappear (daemon fully exited). Without this,
  # `jit start` immediately after sees the stale socket and thinks the daemon
  # is still alive.
  local socket="$(_socket_path)"
  for _ in $(seq 1 30); do
    [[ -e "$socket" ]] || break
    sleep 0.1
  done
  # Also wait for the daemon to actually go offline.
  for _ in $(seq 1 10); do
    local s
    s=$("$JIT_CLI" status 2>&1)
    echo "$s" | grep -q "daemon not running" && break
    sleep 0.1
  done
}

_socket_path() {
  local runtime="${XDG_RUNTIME_DIR:-/tmp}"
  echo "$runtime/bash_jit_$(id -u)/socket"
}

daemon_restart() {
  daemon_stop
  daemon_start
}

daemon_clean_start() {
  daemon_stop
  rm -rf "/tmp/bash_jit_$(id -u)" 2>/dev/null || true
  JIT_DAEMON_CACHE_DIR=$(mktemp -d)
  export JIT_DAEMON_CACHE_DIR
  daemon_start
}

# ---- Test helpers ----

# make_script NAME: read stdin, write to $TMPDIR/NAME, chmod +x, echo path.
make_script() {
  local name="$1"
  local path="$TMPDIR/$name"
  cat > "$path"
  chmod +x "$path"
  echo "$path"
}

# measure_ms CMD...: run CMD, set TIME_MS to wall-clock milliseconds.
# Uses bash's built-in time with TIMEFORMAT for portability (no date +%s%N).
measure_ms() {
  local t
  TIMEFORMAT='%R'
  t=$( { time "$@" > /dev/null 2>&1; } 2>&1 )
  TIME_MS=$(python3 -c "print(int(${t} * 1000))")
}

# print_summary: print final counts and return appropriate exit code.
print_summary() {
  echo ""
  echo "=== Summary ==="
  local total=$((PASS + FAIL + SKIP))
  echo "Total: $total  Passed: $PASS  Failed: $FAIL  Skipped: $SKIP"
  if [[ $FAIL -eq 0 ]]; then
    echo "All tests passed!"
    return 0
  else
    echo "Some tests FAILED!"
    return 1
  fi
}
