#!/usr/bin/env bash
# setup.sh -- Download koala benchmark suite and fetch test inputs.
#
# Usage:
#   ./tests/jit/koala/setup.sh              # default: clone to ../koala
#   ./tests/jit/koala/setup.sh /path/to/dir # clone to specified directory

set -uo pipefail

KOALA_DIR="${1:-$(cd "$(dirname "$0")/../../../.." && pwd)/koala}"

if [[ -d "$KOALA_DIR/.git" ]]; then
  echo "Koala already exists at $KOALA_DIR"
else
  echo "Cloning koala to $KOALA_DIR ..."
  git clone git@github.com:kbensh/koala.git "$KOALA_DIR"
fi

echo ""
echo "Fetching test inputs (small datasets) ..."

# rand: all_names.txt (~2M names)
echo "  rand ..."
(cd "$KOALA_DIR/rand" && bash fetch.sh 2>&1)

# nlp: Project Gutenberg texts (small dataset: ~3000 books)
echo "  nlp ..."
(cd "$KOALA_DIR/nlp" && bash fetch.sh --small 2>&1)

echo ""
echo "Setup complete. Run benchmarks with:"
echo "  ./tests/jit/koala/run_all.sh $KOALA_DIR"
