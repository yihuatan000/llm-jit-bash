#!/usr/bin/env bash
# jit_test_it.sh -- functional + performance test for a single script under JIT.
#
# Compiles the script, compares bash vs Python output, measures performance.
#
# Usage:
#   ./tests/jit/jit_test_it.sh <script.sh>
#   ./tests/jit/jit_test_it.sh <script.sh> --verbose

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib/test_common.sh
source "$SCRIPT_DIR/lib/test_common.sh"

VERBOSE=0
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose|-v) VERBOSE=1; shift ;;
    -h|--help)
      sed -n '2,9p' "$0"
      exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)
      if [[ -n "$TARGET" ]]; then
        echo "ERROR: multiple scripts specified (expected exactly one)" >&2; exit 2
      fi
      TARGET="$1"; shift
      ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "ERROR: no script specified" >&2
  echo "Usage: $0 <script.sh> [--verbose]" >&2
  exit 2
fi

if [[ ! -f "$TARGET" ]]; then
  echo "ERROR: file not found: $TARGET" >&2
  exit 2
fi

TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"
LABEL="${TARGET##*/}"

# ── Setup ──────────────────────────────────────────────────────────────────

section "Setup: $LABEL"

# Use persistent cache so compilations survive across runs.
export JIT_DAEMON_CACHE_DIR="$CACHE_DIR"

daemon_start
pass "daemon started"

# ── Baseline ───────────────────────────────────────────────────────────────

section "Baseline (native bash)"

BASELINE_BIN="${HOME}/local/bash-baseline/bin/bash"
if [[ ! -x "$BASELINE_BIN" ]]; then
  BASELINE_BIN="/bin/bash"
fi

bash_out=$(BASH_JIT=0 "$BASELINE_BIN" "$TARGET" 2>&1)
bash_rc=$?
bash_lines=$(echo "$bash_out" | wc -l | tr -d ' ')
bash_chars=$(echo "$bash_out" | wc -c | tr -d ' ')

echo "  bash exit code: $bash_rc"
echo "  bash output: $bash_chars chars, ${bash_lines} lines"

if [[ $bash_rc -ne 0 ]]; then
  fail "baseline exited with code $bash_rc"
  daemon_stop
  exit 1
fi
pass "baseline captured"

# ── Compile ────────────────────────────────────────────────────────────────

section "Compile ($LABEL → Python)"

source_content=$(cat "$TARGET")
source_len=${#source_content}
echo "  Compiling $source_len chars..."

compile_out=$("$JIT_CLI" compile --stdin < "$TARGET" 2>&1)
compile_rc=$?

if [[ $compile_rc -ne 0 ]]; then
  echo "  FAIL: compilation failed (rc=$compile_rc)"
  echo "  $compile_out"
  fail "compilation failed"
  daemon_stop
  exit 1
fi

compiled_py=$(echo "$compile_out" | sed -n 's/.*Output: //p')
echo "  Python file: $compiled_py"
pass "compilation succeeded"

# ── Correctness ────────────────────────────────────────────────────────────

section "Correctness (bash vs Python)"

py_out=$(python3 "$compiled_py" 2>&1)
py_rc=$?
py_lines=$(echo "$py_out" | wc -l | tr -d ' ')
py_chars=$(echo "$py_out" | wc -c | tr -d ' ')

echo "  Python exit code: $py_rc"
echo "  Python output: $py_chars chars, ${py_lines} lines"

if [[ "$bash_out" == "$py_out" ]]; then
  pass "output is identical"
else
  matching=$(diff <(echo "$bash_out") <(echo "$py_out") | grep "^<" | wc -l)
  matching=$((bash_lines - matching))
  fail "output differs: bash=${bash_lines} lines, py=${py_lines} lines, matching=${matching}"
  if [[ $VERBOSE -eq 1 ]]; then
    echo ""
    echo "  === bash output ==="
    echo "$bash_out"
    echo ""
    echo "  === python output ==="
    echo "$py_out"
    echo ""
    echo "  === diff ==="
    diff <(echo "$bash_out") <(echo "$py_out") | head -60
  else
    echo "  Use --verbose to see full output"
  fi
fi

# ── Performance ────────────────────────────────────────────────────────────

section "Performance (bash vs Python)"

# Bash: median of 3 runs
bash_times=()
for _ in $(seq 3); do
  measure_ms "$BASELINE_BIN" "$TARGET"
  bash_times+=("$TIME_MS")
done
bash_ms=$(printf '%s\n' "${bash_times[@]}" | sort -n | sed -n '2p')

# Python: median of 3 runs
py_times=()
for _ in $(seq 3); do
  measure_ms python3 "$compiled_py"
  py_times+=("$TIME_MS")
done
py_ms=$(printf '%s\n' "${py_times[@]}" | sort -n | sed -n '2p')

if [[ $py_ms -gt 0 ]]; then
  speedup=$(python3 -c "print(f'{$bash_ms / $py_ms:.1f}x')")
else
  speedup="inf"
fi

printf "  Bash (%s): %dms (median of 3)\n" "$LABEL" "$bash_ms"
printf "  Python:        %dms (median of 3)\n" "$py_ms"

if [[ $py_ms -lt $bash_ms ]]; then
  pass "Python is faster ($speedup speedup)"
else
  fail "Python is slower ($speedup)"
fi

# ── Cleanup ────────────────────────────────────────────────────────────────

section "Cleanup"
daemon_stop

print_summary
