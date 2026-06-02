#!/usr/bin/env bash
# While loops work under JIT.
require_daemon=1

test_while_loops() {
  section "While Loop Tests"

  local script
  script=$(make_script "test_while.sh" <<'EOF'
i=0
while [ $i -lt 5 ]; do
    echo "iter $i"
    i=$((i + 1))
done
EOF
  )

  local result expected
  result=$(BASH_JIT=1 "$BASH_BIN" "$script" 2>&1)
  expected="iter 0
iter 1
iter 2
iter 3
iter 4"
  if [[ "$result" == "$expected" ]]; then
    pass "while loop works correctly"
  else
    fail "while loop test failed: got '$result'"
  fi
}
