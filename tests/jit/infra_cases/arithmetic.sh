#!/usr/bin/env bash
# Arithmetic for ((;;)) loops work under JIT.
require_daemon=1

test_arithmetic() {
  section "Arithmetic Tests"

  local script
  script=$(make_script "test_arith.sh" <<'EOF'
for ((i=0; i<10; i++)); do echo "$((i * i))"; done
EOF
  )

  local result expected
  result=$(BASH_JIT=1 "$BASH_BIN" "$script" 2>&1)
  expected=$(printf '%d\n' 0 1 4 9 16 25 36 49 64 81)
  if [[ "$result" == "$expected" ]]; then
    pass "arithmetic for loop works correctly"
  else
    fail "arithmetic test failed: got '$result'"
  fi
}
