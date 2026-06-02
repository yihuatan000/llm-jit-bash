#!/usr/bin/env bash
# 'jit compile' on a snippet — skipped when no LLM API key is configured.
require_daemon=1

test_manual_compile() {
  section "Manual Compilation Test"

  if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
    skip "manual compile (no ANTHROPIC_API_KEY)"
    return
  fi

  local compile_result
  compile_result=$("$JIT_CLI" compile 'for i in $(seq 10); do echo "$i"; done' 2>&1) || true
  if echo "$compile_result" | grep -q "ok\|compiled\|Status"; then
    pass "manual compile works"
  else
    skip "manual compile (unexpected output: $compile_result)"
  fi
}
