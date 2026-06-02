#!/usr/bin/env bash
# jit_run_it.sh -- run a single script under JIT bash.
#
# Starts the daemon, runs the given script with BASH_JIT=1, shows output.
# No correctness comparison or performance measurement — just execute once.
#
# Usage:
#   ./tests/jit/jit_run_it.sh <script.sh>                     # cached (reuse if available)
#   ./tests/jit/jit_run_it.sh <script.sh> --force             # force recompile
#   ./tests/jit/jit_run_it.sh <script.sh> --verbose           # show daemon status
#   ./tests/jit/jit_run_it.sh <script.sh> --force --verbose

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib/test_common.sh
source "$SCRIPT_DIR/lib/test_common.sh"

VERBOSE=0
FORCE=0
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force|-f)   FORCE=1; shift ;;
    --verbose|-v) VERBOSE=1; shift ;;
    -h|--help)    sed -n '2,14p' "$0"; exit 0 ;;
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
  echo "Usage: $0 <script.sh> [--force] [--verbose]" >&2
  exit 2
fi

if [[ ! -f "$TARGET" ]]; then
  echo "ERROR: file not found: $TARGET" >&2
  exit 2
fi

if [[ ! -x "$BASH_BIN" ]]; then
  echo "ERROR: bash not found at $BASH_BIN" >&2
  exit 1
fi

TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"
LABEL="${TARGET##*/}"

# Use persistent cache directory (not a tmpdir) so compilations survive across runs.
export JIT_DAEMON_CACHE_DIR="$CACHE_DIR"

# Start daemon
echo "Starting daemon..."
daemon_start

if [[ $VERBOSE -eq 1 ]]; then
  "$JIT_CLI" status 2>&1
fi

# Compile via jit compile --stdin (avoids shell escaping issues with script content).
force_flag=""
if [[ $FORCE -eq 1 ]]; then
  force_flag="--force"
  echo "Force compiling $LABEL..."
else
  echo "Compiling $LABEL..."
fi
compile_out=$("$JIT_CLI" compile --stdin $force_flag < "$TARGET" 2>&1)
compile_rc=$?

if [[ $compile_rc -ne 0 ]]; then
  echo "Compile failed: $compile_out"
  daemon_stop
  exit 1
fi

if [[ $VERBOSE -eq 1 ]]; then
  echo "$compile_out"
fi

# Extract compiled .py path from compile output.
compiled_py=$(echo "$compile_out" | sed -n 's/.*Output: //p')

# Run under JIT bash
echo "Running $LABEL with BASH_JIT=1..."
if [[ -n "$compiled_py" && -f "$compiled_py" ]]; then
  echo "Using: $compiled_py"
fi
echo "---"
start_ms=$(python3 -c "import time; print(int(time.time()*1000))")
BASH_JIT=1 BASH_JIT_DAEMON="$DAEMON_PATH" "$BASH_BIN" "$TARGET"
rc=$?
end_ms=$(python3 -c "import time; print(int(time.time()*1000))")
TIME_MS=$((end_ms - start_ms))
echo "---"
echo "Exit code: $rc  Time: ${TIME_MS}ms"

if [[ $VERBOSE -eq 1 ]]; then
  "$JIT_CLI" status 2>&1
fi

# Stop daemon
daemon_stop

exit $rc
