#!/usr/bin/env bash
# Bash function calls work under JIT.
require_daemon=1

test_functions() {
  section "Function Tests"

  local script
  script=$(make_script "test_func.sh" <<'EOF'
greet() {
    local name="$1"
    echo "Hello, $name!"
}

greet "World"
greet "JIT"
EOF
  )

  local result baseline
  baseline=$("$BASH_BIN" "$script" 2>&1)
  result=$(BASH_JIT=1 "$BASH_BIN" "$script" 2>&1)
  if [[ "$result" == "$baseline" ]]; then
    pass "function calls work correctly"
  else
    fail "function output differs with JIT (baseline=${#baseline} chars, jit=${#result} chars)"
    echo "    baseline: $baseline"
    echo "    jit:      $result"
  fi
}
