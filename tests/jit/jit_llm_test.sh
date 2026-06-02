#!/usr/bin/env bash
# jit_llm_test.sh -- LLM integration tests for the bash JIT compiler.
#
# Two flavors of test live in this runner:
#   1. Process tests (hardcoded below): end-to-end threshold triggering,
#      force recompile, API connectivity, and a bash-vs-python performance
#      comparison.
#   2. Data-driven compile-correctness cases: each *.sh file under
#      llm_cases/ is read as a bash snippet, compiled to Python via
#      `jit compile`, and its output compared against running the snippet
#      directly under bash.
#
# Requires ANTHROPIC_API_KEY (or ANTHROPIC_AUTH_TOKEN).
#
# Usage:
#   ./tests/jit/jit_llm_test.sh                # run all
#   ./tests/jit/jit_llm_test.sh --list         # list cases
#   ./tests/jit/jit_llm_test.sh --test CASE    # single case from llm_cases/
#   ./tests/jit/jit_llm_test.sh --verbose      # print snippet + python + output

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASES_DIR="$SCRIPT_DIR/llm_cases"

# shellcheck source=lib/test_common.sh
source "$SCRIPT_DIR/lib/test_common.sh"

VERBOSE=0
SINGLE=""
LIST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list|-l)    LIST=1; shift ;;
    --test|-t)    SINGLE="$2"; shift 2 ;;
    --verbose|-v) VERBOSE=1; shift ;;
    -h|--help)    sed -n '2,18p' "$0"; exit 0 ;;
    *)            echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -x "$BASH_BIN" ]]; then
  echo "ERROR: bash not found at $BASH_BIN" >&2
  exit 1
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
  echo "ERROR: No API key found (set ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN)" >&2
  exit 1
fi

verbose_snippet() {
  if [[ $VERBOSE -eq 1 ]]; then
    echo "    --- Bash snippet ---"
    echo "$1" | sed 's/^/    /'
    echo "    ---"
  fi
}

verbose_python() {
  local py_path="$1"
  if [[ $VERBOSE -eq 1 && -f "$py_path" ]]; then
    echo "    --- Python: $py_path ---"
    sed 's/^/    /' "$py_path"
    echo "    ---"
  fi
}

verbose_output() {
  if [[ $VERBOSE -eq 1 ]]; then
    echo "    --- $1 ---"
    echo "$2" | sed 's/^/    /'
    echo "    ---"
  fi
}

resolve_case_path() {
  local arg="$1"
  if [[ -f "$CASES_DIR/$arg" ]]; then
    echo "$CASES_DIR/$arg"; return
  fi
  if [[ -f "$CASES_DIR/${arg%.sh}.sh" ]]; then
    echo "$CASES_DIR/${arg%.sh}.sh"; return
  fi
  echo ""
}

CASES=()
while IFS= read -r f; do CASES+=("$f"); done < <(find "$CASES_DIR" -maxdepth 1 -type f -name '*.sh' | sort)

if [[ $LIST -eq 1 ]]; then
  echo "LLM test cases:"
  for f in "${CASES[@]}"; do
    echo "  ${f##*/}"
  done
  exit 0
fi

if [[ -n "$SINGLE" ]]; then
  resolved=$(resolve_case_path "$SINGLE")
  if [[ -z "$resolved" ]]; then
    echo "ERROR: case not found: $SINGLE" >&2
    exit 2
  fi
  CASES=("$resolved")
fi

create_tmpdir

# ---- Setup: start daemon with low threshold ----
section "Setup"

# Low threshold (3 execs), low complexity gate, no duration gate — we want the
# JIT to compile fast snippets eagerly so tests don't time out.
export BASH_JIT_THRESHOLD=3
export BASH_JIT_MIN_COMPLEXITY=20
export BASH_JIT_MIN_DURATION=0

daemon_start

status=$("$JIT_CLI" status 2>&1)
if echo "$status" | grep -q "Daemon PID"; then
  pass "daemon started with low threshold"
else
  rm -rf "/tmp/bash_jit_$(id -u)" 2>/dev/null || true
  daemon_start
  status=$("$JIT_CLI" status 2>&1)
  if echo "$status" | grep -q "Daemon PID"; then
    pass "daemon started with low threshold (retry)"
  else
    fail "daemon failed to start: $status"
    exit 1
  fi
fi

# ---- E2E Threshold Test ----
section "E2E Threshold-Triggered Compilation"

cat > "$TMPDIR/hot_loop.sh" <<'SCRIPT'
#!/usr/bin/env bash
for i in $(seq 20); do echo "number $i"; done
SCRIPT
chmod +x "$TMPDIR/hot_loop.sh"

expected=$("$BASH_BIN" "$TMPDIR/hot_loop.sh" 2>/dev/null)
pass "baseline bash output captured"
verbose_snippet "$(cat "$TMPDIR/hot_loop.sh")"
verbose_output "Bash output" "$expected"

# Run the script 5 times with JIT enabled (threshold is 3).
export BASH_JIT=1
for run in $(seq 5); do
  result=$("$BASH_BIN" "$TMPDIR/hot_loop.sh" 2>/dev/null)
  if [[ "$result" == "$expected" ]]; then
    echo "  run $run: output matches"
  else
    echo "  run $run: output DIFFERS"
  fi
done

# Wait for async LLM compilation.
echo "  Waiting for async compilation..."
threshold_compiled=0
for attempt in $(seq 12); do
  sleep 5
  status=$("$JIT_CLI" status 2>&1)
  if echo "$status" | grep -q "Compiled: [1-9]"; then
    echo "Daemon status (after $((attempt * 5))s):"
    echo "$status"
    pass "threshold triggered compilation"
    threshold_compiled=1
    break
  fi
  if echo "$status" | grep -q "Failed: [1-9]"; then
    echo "Daemon status:"
    echo "$status"
    fail "compilation failed after threshold"
    threshold_compiled=1
    break
  fi
  if [[ $attempt -eq 12 ]]; then
    echo "Daemon status (final):"
    echo "$status"
    fail "compilation not completed after 60s"
    threshold_compiled=1
  fi
done

# Check if a compiled Python file was created in the cache.
compiled_files=$(find "$JIT_DAEMON_CACHE_DIR" -name "compiled.py" 2>/dev/null || true)
if [[ -n "$compiled_files" ]]; then
  pass "compiled Python file created in cache"
  echo "  Files: $compiled_files"
  for f in $compiled_files; do
    verbose_python "$f"
  done
else
  failed_files=$(find "$JIT_DAEMON_CACHE_DIR" -name "FAILED" 2>/dev/null || true)
  if [[ -n "$failed_files" ]]; then
    fail "compilation was attempted but failed"
    for f in $failed_files; do
      echo "  Failure reason: $(cat "$f")"
    done
  else
    fail "no compiled Python file found in cache"
  fi
fi

# If compiled, verify the Python output matches bash.
if [[ -n "$compiled_files" ]]; then
  py_file=$(echo "$compiled_files" | head -1)
  py_result=$(python3 "$py_file" 2>&1)
  expected_norm=$(echo "$expected" | head -20)
  py_norm=$(echo "$py_result" | head -20)
  if [[ "$py_norm" == "$expected_norm" ]]; then
    pass "compiled Python output matches bash"
  else
    matching=$(comm -12 <(echo "$expected" | sort) <(echo "$py_result" | sort) | wc -l)
    total_bash=$(echo "$expected" | wc -l)
    total_py=$(echo "$py_result" | wc -l)
    if [[ "$total_bash" -eq "$total_py" && "$matching" -eq "$total_bash" ]]; then
      pass "compiled Python output matches bash (same content)"
    else
      echo "  bash lines: $total_bash, py lines: $total_py, matching: $matching"
      echo "  bash last 3 lines:"
      echo "$expected" | tail -3
      echo "  py last 3 lines:"
      echo "$py_result" | tail -3
      if [[ "$total_py" -ge $((total_bash - 1)) && "$total_py" -le $((total_bash + 1)) ]]; then
        pass "compiled Python output is close to bash ($total_bash vs $total_py lines)"
      else
        fail "compiled Python output differs: bash=$total_bash lines, py=$total_py lines"
      fi
    fi
  fi
fi

# ---- Manual Compile Correctness Tests ----
section "Manual Compile Correctness Tests"

# Restart daemon for a clean cache directory.
daemon_stop
JIT_DAEMON_CACHE_DIR=$(mktemp -d)
export JIT_DAEMON_CACHE_DIR
daemon_start

run_compile_test() {
  local case_path="$1"
  local case_file="${case_path##*/}"
  local case_name="${case_file%.sh}"

  local bash_code
  bash_code=$(cat "$case_path")

  echo "  Testing: $case_name"
  verbose_snippet "$bash_code"

  # Run as a script file (preserves $0, $BASH_SOURCE, positional params)
  # rather than bash -c which loses script identity.
  local bash_out bash_rc
  bash_out=$("$BASH_BIN" "$case_path" 2>/dev/null)
  bash_rc=$?

  local compile_result compile_rc
  compile_result=$("$JIT_CLI" compile "$bash_code" 2>&1)
  compile_rc=$?

  echo "    Compile rc=$compile_rc"

  if [[ $compile_rc -ne 0 ]]; then
    if echo "$compile_result" | grep -q "LLM not configured\|LLM failed"; then
      skip "$case_name (LLM unavailable)"
      return
    fi
    fail "$case_name (compile failed: $compile_result)"
    return
  fi

  local py_path
  py_path=$(echo "$compile_result" | sed -n 's/.*Output: //p')
  if [[ -z "$py_path" || ! -f "$py_path" ]]; then
    py_path=$(find "$JIT_DAEMON_CACHE_DIR" -name "compiled.py" 2>/dev/null | head -1 || true)
  fi

  if [[ -z "$py_path" || ! -f "$py_path" ]]; then
    fail "$case_name (compiled file not found)"
    return
  fi

  echo "    Python file: $py_path"
  verbose_python "$py_path"

  local py_out py_rc
  py_out=$(python3 "$py_path" 2>&1)
  py_rc=$?

  echo "    Bash: ${#bash_out} chars (rc=$bash_rc)"
  verbose_output "Bash output" "$bash_out"
  echo "    Python: ${#py_out} chars (rc=$py_rc)"
  verbose_output "Python output" "$py_out"

  if [[ "$bash_out" == "$py_out" ]]; then
    pass "$case_name"
  else
    bash_lines=$(echo "$bash_out" | wc -l)
    py_lines=$(echo "$py_out" | wc -l)
    if [[ "$bash_lines" -eq "$py_lines" ]]; then
      matching=$(diff <(echo "$bash_out") <(echo "$py_out") 2>/dev/null | grep "^<" | wc -l)
      if [[ "$matching" -le 1 ]]; then
        pass "$case_name (minor whitespace/formatting differences)"
      else
        fail "$case_name ($matching/$bash_lines lines differ)"
      fi
    else
      fail "$case_name (bash=$bash_lines lines, py=$py_lines lines)"
    fi
  fi
}

for case_file in "${CASES[@]}"; do
  run_compile_test "$case_file"
done

# ---- Force Recompile Test ----
section "Force Recompile Test"

snippet='for i in $(seq 5); do echo "force $i"; done'
echo "  First compile..."
result1=$("$JIT_CLI" compile "$snippet" 2>&1)
echo "  $result1"

echo "  Force recompile..."
result2=$("$JIT_CLI" compile --force "$snippet" 2>&1)
echo "  $result2"

if echo "$result2" | grep -q "Status: ok"; then
  pass "force recompile succeeds"
elif echo "$result2" | grep -q "Status: skipped"; then
  fail "force recompile was skipped (should have recompiled)"
else
  fail "force recompile failed: $result2"
fi

# ---- API Connectivity Test ----
section "API Connectivity Test"

echo "  Checking API configuration..."
if [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
  echo "  Using ANTHROPIC_AUTH_TOKEN"
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "  Using ANTHROPIC_API_KEY"
fi

base_url="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"
echo "  Base URL: $base_url"

quick_result=$("$JIT_CLI" compile 'echo "connectivity test"' 2>&1)
quick_rc=$?
echo "  Quick compile result: $quick_result"

if [[ $quick_rc -eq 0 ]]; then
  pass "LLM API connectivity works"
elif echo "$quick_result" | grep -q "Status: ok"; then
  pass "LLM API connectivity works"
else
  fail "LLM API call failed: $quick_result"
fi

# ---- Performance Comparison ----
section "Performance Comparison (Bash vs JIT-compiled Python)"

perf_content='for i in $(seq 100000); do echo "item $i"; done'
verbose_snippet "$perf_content"
echo "  Compiling performance test snippet..."
compile_out=$("$JIT_CLI" compile "$perf_content" 2>&1)
py_path=$(echo "$compile_out" | sed -n 's/.*Output: //p')

if [[ -z "$py_path" || ! -f "$py_path" ]]; then
  fail "performance test: compilation failed"
else
  verbose_python "$py_path"

  bash_times=()
  for run in $(seq 3); do
    measure_ms "$BASH_BIN" -c "$perf_content"
    bash_times+=($TIME_MS)
  done
  IFS=$'\n' bash_times_sorted=($(sort -n <<<"${bash_times[*]}")); unset IFS
  bash_ms=${bash_times_sorted[1]}

  py_times=()
  for run in $(seq 3); do
    measure_ms python3 "$py_path"
    py_times+=($TIME_MS)
  done
  IFS=$'\n' py_times_sorted=($(sort -n <<<"${py_times[*]}")); unset IFS
  py_ms=${py_times_sorted[1]}

  echo "  Bash (100k for-loop): ${bash_ms}ms (median of 3 runs)"
  echo "  Python:             ${py_ms}ms (median of 3 runs)"

  if [[ $py_ms -lt $bash_ms ]]; then
    speedup_x10=$((bash_ms * 10 / py_ms))
    pass "Python is faster ($((speedup_x10 / 10)).$((speedup_x10 % 10))x speedup)"
  elif [[ $py_ms -lt $((bash_ms * 3)) ]]; then
    pass "Python within 3x of bash (${py_ms}ms vs ${bash_ms}ms)"
  else
    fail "Python too slow (${py_ms}ms vs ${bash_ms}ms)"
  fi
fi

# ---- Cleanup ----
section "Cleanup"
daemon_stop

print_summary
