#!/usr/bin/env bash
# Sanity: bash binary works without JIT.
require_no_daemon=1

test_bash_basic() {
  section "Bash Basic Execution"

  if [[ ! -x "$BASH_BIN" ]]; then
    fail "bash not found at $BASH_BIN"
    return
  fi

  local result
  result=$("$BASH_BIN" -c 'echo "hello"' 2>&1)
  if [[ "$result" == "hello" ]]; then
    pass "bash works without BASH_JIT"
  else
    fail "bash basic execution failed: $result"
  fi

  result=$("$BASH_BIN" -c 'for i in $(seq 5); do echo "$i"; done' 2>&1)
  if [[ "$result" == "1
2
3
4
5" ]]; then
    pass "bash for loop works correctly"
  else
    fail "bash for loop failed: $result"
  fi
}
