#!/usr/bin/env bash
# Same script run twice with BASH_JIT=1 should produce identical output.
require_daemon=1

test_fingerprint_consistency() {
  section "Fingerprint Consistency"

  "$JIT_CLI" clear 2>/dev/null || true

  local script
  script=$(make_script "test_script.sh" <<'EOF'
for i in $(seq 10); do echo "item $i"; done
EOF
  )

  local expected result1 result2
  expected=$(printf 'item %d\n' {1..10})

  result1=$(BASH_JIT=1 "$BASH_BIN" "$script" 2>&1)
  if [[ "$result1" == "$expected" ]]; then
    pass "script produces correct output with BASH_JIT=1"
  else
    fail "script output mismatch with BASH_JIT=1: $result1"
  fi

  result2=$(BASH_JIT=1 "$BASH_BIN" "$script" 2>&1)
  if [[ "$result1" == "$result2" ]]; then
    pass "script produces consistent output across runs"
  else
    fail "output differs between runs"
  fi
}
