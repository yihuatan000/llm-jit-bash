#!/usr/bin/env bash
# Pipelines work under JIT.
require_daemon=1

test_pipes() {
  section "Pipe Tests"

  local script
  script=$(make_script "test_pipe.sh" <<'EOF'
for i in $(seq 10); do echo "$i"; done | sort -rn | head -3
EOF
  )

  local result
  result=$(BASH_JIT=1 "$BASH_BIN" "$script" 2>&1)
  if [[ "$result" == "10
9
8" ]]; then
    pass "pipes work correctly with JIT"
  else
    fail "pipe test failed: got '$result'"
  fi
}
