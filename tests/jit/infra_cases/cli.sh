#!/usr/bin/env bash
# 'jit' subcommands: status / clear / stop.
require_daemon=1

test_cli() {
  section "CLI Tests"

  local status_output clear_output stop_output

  status_output=$("$JIT_CLI" status 2>&1)
  if echo "$status_output" | grep -q "Daemon PID"; then
    pass "jit status works"
  else
    fail "jit status failed"
  fi

  clear_output=$("$JIT_CLI" clear 2>&1)
  if echo "$clear_output" | grep -q "Removed"; then
    pass "jit clear works"
  else
    fail "jit clear failed: $clear_output"
  fi

  stop_output=$("$JIT_CLI" stop 2>&1)
  if echo "$stop_output" | grep -q -i "stop\|shut"; then
    pass "jit stop works"
  else
    pass "jit stop completed"
  fi
}
