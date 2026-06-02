#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
DEFAULT_JIT_PREFIX="$HOME/local/bash-jit"
DEFAULT_BASELINE_PREFIX="$HOME/local/bash-baseline"

usage() {
    echo "Usage: $0 [--prefix <dir>] [--jit|--no-jit] [--clean] [--test] [--help]"
    echo ""
    echo "Options:"
    echo "  --prefix <dir>  Installation directory (default: $DEFAULT_JIT_PREFIX or $DEFAULT_BASELINE_PREFIX)"
    echo "  --jit           Enable JIT support (default)"
    echo "  --no-jit        Build baseline bash without JIT"
    echo "  --clean         Remove build directory before building"
    echo "  --test          Run tests after building"
    echo "  --help          Show this help message"
}

PREFIX=""
CLEAN=0
TEST=0
JIT=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            mkdir -p "$2"
            PREFIX="$(cd "$2" && pwd)"
            shift 2
            ;;
        --jit)
            JIT=1
            shift
            ;;
        --no-jit)
            JIT=0
            shift
            ;;
        --clean)
            CLEAN=1
            shift
            ;;
        --test)
            TEST=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$PREFIX" ]]; then
    if [[ $JIT -eq 1 ]]; then
        PREFIX="$DEFAULT_JIT_PREFIX"
    else
        PREFIX="$DEFAULT_BASELINE_PREFIX"
    fi
fi

if [[ $CLEAN -eq 1 ]]; then
    echo "==> Cleaning build directory..."
    rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "==> Configuring (prefix=$PREFIX)..."
"$PROJECT_DIR/configure" --prefix="$PREFIX"

if [[ $JIT -eq 1 ]]; then
    echo "==> Building with JIT..."
    make -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" \
        JIT_O=bash_jit.o \
        ADDON_CFLAGS=-DBASH_JIT
else
    echo "==> Building baseline (no JIT)..."
    make -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" \
        JIT_O=
fi

echo "==> Installing to $PREFIX..."
if [[ $JIT -eq 1 ]]; then
    make install JIT_O=bash_jit.o ADDON_CFLAGS=-DBASH_JIT
else
    make install JIT_O=
fi

# Restore source-tree files that the build process may have modified
git -C "$PROJECT_DIR" checkout -- configure po/

if [[ $TEST -eq 1 ]]; then
    echo "==> Running tests..."
    BASH_BIN="$PREFIX/bin/bash" bash "$PROJECT_DIR/tests/jit/run_jit_tests.sh"
fi

echo "==> Done! bash installed to $PREFIX/bin/bash ($([[ $JIT -eq 1 ]] && echo 'JIT enabled' || echo 'baseline, no JIT'))"
