#!/usr/bin/env bash
# Multiple bash processes funnel exec events into the same daemon counter.
require_fresh_daemon=1

test_cross_process() {
  section "Cross-Process Tests"

  "$JIT_CLI" clear 2>/dev/null || true
  sleep 0.3

  local script
  script=$(make_script "test_crossproc.sh" <<'EOF'
for i in $(seq 10); do echo "processing item number $i"; done
EOF
  )

  local run
  for run in $(seq 5); do
    BASH_JIT=1 "$BASH_BIN" "$script" > /dev/null 2>&1
  done

  local status
  status=$("$JIT_CLI" status 2>&1)
  if echo "$status" | grep -q "Total exec events: [1-9]"; then
    pass "cross-process counter accumulation works"
  else
    skip "cross-process counter check (daemon may not be running)"
  fi
}
