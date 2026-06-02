#!/usr/bin/env bash
# Non-exported variables are visible to the JIT-compiled snippet.
require_daemon=1

test_variable_injection() {
  section "Variable Injection Tests"

  local script
  script=$(make_script "test_vars.sh" <<'EOF'
PREFIX="hello"
for i in $(seq 5); do echo "$PREFIX: $i"; done
EOF
  )

  local result expected
  result=$(BASH_JIT=1 "$BASH_BIN" "$script" 2>&1)
  expected="hello: 1
hello: 2
hello: 3
hello: 4
hello: 5"
  if [[ "$result" == "$expected" ]]; then
    pass "variable injection works for non-exported variables"
  else
    fail "variable injection test failed: got '$result'"
  fi
}
