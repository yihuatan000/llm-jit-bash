#!/usr/bin/env bash
# Baseline performance check — bash runs a 1000-iter loop in <10s.
require_no_daemon=1

test_performance() {
  section "Performance Test"

  local script
  script=$(make_script "test_perf.sh" <<'EOF'
for i in $(seq 1000); do echo "item $i"; done
EOF
  )

  local start_time end_time bash_time_ms
  start_time=$(date +%s%N)
  "$BASH_BIN" "$script" > /dev/null 2>&1
  end_time=$(date +%s%N)
  bash_time_ms=$(( (end_time - start_time) / 1000000 ))

  echo "  Performance: ${bash_time_ms}ms for 1000-iteration loop"
  if [[ $bash_time_ms -lt 10000 ]]; then
    pass "performance within acceptable range (${bash_time_ms}ms < 10s)"
  else
    fail "performance too slow (${bash_time_ms}ms)"
  fi
}
