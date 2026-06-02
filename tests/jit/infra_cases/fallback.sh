#!/usr/bin/env bash
# Bash still runs correctly when the daemon is absent (graceful fallback).
require_no_daemon=1

test_fallback() {
  section "Fallback Tests"

  daemon_stop

  local result expected
  result=$("$BASH_BIN" -c 'for i in $(seq 5); do echo "$i"; done' 2>&1)
  expected=$(printf '%d\n' {1..5})
  if [[ "$result" == "$expected" ]]; then
    pass "bash works after daemon stops (fallback)"
  else
    fail "fallback execution failed: $result"
  fi
}
