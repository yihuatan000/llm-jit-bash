#!/usr/bin/env bash
# Output redirection works under JIT.
require_daemon=1

test_redirects() {
  section "Redirect Tests"

  local outfile="$TMPDIR/redirect_output.txt"
  cat > "$TMPDIR/test_redirect.sh" <<EOF
for i in \$(seq 5); do echo "\$i"; done > "$outfile"
cat "$outfile"
EOF
  chmod +x "$TMPDIR/test_redirect.sh"

  local result expected
  result=$(BASH_JIT=1 "$BASH_BIN" "$TMPDIR/test_redirect.sh" 2>&1)
  expected=$(printf '%d\n' {1..5})
  if [[ "$result" == "$expected" ]]; then
    pass "redirects work correctly with JIT"
  else
    fail "redirect test failed: got '$result'"
  fi
}
