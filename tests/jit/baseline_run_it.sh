#!/usr/bin/env bash
# baseline_run_it.sh -- run a single script under baseline bash (no JIT).
#
# Simply executes the given script with the baseline (non-JIT) bash binary.
# No daemon, no compilation — just run once.
#
# Usage:
#   ./tests/jit/baseline_run_it.sh <script.sh>
#   ./tests/jit/baseline_run_it.sh <script.sh> --verbose

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib/test_common.sh
source "$SCRIPT_DIR/lib/test_common.sh"

VERBOSE=0
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose|-v) VERBOSE=1; shift ;;
    -h|--help)    sed -n '2,10p' "$0"; exit 0 ;;
    -*)           echo "unknown flag: $1" >&2; exit 2 ;;
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

BASELINE_BIN="${BASELINE_BIN:-$HOME/local/bash-baseline/bin/bash}"

if [[ ! -x "$BASELINE_BIN" ]]; then
  echo "ERROR: baseline bash not found at $BASELINE_BIN" >&2
  exit 1
fi

TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"
LABEL="${TARGET##*/}"

echo "Running $LABEL with baseline bash..."
echo "---"
start_ms=$(python3 -c "import time; print(int(time.time()*1000))")
"$BASELINE_BIN" "$TARGET"
rc=$?
end_ms=$(python3 -c "import time; print(int(time.time()*1000))")
TIME_MS=$((end_ms - start_ms))
echo "---"
echo "Exit code: $rc  Time: ${TIME_MS}ms"

exit $rc
