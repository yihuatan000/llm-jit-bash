#!/usr/bin/env bash
# run_all.sh -- Run all koala benchmarks with baseline and JIT comparison.
#
# Usage:
#   ./tests/jit/koala/run_all.sh                     # default koala path
#   ./tests/jit/koala/run_all.sh /path/to/koala      # explicit path
#   ./tests/jit/koala/run_all.sh /path/to/koala --runs 5

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/test_common.sh"

# ── Ensure API key is available (read from ~/.claude/settings.json) ────────
if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && [[ -z "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
  SETTINGS="$HOME/.claude/settings.json"
  if [[ -f "$SETTINGS" ]]; then
    while IFS='=' read -r key val; do
      [[ -z "$key" || -z "$val" ]] && continue
      case "$key" in
        ANTHROPIC_AUTH_TOKEN|ANTHROPIC_API_KEY|ANTHROPIC_BASE_URL)
          export "$key=$val"
          ;;
      esac
    done < <(python3 -c "
import json, sys
try:
    with open('$SETTINGS') as f:
        data = json.load(f)
    env = data.get('env', {})
    for k in ('ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY', 'ANTHROPIC_BASE_URL'):
        v = env.get(k, '')
        if v: print(f'{k}={v}')
except Exception: pass
" 2>/dev/null)
  fi
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && [[ -z "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
  echo "ERROR: No Anthropic API key found." >&2
  echo "Set ANTHROPIC_API_KEY or run: source scripts/enter-jit-bash.sh" >&2
  exit 1
fi

KOALA_DIR="${1:-$(cd "$SCRIPT_DIR/../../../.." && pwd)/koala}"
shift 2>/dev/null || true

RUNS=3
if [[ "${1:-}" == "--runs" ]]; then
  RUNS="${2:-3}"
fi

if [[ ! -d "$KOALA_DIR" ]]; then
  echo "ERROR: koala not found at $KOALA_DIR" >&2
  echo "Run ./tests/jit/koala/setup.sh first" >&2
  exit 1
fi

BASELINE_BIN="${HOME}/local/bash-baseline/bin/bash"
if [[ ! -x "$BASELINE_BIN" ]]; then
  echo "ERROR: baseline bash not found at $BASELINE_BIN" >&2
  exit 1
fi

# ── Benchmark definitions ──────────────────────────────────────────────────
# Each entry: name | koala_script | working_dir | env_vars | args

declare -a BENCHMARKS=(
  "rand-pass|rand/scripts/pass.sh|rand|KOALA_SHELL=|5000 32"
  "rand-pickname|rand/scripts/pickname.sh|rand|KOALA_SHELL=|$KOALA_DIR/rand/inputs/all_names.txt 500 /tmp/koala-pickname-out"
  "nlp-count-words|nlp/scripts/count_words.sh|nlp|IN=__NLP_INPUTS__;ENTRIES=50;SUITE_DIR=$KOALA_DIR/nlp|/tmp/koala-nlp-out"
  "nlp-bigrams|nlp/scripts/bigrams.sh|nlp|IN=__NLP_INPUTS__;ENTRIES=50;SUITE_DIR=$KOALA_DIR/nlp|/tmp/koala-nlp-out"
  "nlp-anagrams|nlp/scripts/find_anagrams.sh|nlp|IN=__NLP_INPUTS__;ENTRIES=50;SUITE_DIR=$KOALA_DIR/nlp|/tmp/koala-nlp-out"
  "nlp-syllables|nlp/scripts/sort_words_by_num_of_syllables.sh|nlp|IN=__NLP_INPUTS__;ENTRIES=50;SUITE_DIR=$KOALA_DIR/nlp|/tmp/koala-nlp-out"
)

# ── Auto-detect NLP input directory ────────────────────────────────────────
NLP_INPUTS=""
for d in "$KOALA_DIR/nlp/inputs/pg" "$KOALA_DIR/nlp/inputs/pg-small" "$KOALA_DIR/nlp/inputs/pg-min"; do
  if [[ -d "$d" ]] && [[ $(ls "$d" 2>/dev/null | wc -l) -gt 0 ]]; then
    NLP_INPUTS="$d"
    break
  fi
done

# ── Helpers ─────────────────────────────────────────────────────────────────

run_one() {
  local label="$1" script="$2" workdir="$3" envs="$4" args="$5"
  local script_path="$KOALA_DIR/$script"

  if [[ ! -f "$script_path" ]]; then
    echo "  SKIP: $script not found"
    return
  fi

  # Check required inputs
  if [[ "$label" == "rand-pickname" ]] && [[ ! -f "$KOALA_DIR/rand/inputs/all_names.txt" ]]; then
    echo "  SKIP: $label (rand inputs not fetched, run setup.sh)"
    return
  fi

  # Build env prefix (resolve __NLP_INPUTS__ placeholder)
  if echo "$envs" | grep -q "__NLP_INPUTS__" && [[ -z "$NLP_INPUTS" ]]; then
    echo "  SKIP: $label (nlp inputs not fetched, run setup.sh)"
    return
  fi
  local env_prefix=""
  if [[ -n "$envs" ]]; then
    IFS=';' read -ra pairs <<< "$envs"
    for pair in "${pairs[@]}"; do
      pair="${pair//__NLP_INPUTS__/$NLP_INPUTS}"
      env_prefix+=" $pair"
    done
  fi

  # ── Create output directories (pickname needs a writable dir) ──
  mkdir -p /tmp/koala-pickname-out /tmp/koala-nlp-out

  # ── Baseline ──
  local baseline_times=()
  local baseline_err=""
  for i in $(seq 1 "$RUNS"); do
    local t
    TIMEFORMAT='%R'
    t=$( { cd "$KOALA_DIR/$workdir" && time env $env_prefix "$BASELINE_BIN" $script_path $args > /dev/null 2>/tmp/koala-bench-err.txt; } 2>&1 )
    baseline_times+=("$(python3 -c "print(int(${t} * 1000))")")
  done
  baseline_err=$(cat /tmp/koala-bench-err.txt 2>/dev/null)
  local baseline_ms
  baseline_ms=$(printf '%s\n' "${baseline_times[@]}" | sort -n | sed -n '2p')

  # ── Compile ──
  export JIT_DAEMON_CACHE_DIR="$CACHE_DIR"
  daemon_start

  local compile_out
  compile_out=$("$JIT_CLI" compile --force --stdin < "$script_path" 2>&1)
  local compile_rc=$?
  local compile_status
  compile_status=$(echo "$compile_out" | sed -n 's/Status: //p')
  if [[ $compile_rc -ne 0 ]] || [[ "$compile_status" != "ok" ]]; then
    echo "  FAIL: compile error (status=$compile_status)"
    daemon_stop
    return
  fi
  local compiled_py
  compiled_py=$(echo "$compile_out" | sed -n 's/.*Output: //p')

  # Verify compiled file exists
  if [[ ! -f "$compiled_py" ]]; then
    echo "  FAIL: compiled file not found: $compiled_py"
    daemon_stop
    return
  fi

  # ── JIT (Python) ──
  local jit_times=()
  local jit_err=""
  for i in $(seq 1 "$RUNS"); do
    local t
    TIMEFORMAT='%R'
    t=$( { cd "$KOALA_DIR/$workdir" && time env $env_prefix BASH_JIT_SCRIPT="$script_path" python3 "$compiled_py" $args > /dev/null 2>/tmp/koala-bench-err.txt; } 2>&1 )
    jit_times+=("$(python3 -c "print(int(${t} * 1000))")")
  done
  jit_err=$(cat /tmp/koala-bench-err.txt 2>/dev/null)
  local jit_ms
  jit_ms=$(printf '%s\n' "${jit_times[@]}" | sort -n | sed -n '2p')

  daemon_stop

  # ── Report ──
  local speedup
  if [[ $jit_ms -gt 0 ]]; then
    speedup=$(python3 -c "print(f'{$baseline_ms / $jit_ms:.1f}x')")
  else
    speedup="inf"
  fi

  printf "  %-20s  Baseline: %6dms  JIT: %6dms  Speedup: %s\n" "$label" "$baseline_ms" "$jit_ms" "$speedup"

  # Show stderr if there were errors
  if [[ -n "$jit_err" ]]; then
    echo "    WARNING: JIT stderr: $(echo "$jit_err" | head -1)"
  fi
}

# ── Main ────────────────────────────────────────────────────────────────────

echo "========================================"
echo " Koala Benchmarks (USENIX ATC '25)"
echo "========================================"
echo "Date:    $(date)"
echo "Machine: $(uname -srm)"
echo "Koala:   $KOALA_DIR"
echo "Runs:    $RUNS"
echo ""

for entry in "${BENCHMARKS[@]}"; do
  IFS='|' read -r name script workdir envs args <<< "$entry"
  run_one "$name" "$script" "$workdir" "$envs" "$args"
done

echo ""
echo "========================================"
echo " Done"
echo "========================================"
