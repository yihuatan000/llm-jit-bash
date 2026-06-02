#!/usr/bin/env bash
# eval/cd must not be JIT'd; for loops are eligible and must produce correct output.
require_daemon=1

test_eligibility() {
  section "Eligibility Tests"

  local script result expected first last

  script=$(make_script "test_eval.sh" <<'EOF'
eval 'echo "dynamic"'
EOF
  )
  result=$(BASH_JIT=1 "$BASH_BIN" "$script" 2>&1)
  if [[ "$result" == "dynamic" ]]; then
    pass "eval works correctly (not JIT'd)"
  else
    fail "eval execution failed: $result"
  fi

  script=$(make_script "test_cd.sh" <<'EOF'
cd /tmp && echo "in /tmp"
EOF
  )
  result=$(BASH_JIT=1 "$BASH_BIN" "$script" 2>&1)
  if [[ "$result" == "in /tmp" ]]; then
    pass "cd works correctly (not JIT'd)"
  else
    fail "cd execution failed: $result"
  fi

  script=$(make_script "test_for.sh" <<'EOF'
for i in $(seq 100); do echo "$i"; done
EOF
  )
  result=$(BASH_JIT=1 "$BASH_BIN" "$script" 2>&1)
  expected=$(printf '%d\n' {1..100})
  if [[ "$result" == "$expected" ]]; then
    pass "for loop produces correct output"
  else
    first=$(echo "$result" | head -1)
    last=$(echo "$result" | tail -1)
    if [[ "$first" == "1" && "$last" == "100" ]]; then
      pass "for loop produces correct output (verified endpoints)"
    else
      fail "for loop output incorrect: first=$first last=$last"
    fi
  fi
}
