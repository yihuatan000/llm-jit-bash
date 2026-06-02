# llm-jit-bash

Bash JIT compiler powered by LLM translation. Automatically compiles hot bash code and entire scripts into Python for faster execution — **zero modifications required** to existing scripts.

Based on GNU Bash 5.3.

## How It Works

1. **Detect**: When a bash script is executed with `BASH_JIT=1`, the JIT system computes a fingerprint of the script content
2. **Compile**: The daemon calls an LLM to translate bash → Python, writing the result to a local cache
3. **Execute**: On subsequent runs, bash replaces itself with `python3` via `execvp`, running the compiled version

```
First run:   bash script.sh → normal bash execution → async LLM compilation
Second run:  bash script.sh → cache hit → execvp("python3", compiled.py)
```

## Performance

### Self-contained scripts

| Script | Type | Bash | Python (JIT) | Speedup |
|--------|------|------|---------------|---------|
| source-stats.sh | CPU intensive (loops, string processing) | 16,639 ms | 376 ms | **44.3x** |
| git-file-contributors.sh | I/O intensive (subprocess per file) | 49,211 ms | 42,802 ms | 1.15x |

### Koala benchmarks (USENIX ATC '25, real-world scripts)

Tested against the [Koala](https://github.com/kbensh/koala) benchmark suite with `pg-small` dataset:

| Script | Type | Bash | Python (JIT) | Speedup |
|--------|------|------|---------------|---------|
| pass | loop + subprocess (5000 iterations, tr/head per iteration) | 6,215 ms | 16 ms | **388x** |
| pickname | loop + file I/O (500 iterations, shuf per iteration) | 27,471 ms | 141 ms | **195x** |
| nlp-anagrams | loop + functions + sort/uniq | 677 ms | 371 ms | **1.8x** |
| nlp-syllables | loop + functions + pipelines | 902 ms | 621 ms | **1.5x** |
| nlp-bigrams | loop + functions + temp files | 2,158 ms | 1,498 ms | **1.4x** |
| nlp-count-words | loop + subprocess pipelines | 509 ms | 527 ms | 1.0x |

The JIT excels at scripts with heavy loops, string processing, and repeated command dispatch — exactly where bash's per-iteration overhead adds up. Scripts dominated by I/O-bound subprocess calls see minimal improvement.

### Reproduce benchmarks

```bash
./tests/jit/koala/setup.sh          # download koala + test data
./tests/jit/koala/run_all.sh         # run all benchmarks
```

## Quick Start

### Build

```bash
bash scripts/build.sh          # builds JIT-enabled bash to ~/local/bash-jit/
```

### Enter JIT Bash

```bash
source scripts/enter-jit-bash.sh
```

This starts the daemon, configures the LLM API key, and drops you into a JIT-enabled bash shell.

### Pre-compile a Script

```bash
jit compile script.sh                    # compile a script file
jit compile --stdin < script.sh          # compile via stdin
jit compile --force script.sh            # force recompilation
```

### Run with JIT

```bash
BASH_JIT=1 bash script.sh    # first run: normal speed + async compilation
BASH_JIT=1 bash script.sh    # second run: Python speed
```

## Architecture

```
┌──────────────────────────────────────────┐
│            Bash Process (C)              │
│                                          │
│  bash_jit_try_script()                   │
│    1. Read script, compute fingerprint   │
│    2. Check cache (compiled.py exists?)  │
│    3. Cache hit → execvp("python3", ...) │
│    4. Cache miss → report to daemon      │
│                                          │
└──────────────┬───────────────────────────┘
               │ Unix socket
               v
┌──────────────────────────────────────────┐
│         bash_jitd (Python daemon)        │
│                                          │
│  1. Count executions per fingerprint     │
│  2. When threshold crossed:              │
│     Call LLM → bash to Python            │
│  3. Validate + write to cache            │
│                                          │
└──────────────────────────────────────────┘
```

### Key Design Decisions

- **Zero overhead when disabled**: All JIT code is wrapped in `#if defined(BASH_JIT)`. Without `--enable-jit`, the binary is stock bash.
- **Graceful degradation**: Every failure path (daemon down, LLM error, Python crash) falls back to normal bash execution.
- **Whole-script JIT**: Uses `execvp` to replace the bash process entirely with python3, inheriting all file descriptors, environment, and working directory.
- **FNV-128 fingerprinting**: Non-cryptographic hash for cache lookup. No external dependencies.

## CLI Reference

```
jit status                    Show daemon status and hot code
jit compile <file.sh>         Compile a script
jit compile <bash_string>     Compile a bash string
jit compile --stdin           Compile from stdin
jit compile --force ...       Force recompilation
jit clear                     Clear all compiled cache
jit clear --failed            Clear only failed compilations
jit stop                      Stop the daemon
jit start                     Start the daemon
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `BASH_JIT` | (unset) | Set to `1` to enable JIT |
| `BASH_JIT_THRESHOLD` | `100` | Execution count before auto-compilation |
| `BASH_JIT_MIN_DURATION` | `50` | Min avg duration (ms) to trigger compilation |
| `BASH_JIT_CACHE_DIR` | `~/.cache/bash_jit` | Cache directory |
| `BASH_JIT_DAEMON` | `scripts/bash_jitd` | Path to daemon |

LLM configuration is read from `~/.config/bash_jit/config.json` or environment variables (`ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`).

## Project Structure

```
bash_jit.c / bash_jit.h        C-side: fingerprint, eligibility, cache check, execvp
scripts/bash_jitd               Python daemon: counting, LLM translation, caching
scripts/jit                     CLI tool
scripts/build.sh                Build script
scripts/enter-jit-bash.sh       Enter JIT-enabled bash shell
docs/plans/jit-compiler.md      Full design document
tests/jit/                      Test suite (27 test cases + Koala benchmarks)
```

## Requirements

- GCC or Clang
- Python 3.8+
- Anthropic API key (or compatible endpoint)

## License

GNU GPL v3 (inherited from GNU Bash). See [COPYING](COPYING).
