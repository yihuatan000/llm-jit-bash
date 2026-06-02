#!/usr/bin/env bash
# Daemon starts and responds to status.
require_fresh_daemon=1

test_daemon_lifecycle() {
  section "Daemon Lifecycle"

  local status
  status=$("$JIT_CLI" status 2>&1)
  if echo "$status" | grep -q "Daemon PID"; then
    pass "daemon starts and responds to status"
  else
    fail "daemon status failed: $status"
  fi
}
