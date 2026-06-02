# Bash JIT Compiler Design Document

## 1. Background and Motivation

Bash is the most widely used shell on Unix/Linux systems, but as an interpreted language its performance is limited. Many production environments (CI/CD pipelines, deployment scripts, cron jobs) repeatedly execute the same bash scripts thousands of times. Recent advances in LLM make it possible to accurately translate bash code to Python - a language with significantly faster execution speed for CPU-intensive operations (string processing, loops, data structures).

This project implements a JIT compiler in Bash 5.3 that:

1. Automatically detects "hot" code snippets (any code executed many times, not just functions)
2. Uses LLM to translate them to Python
3. Transparently redirects subsequent executions to the compiled Python version
4. Falls back to normal bash execution if anything goes wrong

Bash scripts require **zero modification** to benefit from JIT.

### 1.1 Design Principles

1. **Conservative eligibility**: Only commands that can be correctly translated to Python are JIT'd. Complex bash constructs (dynamic scoping, word splitting, `eval`, process substitution) are excluded by the eligibility check.
2. **Graceful degradation**: Every failure path falls back to normal bash execution. The JIT system must never make bash slower or less correct.
3. **Zero overhead when disabled**: When `BASH_JIT` is unset, the JIT adds exactly one branch per execution path.
4. **Integration over reimplementation**: The JIT reuses bash's existing execution engine (pipes, redirections, signals, job control) by constructing synthetic `cm_simple` commands, rather than reimplementing these mechanisms.

## 2. Code Snippet: Tracked Unit

### 2.1 What is a "snippet"?

A **snippet** is any top-level command parsed by bash's parser. This is the natural unit of execution in bash's `reader_loop()` and `parse_and_execute()`. Examples:

| Bash Code | Snippet Count | Explanation |
|-----------|---------------|-------------|
| `aaa && bbb && ccc` | 1 | One `cm_connection` command |
| `for i in $(seq 100); do process "$i"; done` | 1 | One `cm_for` command |
| `foo() { ... }; foo; foo` | 3 | Function def + 2 calls (each is separate) |
| Script with 10 lines of code | ~10 | Each top-level statement is one snippet |
| `source helpers.sh` | N | Each top-level command in helpers.sh becomes a snippet |

### 2.2 Snippet Fingerprinting

Each snippet is identified by a composite fingerprint that includes both the source text and the runtime context:

```
fingerprint = FNV128(
    make_command_string(command)
    + "\0"
    + snapshot(all_function_bodies)        ← iterate all defined functions
    + "\0"
    + shell_options_bitmap
)
```

The fingerprint is a 128-bit value produced by a dual-pass FNV-1a hash (see Section 5.1.2), serialized as a 32-character hex string.

**Why not plain SHA-256?** Bash's codebase has no cryptographic hash function. Adding SHA-256 would require 400+ lines of crypto code or an OpenSSL dependency. A 128-bit non-cryptographic hash provides negligible collision probability for a local snippet cache with hundreds of entries.

**Why include ALL function bodies (not just "referenced" ones)?** Statically determining which functions a bash command references is undecidable — command names can come from variable expansions (`"$funcname" args`), conditional logic, or nested calls. Rather than attempt a fragile heuristic, the context hash includes ALL currently defined functions. This is conservative (redefining any function invalidates all cache entries) but correct (no false cache hits). For typical scripts with < 100 functions, the overhead is negligible.

**Why include shell options?** `set -e`, `set -u`, and `set -o pipefail` fundamentally change command behavior. A snippet compiled under `set -e` must not be reused when `set +e` is active.

### 2.3 Three Tracking Scenarios

| Scenario | Interception Point | What Gets Tracked |
|----------|-------------------|-------------------|
| Top-level commands in scripts/interactive | `reader_loop()` in `eval.c:183` | Each `current_command` |
| source/eval/command substitution | `parse_and_execute()` in `evalstring.c:567` | Each `command` in the loop |
| Function calls | `execute_function()` in `execute_cmd.c:5181` | Function body (name + body hash) |

### 2.4 Why This Covers All Cases

**Case: `aaa && bbb && ccc`**
This is one `cm_connection` top-level command. The entire chain is one snippet. If this chain appears in a script executed 100 times, the daemon sees its hash 100 times and eventually JITs it.

**Case: `bash -c "for i in ...; do ...; done"`**
The entire `-c` argument is parsed in `parse_and_execute()` or `reader_loop()`. One snippet.

**Case: Repeatedly calling `bash script.sh` from a loop**
Each invocation is a new bash process. Each process reads `script.sh` in `reader_loop()`. The daemon receives the same hash from each process. When the global count crosses the threshold, it compiles. The next process to start discovers the compiled version.

**Case: `source heavy_lib.sh` inside a loop**
`source` goes through `parse_and_execute()`. Each top-level command in `heavy_lib.sh` is tracked as a separate snippet.

**Case: Function `foo` called 1000 times in a loop**
`execute_function()` is called 1000 times. The function body is tracked by (name, body_hash). After the threshold, the function body gets JIT'd.

## 3. Architecture Overview

```
+---------------------------------------------------------------+
|                       Bash Process (C)                         |
|                                                                |
|  reader_loop() [eval.c:183]     -- top-level commands         |
|  parse_and_execute() [evalstring.c:567] -- source/eval        |
|  execute_function() [execute_cmd.c:5181] -- function calls    |
|              |                                                 |
|              v                                                 |
|  +------------------------+                                   |
|  | bash_jit_check(command)|  1. savestring(make_command_string)|
|  |                        |  2. compute fingerprint             |
|  |                        |  3. check eligibility               |
|  |                        |  4. check local cache               |
|  |                        |  5. if compiled: build replacement   |
|  |                        |  6. if not compiled: report to daemon|
|  +------------------------+                                   |
|         |              |                                       |
|   REPLACEMENT      NORMAL                                      |
|         |              |                                       |
|         v              v                                       |
|  execute_command()  execute_command()                          |
|  (python3 as         (original bash)                           |
|   cm_simple)                                                  |
|         |              |                                       |
+---------------------------------------------------------------+
              | (non-blocking Unix socket)
              v
+---------------------------------------------------------------+
|              bash_jitd (Python daemon, one per user)           |
|                                                                |
|  1. Receive "executed hash X" from all bash processes          |
|  2. Maintain GLOBAL counters (survives across bash processes)  |
|  3. When hash X crosses threshold:                             |
|     a. Extract source from request                             |
|     b. Call LLM API -> translate bash to Python                |
|     c. Validate (syntax check + trust-but-verify)              |
|     d. Write to $BASH_JIT_CACHE_DIR/<hash>/compiled.py         |
|  4. Next time any bash process sees hash X:                    |
|     local cache hit -> construct replacement command           |
+---------------------------------------------------------------+
```

### 3.1 Key Design Decision: Replacement COMMAND Model

The JIT system does **not** fork+exec Python directly. Instead, it constructs a synthetic `cm_simple` command (e.g., `python3 /cache/<hash>/compiled.py`) and hands it to bash's existing `execute_command()` engine.

**Why replacement (not direct fork+exec)**:
- **Redirections work automatically**: `command > file.txt` — bash's execution engine handles the redirect
- **Pipes work automatically**: `cmd1 | compiled_cmd | cmd3` — bash handles the pipeline
- **Job control works**: `compiled_cmd &` — bash handles background execution
- **Signals are correct**: SIGINT, SIGTERM are passed through bash's signal handling
- **Environment is correct**: bash calls `maybe_make_export_env()` before execve

### 3.2 Key Design Decision: Daemon-based Unified Counting

All bash processes report execution events to a single daemon via Unix domain socket. The daemon maintains **global counters** that persist across process boundaries.

**Why daemon (not file-based)**:
- Real-time: no delay between reporting and threshold detection
- Atomic: no race conditions between concurrent bash processes
- Persistent: daemon can maintain counters in memory, flush to disk periodically
- Single compilation: when threshold is crossed, daemon compiles exactly once

**Communication overhead**: Each report is a non-blocking write of ~100 bytes to a Unix socket. On localhost this is <0.05ms. For a script with 1000 top-level commands, total overhead is ~50ms -- negligible.

## 4. Execution Flow

### 4.1 Normal Flow (per command in bash)

```
Command parsed (COMMAND tree built)
         |
         v
  JIT enabled? --No--> Normal bash execution
         |
        Yes
         v
  source = savestring(make_command_string(command))
  fingerprint = fnv128_hex(source, context)
         |
         v
  Check eligibility (see Section 5.2)
         |
    ineligible?
         |
        Yes --> Normal bash execution
         |
        No
         v
  Check local cache (jit_snippet_entry)
         |
    is_compiled == 1?
         |
        Yes --> goto REPLACEMENT
         |
        No
         v
  Periodically check filesystem (every 10 invocations):
  access($CACHE_DIR/<fingerprint>/compiled.py, R_OK)?
         |
        Yes --> verify source match (anti-collision)
         |           |
         |     verified? --No--> delete cache, mark -1, goto NORMAL
         |           |
         |          Yes
         |           |
         +---> goto REPLACEMENT
         |
        No --> goto NORMAL

  === REPLACEMENT ===
  jit_inject_variables(source)
  replacement = jit_make_python_command(fingerprint, original, args, source)
  execute_command(replacement)
  dispose_command(replacement)
  DONE

  === NORMAL ===
  Report to daemon (non-blocking send, inline in bash_jit_check):
    {"type":"exec", "fingerprint":"...", "source":"...", "context":{...}}
         |
         v
  execute via normal bash (execute_command_internal)
  DONE
```

**Important**: `make_command_string()` returns a pointer to a **static buffer** (`the_printed_command` in `print_cmd.c:105`). During normal bash execution, this buffer is overwritten by `set -x` tracing, subshell execution, and other internal calls. Therefore the JIT code must `savestring()` the result immediately — it cannot hold the raw pointer across execution.

### 4.2 Daemon Flow

```
Daemon receives: {"type":"exec", "fingerprint":"abc123...", "source":"for i in ..."}
         |
         v
  global_counter[fingerprint]++
         |
         v
  global_counter[fingerprint] >= threshold? --No--> done
         |
        Yes (first time crossing threshold)
         v
  1. Store source text for this fingerprint
  2. Build LLM prompt with source + context
  3. Call LLM API
  4. Validate result (syntax + static analysis)
  5. Write to $CACHE_DIR/<fingerprint>/compiled.py
  (Next bash process that sees this fingerprint will find the .py file)
```

### 4.3 Cross-Process Scenario

```
Process A: bash loop.sh (1st run)
  -> reader_loop parses commands, fingerprints them
  -> reports to daemon: "executed fp1, fp2, fp3"
  -> daemon counters: fp1=1, fp2=1, fp3=1
  -> executes normally
  -> exits

Process B: bash loop.sh (2nd run)
  -> same fingerprints: fp1, fp2, fp3
  -> daemon counters: fp1=2, fp2=2, fp3=2
  -> executes normally

...

Process 100: bash loop.sh (100th run)
  -> daemon counters: fp1=100 -> crosses threshold!
  -> daemon compiles fp1 to Python
  -> writes $CACHE_DIR/fp1/compiled.py
  -> this process still executes normally (compiled version not ready yet)

Process 101: bash loop.sh (101st run)
  -> reader_loop parses command with fingerprint fp1
  -> local cache check finds is_compiled == 1
  -> construct replacement COMMAND(cm_simple, words=["python3", "/cache/fp1/compiled.py"])
  -> execute_command(replacement) -> python3 runs
  -> JIT-accelerated execution!
```

### 4.4 Known Limitation: Compile Timing

Hot code reaches the compilation threshold after N executions. The LLM translation takes seconds to minutes. By the time the compiled version is ready, the current script execution may have already passed that code path. Benefits primarily accrue to **future** invocations of the same script.

For scripts that loop internally (e.g., a `for` loop running 10000 iterations), the compiled version becomes available partway through and the remaining iterations benefit. For scripts that execute once and exit, there is no benefit unless the daemon's cache persists from a previous run.

**Mitigation**: The daemon persists its counter and cache to disk. Once a script has been "warmed up" (executed enough times historically), subsequent runs immediately find compiled versions.

## 5. Component Design

### 5.1 C-Side: `bash_jit.c` + `bash_jit.h`

#### 5.1.1 Core Data Structures

```c
/* Per-snippet tracking (in-process, for cache check optimization) */
typedef struct {
  unsigned long local_count;    /* in-process execution count */
  int is_compiled;              /* 1=compiled, 0=unchecked, -1=confirmed uncompiled */
  char *fingerprint;            /* heap-allocated 32-char hex string */
} jit_snippet_entry;

/* Global state */
static HASH_TABLE *jit_local_cache;  /* fingerprint -> jit_snippet_entry */
static int jit_socket = -1;          /* Unix socket to daemon */
static int bash_jit_enabled = 0;     /* 1 if BASH_JIT is set */

/* Return values for bash_jit_check() */
#define JIT_CHECK_NORMAL     0   /* proceed with normal bash execution */
#define JIT_CHECK_COMPILED   1   /* use the replacement command */
```

#### 5.1.2 Fingerprint Computation: 128-bit FNV-1a

Bash's `hashlib.c` implements a 32-bit FNV-1a variant. The JIT extends this to 128 bits using a dual-pass technique: run FNV-1a twice with different seeds and concatenate the results. The codebase already documents the 64-bit FNV constants at `hashlib.c:200-203`.

```c
/*
 * FNV-1a with two different offsets, producing a 128-bit digest.
 * Serialized as a 32-character lowercase hex string.
 *
 * FNV-1a reference: http://www.isthe.com/chongo/tech/comp/fnv/
 * Bash's existing 32-bit constants: hashlib.c:197-198
 */

#define FNV_OFFSET_A  2166136261u   /* standard FNV offset basis */
#define FNV_OFFSET_B  2166136263u   /* offset + 2, for second pass */

static void
fnv128_hex (const char *input, char out[33])
{
  unsigned int h1 = FNV_OFFSET_A, h2 = FNV_OFFSET_B;
  unsigned int h3 = FNV_OFFSET_A ^ 0x5bd1e995;  /* murmur constant for mixing */
  unsigned int h4 = FNV_OFFSET_B ^ 0x5bd1e995;
  const unsigned char *s = (const unsigned char *)input;

  while (*s)
    {
      unsigned int c = *s++;
      /* FNV-1a: XOR then multiply (shift-add approximation from hashlib.c:217) */
      h1 ^= c; h1 += (h1<<1) + (h1<<4) + (h1<<7) + (h1<<8) + (h1<<24);
      h2 ^= c; h2 += (h2<<1) + (h2<<4) + (h2<<7) + (h2<<8) + (h2<<24);
      h3 ^= c; h3 += (h3<<1) + (h3<<4) + (h3<<7) + (h3<<8) + (h3<<24);
      h4 ^= c; h4 += (h4<<1) + (h4<<4) + (h4<<7) + (h4<<8) + (h4<<24);
    }

  sprintf(out, "%08x%08x%08x%08x", h1, h2, h3, h4);
  out[32] = '\0';
}
```

#### 5.1.3 Context Hash

The fingerprint includes runtime context to ensure cache invalidation when the execution environment changes:

```c
/*
 * Compute a context hash from the current execution environment.
 * Appended to source text before fingerprinting.
 *
 * Strategy: snapshot ALL currently defined functions (name + body hash),
 * plus relevant shell options. This is conservative — redefining any
 * function invalidates ALL cache entries — but correct and simple.
 *
 * Rationale for "all functions" instead of "referenced functions":
 *   Statically determining which functions a bash command references is
 *   undecidable in general (dynamic dispatch via "$funcname", variables
 *   containing command names, etc.). The eligible subset excludes eval/exec,
 *   but even within it, command names can come from variable expansions.
 *   Hashing ALL functions is O(n) in function count (typically < 100),
 *   guarantees no false cache hits, and unnecessary invalidation is
 *   acceptable for a JIT cache.
 *
 * Uses: all_shell_functions() from variables.c,
 *       named_function_string() from print_cmd.c.
 */
static char *
jit_build_context (void)
{
  BUFFER *buf;
  SHELL_VAR **funcs;
  int i;

  buf = xmalloc (sizeof (BUFFER));
  buf->b = NULL;
  buf->indx = 0;

  /* Append all function definitions: name\\0body_hash\\0 */
  funcs = all_shell_functions ();
  if (funcs)
    {
      for (i = 0; funcs[i]; i++)
        {
          COMMAND *body = function_cell (funcs[i]);
          char *body_str;
          char body_hash[33];

          body_str = named_function_string (
              funcs[i]->name, body, FUNC_MULTILINE | FUNC_EXTERNAL);
          fnv128_hex (body_str, body_hash);
          free (body_str);

          /* name\0body_hash\0 */
          buf = buf_concat (buf, funcs[i]->name, strlen (funcs[i]->name));
          buf = buf_concat (buf, "\0", 1);
          buf = buf_concat (buf, body_hash, 32);
          buf = buf_concat (buf, "\0", 1);
        }
      free (funcs);
    }

  /* Append shell options bitmap as hex */
  {
    unsigned int optbits = 0;
    if (exit_immediately_on_error) optbits |= 0x01;  /* set -e */
    if (bash_syslog_history)       optbits |= 0x02;  /* unused placeholder */
    if (nounset_on)                optbits |= 0x04;  /* set -u */
    if (pipefail_opt)              optbits |= 0x08;  /* set -o pipefail */
    if (disallow_filename_globbing) optbits |= 0x10; /* set -f */

    char optbuf[16];
    snprintf (optbuf, sizeof (optbuf), "opts:%x", optbits);
    buf = buf_concat (buf, optbuf, strlen (optbuf));
  }

  return buf->b;  /* caller must free */
}
```

The context string is concatenated to the source text with a `\0` separator before hashing:

```c
char *source = savestring (make_command_string (command));
char *context = jit_build_context ();
/* Concatenate: source \0 context */
size_t src_len = strlen (source);
size_t ctx_len = strlen (context);  /* context may contain \0, see below */
size_t total = src_len + 1 + ctx_len;
char *fp_input = xmalloc (total + 1);
memcpy (fp_input, source, src_len + 1);        /* includes trailing \0 */
memcpy (fp_input + src_len + 1, context, ctx_len + 1);

char fingerprint[33];
fnv128_hex (fp_input, fingerprint);
```

#### 5.1.4 Main Interface: `bash_jit_check()`

This is the single entry point called at each interception point. It performs the check AND reports to the daemon in one call, avoiding any global state between check and report.

**Why no separate report function**: The earlier design used `bash_jit_check()` + `bash_jit_report()` with global `pending_fingerprint`/`pending_source` state. This caused a **nested interception bug**: when `parse_and_execute()` is called during normal execution of an outer command (e.g., via `source`), the inner interception overwrites the pending report data, causing the outer command's execution to never be reported. By reporting immediately inside `bash_jit_check()`, each invocation is self-contained and nesting is safe — the inner call reports its own fingerprint, and the outer call reports its own fingerprint.

```c
/*
 * Check whether a command should be JIT-accelerated.
 *
 * If a compiled version exists and is eligible:
 *   - Sets *replacement to a new COMMAND that runs python3
 *   - Returns JIT_CHECK_COMPILED
 *   Caller should execute_command(replacement), then dispose_command(replacement)
 *
 * If no compiled version exists:
 *   - Returns JIT_CHECK_NORMAL
 *   - Caller should execute the original command normally
 *   - This function has already reported the execution to the daemon
 *
 * IMPORTANT: make_command_string() returns a pointer to a static buffer.
 * We must savestring() immediately and never hold the raw pointer.
 */
int
bash_jit_check (COMMAND *command, WORD_LIST *args,
                COMMAND **replacement)
{
  char *source, fingerprint[33];
  jit_snippet_entry *entry;
  BUCKET_CONTENTS *item;

  *replacement = NULL;

  if (!bash_jit_enabled)
    return JIT_CHECK_NORMAL;

  /* 1. Get normalized source text (MUST savestring — static buffer!) */
  source = savestring (make_command_string (command));
  if (!source || !*source)
    {
      FREE (source);
      return JIT_CHECK_NORMAL;
    }

  /* 2. Check eligibility (see Section 5.2) */
  if (!jit_is_eligible (command, source))
    {
      FREE (source);
      return JIT_CHECK_NORMAL;
    }

  /* 3. Compute fingerprint with context */
  {
    char *context = jit_build_context ();
    size_t len = strlen(source) + 1 + strlen(context);
    char *fp_input = xmalloc(len + 1);
    memcpy(fp_input, source, strlen(source) + 1);
    memcpy(fp_input + strlen(source) + 1, context, strlen(context) + 1);
    fnv128_hex(fp_input, fingerprint);
    FREE(fp_input);
    FREE(context);
  }

  /* 4. Check local cache */
  item = hash_search(fingerprint, jit_local_cache, HASH_CREATE);
  if (item->data)
    {
      entry = (jit_snippet_entry *)item->data;
      if (entry->is_compiled == 1)
        {
          /* Already known to be compiled */
          *replacement = jit_make_python_command(fingerprint, command, args, source);
          FREE(source);
          return JIT_CHECK_COMPILED;
        }

      entry->local_count++;

      /* Periodically check filesystem (every 10 invocations) */
      if (entry->is_compiled == 0 && entry->local_count % 10 == 0)
        {
          char cache_path[512];
          snprintf(cache_path, sizeof(cache_path),
                   "%s/%s/compiled.py", jit_cache_dir, fingerprint);
          if (access(cache_path, R_OK) == 0)
            {
              if (jit_verify_cache(fingerprint, source))
                {
                  entry->is_compiled = 1;
                  *replacement = jit_make_python_command(fingerprint, command, args, source);
                  FREE(source);
                  return JIT_CHECK_COMPILED;
                }
              else
                {
                  /* Collision or corruption — remove and skip */
                  jit_invalidate_cache(fingerprint);
                  entry->is_compiled = -1;
                }
            }
          /* After many checks with no result, stop checking */
          if (entry->local_count > 100)
            entry->is_compiled = -1;
        }
    }
  else
    {
      /* First time seeing this fingerprint */
      entry = xmalloc(sizeof(jit_snippet_entry));
      entry->local_count = 1;
      entry->is_compiled = 0;
      entry->fingerprint = savestring(fingerprint);
      item->data = (PTR_T)entry;
    }

  /* 5. Report to daemon (fire-and-forget, non-blocking) */
  jit_send_exec_report(fingerprint, source);
  FREE(source);

  return JIT_CHECK_NORMAL;
}
```

#### 5.1.5 Reporting to Daemon: `jit_send_exec_report()`

Inline helper called by `bash_jit_check()`. Sends a single fire-and-forget message to the daemon. No global state, no pending data.

```c
/*
 * Send an exec report to the daemon. Fire-and-forget via non-blocking send.
 * Called from bash_jit_check() — no global state between calls.
 */
static void
jit_send_exec_report (const char *fingerprint, const char *source)
{
  char msg[8192];
  int msg_len;

  if (jit_socket < 0)
    return;

  /* Build exec message (fire-and-forget) */
  msg_len = snprintf(msg, sizeof(msg),
    "{\"type\":\"exec\",\"fingerprint\":\"%s\",\"source\":\"%s\","
    "\"context\":{\"pid\":%d,\"source_file\":\"%s\"}}\n",
    fingerprint,
    jit_json_escape(source),
    (int)getpid(),
    jit_json_escape(get_string_value("BASH_SOURCE") ? : ""));

  if (msg_len > 0 && msg_len < (int)sizeof(msg))
    send(jit_socket, msg, msg_len, MSG_DONTWAIT | MSG_NOSIGNAL);
}
```

#### 5.1.6 Helper Functions

The following helper functions must be implemented in `bash_jit.c`:

**`jit_json_escape()` — JSON string escaping per RFC 8259**:

Escapes `\`, `"`, and all control characters below U+0020 using `\uXXXX`. Returns a pointer to a heap-allocated string. Input strings containing NUL bytes are rejected (bash strings are NUL-terminated, so this shouldn't occur in practice, but the function handles the edge case by truncating at NUL).

```c
/* Must handle: \ → \\, " → \", \n → \n, \r → \r, \t → \t,
   and all other control chars (0x00-0x1F) → \uXXXX */
static char *
jit_json_escape (const char *input);
```

**`jit_read_file()` — Read a small file into a heap buffer**:

Uses POSIX `open()/fstat()/read()/close()`. Returns NULL on failure. Used by `jit_verify_cache()` to read `meta.json`.

```c
static char *
jit_read_file (const char *path, size_t *out_len);
```

**`jit_json_extract()` — Extract a named string field from flat JSON**:

A simple state-machine parser that handles `\"` and `\\` escapes. Not a full JSON parser — only extracts top-level string fields. Used by `jit_verify_cache()` to extract `source_text` from `meta.json`.

```c
/* Returns a heap-allocated copy of the value, or NULL if not found. */
static char *
jit_json_extract (const char *json, const char *key);
```

### 5.2 JIT Eligibility Criteria

Not all bash commands can be correctly translated to Python. The following criteria define what is eligible for JIT compilation. Commands that fail any criterion are silently skipped — no overhead beyond the eligibility check itself.

#### 5.2.1 Eligibility Rules

| Rule | Check | Rationale |
|------|-------|-----------|
| Command type | Allow `cm_simple`, `cm_for`, `cm_while`, `cm_arith_for`, `cm_arith` | Compound commands with complex branching (`cm_if`/`cm_case`) are excluded |
| No state-modifying builtins | Exclude builtins that modify shell state: `cd`, `pushd`, `popd`, `export`, `local`, `declare`, `typeset`, `readonly`, `unset`, `shift`, `trap`, `read`, `set`, `unset`, `umask`, `ulimit`, `getopts`, `return`, `exit`, `break`, `continue`, `wait`, `kill`, `jobs`, `bg`, `fg`, `disown`, `suspend`, `logout`, `times`, `hash` | These modify shell state or control flow that cannot be replicated in a subprocess |
| Pure builtins allowed | `echo`, `printf`, `test`, `[`, `[[`, `true`, `false`, `:` are eligible | These are I/O or computational and can be translated to Python (`print()`, string formatting, boolean expressions) |
| Variable references | Non-exported variables are allowed — they are injected into the Python process environment (see Section 5.4.1) | The variable injection mechanism makes most variable usage safe |
| No variable assignments | The command must not contain `VAR=...` assignments (outside of loop variables in `for`/`while`) | Assignments in the JIT'd code won't propagate back to bash — subsequent commands would see stale values |
| No `eval`/`exec`/`source` | Source must not contain these builtins | These require a full bash interpreter |
| No process substitution | No `<(...)` or `>(...)` constructs | These depend on bash's fd management |
| No here-documents | No `<<` or `<<<` redirections | These depend on bash's parsing and expansion rules |
| Minimum complexity | `strlen(source) > JIT_MIN_COMPLEXITY` (default: 50 chars) | Small commands are slower via python3 due to fork+exec overhead; see Section 9 for analysis |

**Why this is broader than "only external commands"**: The previous design excluded ALL builtins and ALL non-exported variables. In practice, the most common hot code patterns in bash scripts are:
- `for`/`while` loops with `echo` or `printf` inside (now eligible — `echo` maps to `print()`)
- Loops that reference shell variables like `$DIR`, `$PREFIX` (now eligible — via variable injection)
- `test`/`[` commands in loops (now eligible — maps to Python boolean expressions)

The key insight is that bash's per-iteration overhead (variable expansion, word splitting, command dispatch) × loop count often far exceeds python3's one-time fork+exec cost. See Section 9 for the quantitative analysis.

#### 5.2.2 Builtin Classification

Bash classifies builtins via `struct builtin` flags in `builtins.h`:
- `SPECIAL_BUILTIN` (0x08): POSIX special builtins (`break`, `cd`, `continue`, `eval`, `exec`, `exit`, `export`, `readonly`, `return`, `set`, `shift`, `trap`, `unset`, `.`)
- `ASSIGNMENT_BUILTIN` (0x10): Builtins that take assignment statements (`declare`, `export`, `local`, `readonly`, `typeset`)
- `LOCALVAR_BUILTIN` (0x40): Builtins that create local variables (`declare`, `local`, `typeset`)

The JIT uses these flags to classify builtins into three categories:

| Category | Examples | JIT eligible? |
|----------|----------|---------------|
| State-modifying | `cd`, `export`, `local`, `shift`, `trap`, `read`, `set`, `return`, `exit`, `break`, `continue`, `wait`, `kill`, `umask` | **No** — modifies shell state or control flow |
| I/O / computational | `echo`, `printf`, `test`, `[`, `true`, `false`, `:` | **Yes** — can be translated to Python equivalents |
| Interpreter-dependent | `eval`, `exec`, `source`/`.`, `eval` | **No** — requires bash interpreter at runtime |

#### 5.2.3 Implementation

```c
/*
 * Check if a command is eligible for JIT compilation.
 * Returns 1 if eligible, 0 if not.
 *
 * This is a conservative check — when in doubt, return 0.
 */
static int
jit_is_eligible (COMMAND *command, const char *source)
{
  /* Length check — fork+exec python3 costs ~2-5ms */
  if (strlen(source) < jit_min_complexity)
    return 0;

  /* Command type check */
  switch (command->type)
    {
    case cm_simple:
    case cm_for:
    case cm_while:
    case cm_arith:
#if defined (ARITH_FOR_COMMAND)
    case cm_arith_for:
#endif
      break;
    default:
      return 0;  /* cm_if, cm_case, cm_connection, cm_group, etc. */
    }

  /* Check for excluded constructs in source text */
  if (strstr(source, "eval ") || strstr(source, "eval("))
    return 0;
  if (strstr(source, "exec "))
    return 0;
  if (strstr(source, "source ") || strstr(source, ". "))
    return 0;
  if (strstr(source, "<(") || strstr(source, ">("))
    return 0;
  if (strstr(source, "<<") || strstr(source, "<<<"))
    return 0;

  /* Check for variable assignments (outside of for loop variables) */
  if (jit_has_assignments(command))
    return 0;

  /* For cm_simple: check that the command is not a state-modifying builtin */
  if (command->type == cm_simple)
    {
      WORD_LIST *words = command->value.Simple->words;
      /* Skip leading assignment words (VAR=val prefix) */
      while (words && (words->word->flags & W_ASSIGNMENT))
        words = words->next;
      if (words && words->word && words->word->word)
        {
          char *cmd_name = words->word->word;
          if (jit_is_state_modifying_builtin(cmd_name))
            return 0;
        }
    }

  return 1;
}

/*
 * Check if a builtin modifies shell state.
 * Uses bash's builtin_address_internal() to look up flags.
 * Returns 1 for state-modifying builtins, 0 otherwise.
 */
static int
jit_is_state_modifying_builtin (const char *name)
{
  struct builtin *b;
  b = builtin_address_internal(name, 1);
  if (!b || !(b->flags & BUILTIN_ENABLED))
    return 0;  /* Not a builtin — external command, eligible */

  /* Special builtins are generally state-modifying */
  if (b->flags & SPECIAL_BUILTIN)
    return 1;

  /* Assignment/local-var builtins modify shell state */
  if (b->flags & (ASSIGNMENT_BUILTIN | LOCALVAR_BUILTIN))
    return 1;

  /* Check against explicit state-modifying list */
  /* (builtins that modify state but lack the above flags) */
  static const char *state_modifying[] = {
    "cd", "pushd", "popd", "dirs", "read", "shift",
    "trap", "umask", "ulimit", "getopts", "wait",
    "kill", "jobs", "bg", "fg", "disown", "suspend",
    "logout", "times", "hash", NULL
  };
  for (int i = 0; state_modifying[i]; i++)
    if (STREQ(name, state_modifying[i]))
      return 1;

  return 0;  /* Pure builtin (echo, printf, test, etc.) — eligible */
}

/*
 * Check if a command tree contains variable assignments
 * that would be lost when executed in a subprocess.
 * For-loop variables (for i in ...) are NOT considered assignments.
 */
static int
jit_has_assignments (COMMAND *command)
{
  switch (command->type)
    {
    case cm_simple:
      /* Assignment words are detected by W_ASSIGNMENT flag.
         Leading assignment words (VAR=val cmd) are OK — they become
         environment variables for the command.
         We only flag if there are assignments embedded in the command. */
      {
        WORD_LIST *w;
        int saw_non_assignment = 0;
        for (w = command->value.Simple->words; w; w = w->next)
          {
            if (w->word->flags & W_ASSIGNMENT)
              {
                if (saw_non_assignment)
                  return 1;  /* Assignment after command word — unusual but exclude */
              }
            else
              saw_non_assignment = 1;
          }
      }
      return 0;

    case cm_for:
    case cm_arith_for:
      /* Loop variable assignments are OK — Python handles them natively.
         Check the loop BODY for assignments. */
      return jit_has_assignments_in_body(command);

    case cm_while:
      /* Check both condition and body */
      return (jit_has_assignments_in_tree(execute_command_internal_condition(command)) ||
              jit_has_assignments_in_body(command));

    default:
      return 0;
    }
}
```

### 5.3 Interception Points in Bash Source

All interception points follow the same pattern: call `bash_jit_check()`, then either execute the replacement or execute normally and report.

#### Point 1: `reader_loop()` in `eval.c:183`

```c
// Before:
//   execute_command(current_command);

// After:
#if defined (BASH_JIT)
  {
    COMMAND *jit_cmd = NULL;

    if (bash_jit_check(current_command, NULL, &jit_cmd)
        == JIT_CHECK_COMPILED)
      {
        execute_command(jit_cmd);
        dispose_command(jit_cmd);
      }
    else
#endif
      {
        execute_command(current_command);
#if defined (BASH_JIT)
      }
#endif
  }
```

#### Point 2: `parse_and_execute()` in `evalstring.c:567`

Same pattern as Point 1:

```c
// Before:
//   last_result = execute_command_internal(command, 0, NO_PIPE, NO_PIPE, bitmap);

// After:
#if defined (BASH_JIT)
  {
    COMMAND *jit_cmd = NULL;

    if (bash_jit_check(command, NULL, &jit_cmd)
        == JIT_CHECK_COMPILED)
      {
        last_result = execute_command(jit_cmd);
        dispose_command(jit_cmd);
      }
    else
#endif
      {
        last_result = execute_command_internal(command, 0, NO_PIPE, NO_PIPE, bitmap);
#if defined (BASH_JIT)
      }
#endif
  }
```

#### Point 3: `execute_function()` in `execute_cmd.c:5181`

For function calls, the fingerprint is computed from the function body source, and arguments are passed through to the Python script:

```c
// After funcnest_max check (around line 5206):
#if defined (BASH_JIT)
  {
    COMMAND *jit_cmd = NULL;

    if (bash_jit_function_check(var, words, &jit_cmd)
        == JIT_CHECK_COMPILED)
      {
        return execute_command(jit_cmd);
        /* dispose happens in execute_command's normal cleanup */
      }
  }
#endif

// ... normal function body execution ...
// (no separate report call needed — report happens inside check function)
```

#### Point 4: `execute_intern_function()` in `execute_cmd.c:6336`

When bash defines a function (`cm_function_def`), register it with daemon for context:

```c
// After bind_function(name->word, funcdef->command) (line 6336):
#if defined (BASH_JIT)
  if (bash_jit_enabled)
    bash_jit_register_function(name->word, funcdef->command);
#endif
```

### 5.4 Command Replacement: `jit_make_python_command()`

#### 5.4.1 Variable Injection

The Python subprocess cannot directly access bash's non-exported variables. The JIT solves this by **injecting referenced variables into the Python process's environment** via bash's `temporary_env` mechanism.

**How it works**:
1. When constructing the replacement command, scan the source text for `$VAR` and `${VAR}` references
2. For each referenced variable, look up its current value using `find_variable()`
3. Add non-exported variables to `temporary_env` (bash's mechanism for `VAR=val cmd` assignments)
4. `maybe_make_export_env()` includes `temporary_env` in the environment array
5. After the replacement command executes, `dispose_used_env_vars()` cleans up automatically

This leverages bash's existing `temporary_env` infrastructure (used for `VAR=val command` syntax). No manual cleanup needed — bash's `execute_simple_command()` calls `dispose_used_env_vars()` after execution.

```c
/*
 * Inject non-exported shell variables referenced in the source
 * into temporary_env, making them available to the Python subprocess.
 *
 * Uses bash's temporary_env mechanism (same as VAR=val cmd).
 * Cleanup is automatic: dispose_used_env_vars() is called by
 * execute_simple_command() after the replacement command completes.
 *
 * Variables that are already exported, functions, arrays, or
 * special parameters are skipped.
 */
static void
jit_inject_variables (const char *source)
{
  const char *s;
  char varname[256];
  int vlen;

  if (!source)
    return;

  for (s = source; *s; s++)
    {
      /* Look for $VAR or ${VAR} patterns */
      if (*s != '$')
        continue;

      s++;  /* skip '$' */

      /* ${VAR} form */
      if (*s == '{')
        {
          s++;
          vlen = 0;
          while (*s && *s != '}' && vlen < sizeof(varname) - 1)
            {
              if (!isalnum((unsigned char)*s) && *s != '_')
                break;
              varname[vlen++] = *s++;
            }
          varname[vlen] = '\0';
          if (*s == '}')
            s++;
          else
            continue;
        }
      /* $VAR form — collect alphanumeric/underscore */
      else if (isalpha((unsigned char)*s) || *s == '_')
        {
          vlen = 0;
          while (*s && (isalnum((unsigned char)*s) || *s == '_')
                 && vlen < sizeof(varname) - 1)
            varname[vlen++] = *s++;
          varname[vlen] = '\0';
          s--;  /* will be incremented by for loop */
        }
      else
        continue;

      if (vlen == 0)
        continue;

      /* Skip special parameters: $?, $#, $@, $*, $$, $!, $_ */
      if (strlen(varname) == 1 && strchr("?#@*!_", varname[0]))
        continue;

      /* Look up the variable */
      SHELL_VAR *var = find_variable(varname);
      if (!var)
        continue;

      /* Skip if already exported, is a function, or is an array */
      if (exported_p(var) || function_p(var) || array_p(var))
        continue;

      /* Get the value */
      char *val = get_variable_value(var);
      if (!val)
        continue;

      /* Add to temporary_env (same mechanism as VAR=val cmd) */
      if (temporary_env == 0)
        temporary_env = hash_create(TEMPENV_HASH_BUCKETS);

      SHELL_VAR *tvar = hash_lookup(varname, temporary_env);
      if (!tvar)
        {
          tvar = make_new_variable(varname, temporary_env);
          tvar->attributes |= (att_exported | att_tempvar);
        }
      var_setvalue(tvar, savestring(val));
    }

  /* Rebuild the export environment to include injected variables */
  if (temporary_env)
    maybe_make_export_env();
}
```

**Limitations of variable injection**:
- Values are snapshotted at JIT check time. If the JIT'd code modifies a variable, the change is NOT propagated back to bash. This is why the eligibility check (Section 5.2.1) excludes commands with variable assignments.
- Array variables cannot be injected (environment variables are scalar strings).
- Special parameters (`$?`, `$#`, `$@`, etc.) cannot be injected — the compiled Python script receives them via `sys.argv` or must recompute them.

#### 5.4.2 Top-level Commands

Constructs a `cm_simple` command that invokes `python3` with the compiled script. Injects referenced non-exported variables into the environment. Preserves the original command's redirects correctly.

```c
/*
 * Build a replacement COMMAND that runs: python3 <cache_path> [args...]
 * Inherits redirects from the original command.
 * Injects referenced non-exported variables via temporary_env.
 *
 * IMPORTANT: Redirects live at different levels depending on command type.
 * For cm_simple: redirects are in command->value.Simple->redirects
 * For compound commands (cm_for, cm_while, etc.): redirects are in command->redirects
 */
COMMAND *
jit_make_python_command (const char *fingerprint, COMMAND *original,
                         WORD_LIST *args, const char *source)
{
  COMMAND *cmd;
  SIMPLE_COM *simple;
  WORD_LIST *words, *tail;
  char python_path[512];

  /* 1. Inject non-exported variables referenced in source */
  jit_inject_variables(source);

  /* 2. Build word list: python3 <cache_path> */
  snprintf(python_path, sizeof(python_path),
           "%s/%s/compiled.py", jit_cache_dir, fingerprint);

  words = make_word_list(make_word("python3"), NULL);
  tail = words;
  tail->next = make_word_list(make_word(python_path), NULL);
  tail = tail->next;

  /* 3. Copy prefix assignment words from original (e.g., VAR=val cmd) */
  if (original->type == cm_simple)
    {
      WORD_LIST *orig_words = original->value.Simple->words;
      while (orig_words && (orig_words->word->flags & W_ASSIGNMENT))
        {
          WORD_LIST *assign_word;
          assign_word = make_word_list(copy_word(orig_words->word), NULL);
          assign_word->word->flags |= W_ASSIGNMENT;
          /* Insert before python3 */
          assign_word->next = words;
          words = assign_word;
          orig_words = orig_words->next;
        }
    }

  /* 4. Append extra arguments (for function calls) */
  while (args)
    {
      tail->next = make_word_list(copy_word(args->word), NULL);
      tail = tail->next;
      args = args->next;
    }

  /* 5. Extract redirects from the correct location */
  REDIRECT *redirs;
  if (original->type == cm_simple)
    redirs = original->value.Simple->redirects;
  else
    redirs = original->redirects;

  /* 6. Construct new cm_simple */
  simple = (SIMPLE_COM *)xmalloc(sizeof(SIMPLE_COM));
  simple->words = words;
  simple->redirects = redirs;  /* Inherit redirects */
  simple->flags = 0;
  simple->line = original->line;

  cmd = (COMMAND *)xmalloc(sizeof(COMMAND));
  cmd->type = cm_simple;
  cmd->flags = original->flags;
  cmd->redirects = NULL;   /* Already in SIMPLE_COM */
  cmd->value.Simple = simple;

  return cmd;
}
```

This replacement command flows through `execute_command()` → `execute_command_internal()` → `execute_simple_command()` → `execute_disk_command()` → `make_child()` + `execve("python3", ...)`. Bash's full pipe, redirect, signal, and job control infrastructure is reused. The `temporary_env` entries are cleaned up by `dispose_used_env_vars()` in `execute_command_internal()` after the command completes.

#### 5.4.3 Function Calls

Function calls need to pass the function's positional parameters as arguments to the Python script, and inject non-exported variables from the calling context:

```c
int
bash_jit_function_check (SHELL_VAR *var, WORD_LIST *words,
                         COMMAND **replacement)
{
  char *body_source;
  char fingerprint[33];

  *replacement = NULL;

  if (!bash_jit_enabled)
    return JIT_CHECK_NORMAL;

  /* Get function body source */
  body_source = savestring(
    named_function_string(var->name, function_cell(var), FUNC_MULTILINE));
  if (!body_source)
    return JIT_CHECK_NORMAL;

  /* Compute fingerprint from function body */
  /* ... (same pattern as bash_jit_check) ... */

  /* If compiled, construct replacement with function arguments */
  if (entry->is_compiled == 1)
    {
      jit_inject_variables(body_source);
      *replacement = jit_make_python_command_with_args(fingerprint, words);
      return JIT_CHECK_COMPILED;
    }

  /* Report to daemon (inline, same as bash_jit_check) */
  jit_send_exec_report(fingerprint, body_source);
  FREE(body_source);
  return JIT_CHECK_NORMAL;
}

/*
 * Build: python3 <cache_path> arg1 arg2 ...
 * 'words' is the function call's argument list (includes function name as first word).
 * The function name is skipped; remaining words become python3 arguments.
 */
COMMAND *
jit_make_python_command_with_args (const char *fingerprint, WORD_LIST *func_args)
{
  WORD_LIST *words, *tail;
  char python_path[512];

  snprintf(python_path, sizeof(python_path),
           "%s/%s/compiled.py", jit_cache_dir, fingerprint);

  words = make_word_list(make_word("python3"), NULL);
  tail = words;
  tail->next = make_word_list(make_word(python_path), NULL);
  tail = tail->next;

  /* Skip function name (first word), pass the rest as arguments */
  if (func_args)
    func_args = func_args->next;
  while (func_args)
    {
      tail->next = make_word_list(copy_word(func_args->word), NULL);
      tail = tail->next;
      func_args = func_args->next;
    }

  /* ... construct COMMAND (same as jit_make_python_command) ... */
}
```

#### 5.4.3 Execution Sequence

```
Scenario: for i in $(seq 100); do echo "$PREFIX: $i"; done  (fingerprint=FP1, compiled)

reader_loop()
  └→ parse_command() → yyparse()
       → global_command = COMMAND(cm_for, ...)

  └→ bash_jit_check(global_command, NULL, &replacement)
       → source = savestring(make_command_string(global_command))
       → fingerprint = fnv128_hex(source + context)
       → entry->is_compiled == 1
       → jit_inject_variables(source)
           → scans source for $PREFIX, finds non-exported variable
           → adds PREFIX="current_value" to temporary_env
           → calls maybe_make_export_env()
       → replacement = COMMAND(cm_simple, words=["python3", "/cache/FP1/compiled.py"])
       → return JIT_CHECK_COMPILED

  └→ execute_command(replacement)
       → execute_command_internal(replacement)
         → cm_simple → execute_simple_command()
           → words expanded: ["python3", "/cache/FP1/compiled.py"]
           → not a builtin, not a function
           → execute_disk_command()
             → make_child("python3")
               → child: execve("python3", ["/cache/FP1/compiled.py"], export_env)
                         export_env includes PREFIX from temporary_env
               → parent: wait_for(pid)
         → dispose_used_env_vars()  ← cleans up temporary_env (removes PREFIX)
         → collect exit code → return

  └→ dispose_command(replacement)
```

### 5.5 Daemon: `bash_jitd`

#### 5.5.1 Role Separation

```
Role            Responsibility                                  Does NOT
─────────────────────────────────────────────────────────────────────────
bash (C)        Report executions, discover compiled results     Decide when to compile
                Execute replacement commands                     Call LLM
daemon          Count, detect hot spots, compile via LLM         Execute Python code
                Write cache files                                Participate in execution path
CLI (jit)       User manual compile, view status, manage cache   Participate in runtime path
python3         Execute compiled code                            Know about JIT system
```

Core principle: **bash only reports and discovers, daemon only counts and compiles**.

#### 5.5.2 Transport: Unix Domain Socket + JSON Lines

**Protocol**: Unix domain socket + JSON Lines (newline-delimited JSON messages).

**Connection model**: Each bash process establishes a **persistent connection** at initialization. Benefits:
- No per-message connection setup/teardown overhead
- Daemon detects bash process exit via connection close
- Multiple messages can be pipelined on one connection

**Message patterns**:

| Pattern | Use case | Bash-side behavior |
|---------|----------|--------------------|
| fire-and-forget | Report execution (`exec`, `register_function`) | Non-blocking send, no response expected |
| request-response | CLI management (`compile`, `status`, `flush`, `shutdown`) | Blocking send, wait for response |

#### 5.5.3 API Definitions

**API 1: `exec` — Report snippet execution** (bash → daemon, fire-and-forget)

```json
// Request (non-blocking, no response)
{
  "type": "exec",
  "fingerprint": "a1b2c3d4e5f6...",
  "source": "for i in $(seq 100); do process \"$i\"; done",
  "context": {
    "source_file": "script.sh",
    "function_name": null,
    "pid": 12345
  }
}
```

Daemon behavior:
1. `global_counters[fingerprint]++`
2. Store `source` and `context` (first time only)
3. If `count >= threshold` and not yet compiled and not failed → trigger async compilation

**API 2: `register_function` — Register function definition** (bash → daemon, fire-and-forget)

```json
// Request (non-blocking, no response)
{
  "type": "register_function",
  "name": "process_item",
  "fingerprint": "a1b2c3...",
  "generation": 1,
  "source": "process_item() {\n  local item=$1\n  echo \"$item\" | tr a-z A-Z\n}"
}
```

Daemon maintains `functions_registry[name] = {fingerprint, generation, source}`. The `generation` counter increments on each redefinition. If the generation changes, all cache entries referencing this function are invalidated.

**API 3: `compile` — Request compilation** (CLI → daemon → CLI, request-response)

```json
// Request
{
  "type": "compile",
  "source": "for i in $(seq 100); do ...",
  "force": false
}

// Response
{
  "type": "compile_response",
  "fingerprint": "a1b2c3...",
  "status": "ok" | "failed" | "skipped",
  "path": "/home/user/.cache/bash_jit/a1b2c3..../compiled.py",
  "error": "error message if failed"
}
```

**API 4: `compile_file` — Compile script file** (CLI → daemon → CLI, request-response)

```json
// Request
{
  "type": "compile_file",
  "path": "/path/to/script.sh",
  "force": false
}

// Response
{
  "type": "compile_file_response",
  "snippets": [
    {"fingerprint": "a1b2c3...", "source_preview": "for i in ...", "status": "ok", "path": "..."},
    {"fingerprint": "d4e5f6...", "source_preview": "echo done", "status": "ok", "path": "..."}
  ],
  "total": 5,
  "compiled": 4,
  "failed": 1
}
```

**API 5: `status` — Query daemon state** (CLI → daemon → CLI, request-response)

```json
// Request
{ "type": "status" }

// Response
{
  "type": "status_response",
  "uptime_seconds": 3600,
  "total_snippets": 150,
  "compiled_snippets": 12,
  "failed_snippets": 3,
  "total_exec_events": 50000,
  "top_hot": [
    {"fingerprint": "a1b2c3...", "source_preview": "for i in ...", "count": 5000, "status": "compiled"}
  ],
  "daemon_pid": 98765
}
```

**API 6: `clear` — Clear cache** (CLI → daemon → CLI, request-response)

```json
// Request
{ "type": "clear", "scope": "all" | "failed" | "compiled" }

// Response
{ "type": "clear_response", "removed_files": 5, "removed_counters": 150 }
```

**API 7: `shutdown` — Stop daemon** (CLI → daemon → CLI, request-response)

```json
// Request
{ "type": "shutdown" }

// Response
{ "type": "shutdown_response", "message": "daemon shutting down" }
```

#### 5.5.4 API Callers

| API | bash (C) | CLI (jit) | daemon |
|-----|----------|-----------|--------|
| `exec` | Send only | — | Receive and count |
| `register_function` | Send only | — | Receive and register |
| `compile` | Never | Send and wait | Receive and compile |
| `compile_file` | Never | Send and wait | Receive and compile |
| `status` | Never | Send and wait | Receive and respond |
| `flush` | Never | Send and wait | Receive and execute |
| `shutdown` | Never | Send and wait | Receive and exit |

#### 5.5.5 Bash-side Cache Discovery

Bash does not query the daemon for compilation status. Discovery is entirely **filesystem-based**:

```
bash executes command → compute fingerprint → check $CACHE_DIR/<fp>/compiled.py
                                                |
                                       access(path, R_OK) == 0 ?
                                       /                      \
                                     Yes                      No
                                      |                       |
                                verify source            normal bash execution
                                execute python3           then report to daemon
```

**Why not query the daemon**:
- `access()` is a single syscall (~0.5us), faster than socket communication
- Works even if the daemon crashes — as long as `.py` files exist, JIT works
- Simpler: bash C-side doesn't need to handle async responses

#### 5.5.6 Daemon Internal Architecture

```
bash_jitd
├── Unix Socket Server (asyncio)
│   ├── Persistent connection management (one per bash process)
│   ├── JSON Lines parsing
│   └── Message routing
│
├── Counter Manager
│   ├── global_counters: {fingerprint -> count}
│   ├── Periodic persistence to counters.json (every 60s)
│   └── Startup recovery from counters.json
│
├── Function Registry
│   ├── functions: {name -> {fingerprint, generation, source}}
│   └── Invalidation on generation change
│
├── Compile Worker (asyncio task pool)
│   ├── Compile queue (fingerprints awaiting compilation)
│   ├── LLM API calls
│   ├── Validation pipeline
│   └── Write cache files (atomic)
│
├── Cache Manager
│   ├── Write .py / .meta.json / .FAILED files
│   ├── TTL-based expiry (default: 30 days)
│   └── Size limit enforcement
│
└── Counter Persistence
    ├── Every 60 seconds: write counters.json
    ├── On SIGTERM: write counters.json
    └── On startup: read counters.json
```

#### 5.5.7 Compile Queue and Concurrency Control

```python
compile_semaphore = asyncio.Semaphore(3)  # Max 3 concurrent LLM calls

async def compile_worker(self, fingerprint):
    async with compile_semaphore:
        source = self.sources[fingerprint]
        context = self.build_context(fingerprint)
        try:
            python_code = await self.call_llm(source, context)
            self.validate_syntax(python_code)
            self.write_cache(fingerprint, python_code, source)
        except Exception as e:
            self.mark_failed(fingerprint, str(e))
```

#### 5.5.8 Counter Persistence

```json
// $CACHE_DIR/counters.json
{
  "version": 1,
  "last_updated": "2026-06-01T12:00:00Z",
  "snippets": {
    "a1b2c3...": {"count": 5000, "status": "compiled"},
    "d4e5f6...": {"count": 3200, "status": "failed"},
    "g7h8i9...": {"count": 150, "status": "not_compiled"}
  },
  "functions": {
    "process_item": {"generation": 2, "fingerprint": "x1y2z3..."}
  }
}
```

Daemon writes every 60 seconds. On startup, reads the file. Maximum data loss: 60 seconds of counters. Function generation counters survive restarts.

### 5.6 LLM Translation

#### 5.6.1 Context Enrichment

Before calling the LLM, the daemon enriches the source with:

1. **Called functions**: The daemon's function registry provides source code for any functions referenced in the snippet.
2. **External commands**: The daemon parses the source to find external commands (anything not a builtin or function). These become `subprocess` calls in Python.
3. **Environment variables**: All shell variables referenced in the source (both exported and non-exported) are available via `os.environ` thanks to the variable injection mechanism (Section 5.4.1).

#### 5.6.2 Prompt Template

```
You are translating a bash code snippet to Python for performance optimization.
The Python code must produce IDENTICAL observable behavior.

CONSTRAINTS:
- The Python script receives positional parameters as sys.argv[1:]
- All referenced shell variables ($VAR, ${VAR}) are available as os.environ["VAR"]
- stdin/stdout/stderr behave identically to bash
- Exit code: sys.exit(N) maps to bash exit code N

TRANSLATION RULES:
- echo → print() (handle -n, -e flags)
- printf → Python string formatting (f-strings or str.format)
- test / [ / [[ → Python boolean expressions
- External commands → subprocess.run(["cmd", "arg1", ...])
- for loops → Python for loops (native, no subprocess per iteration)
- Arithmetic $((expr)) → Python int expressions

SAFETY:
- Do NOT use eval() or exec() on dynamic strings
- Do NOT use subprocess with shell=True
- Do NOT access the filesystem beyond what the bash code does

Available bash functions (translate inline):
{called_functions}

Source to translate:
```bash
{source}
```

Output ONLY Python code, no explanations.
```

#### 5.6.3 What the LLM Prompt Explicitly Cannot Handle

The prompt acknowledges the following limitations. If the source contains any of these, the eligibility check (Section 5.2) should have already rejected it. This serves as a defense-in-depth layer:

- Dynamic scoping (variable lookup follows call chain)
- Word splitting and globbing on unquoted expansions
- Pipeline subshell semantics (variable assignments lost in pipes)
- `eval`, `exec`, `source` builtins
- Process substitution `<(...)` / `>(...)`
- Here-documents `<<` / `<<<`
- Trap handlers

### 5.7 Validation Pipeline

After the LLM returns Python code:

1. **Syntax check**: `compile(code, '<string>', 'exec')` — reject if it fails.
2. **Static analysis**: Check for dangerous patterns:
   - `os.system()`, `eval()`, `exec()` on untrusted input
   - Imports of suspicious modules (`pickle`, `subprocess` with `shell=True`)
   - File writes outside the cache directory
3. **Trust-but-verify**: For the first M executions (default: 5) after compilation, execute **both** the original bash command and the Python translation. Capture and compare stdout, stderr, AND exit codes. Log mismatches to `$BASH_JIT_LOG`. After M consistent results, trust the translation and stop dual execution.
4. **Timeout**: Kill validation after configurable seconds (default: 5).
5. **Side-effect isolation**: Commands that produce observable side effects (file writes, network calls, database modifications) are identified by the eligibility check and excluded from trust-but-verify. For these commands, validation relies on static analysis only (steps 1-2).
6. **On failure**: Write `FAILED` marker file, don't retry until source fingerprint changes.

**Why compare stdout/stderr, not just exit codes**: Exit-code-only comparison is insufficient — two programs can produce different output but the same exit code. Comparing stdout+stderr+exit code catches semantic mismatches.

**Why exclude side-effect commands from dual execution**: Commands that write files or send network requests would produce duplicate side effects when run twice. The static analysis (steps 1-2) provides a baseline safety check for these commands. As the system matures, a sandboxed comparison mode can be added.

### 5.8 Cache Management

#### 5.8.1 Directory Structure

```
$XDG_CACHE_HOME/bash_jit/
  counters.json                     # daemon's global counters
  <fingerprint>/                    # one directory per snippet
    compiled.py                     # compiled Python
    meta.json                       # metadata (source, context, timestamps)
    FAILED                          # compilation failed marker (empty file)
```

#### 5.8.2 Atomic Writes

Daemon writes use temp files + `rename()` for atomicity:

```python
def write_cache(self, fingerprint, python_code, source_text, metadata):
    snippet_dir = os.path.join(self.cache_dir, fingerprint)
    os.makedirs(snippet_dir, exist_ok=True)

    # 1. Atomic write meta.json
    meta_path = os.path.join(snippet_dir, "meta.json")
    meta_tmp = meta_path + ".tmp." + str(os.getpid())
    with open(meta_tmp, "w") as f:
        json.dump(metadata, f)
    os.rename(meta_tmp, meta_path)

    # 2. Atomic write compiled.py (MUST be last — bash checks this file)
    py_path = os.path.join(snippet_dir, "compiled.py")
    py_tmp = py_path + ".tmp." + str(os.getpid())
    with open(py_tmp, "w") as f:
        f.write(python_code)
    os.rename(py_tmp, py_path)
```

**Write order guarantee**: `meta.json` is written before `compiled.py`. When bash's `access(compiled.py)` succeeds, `meta.json` is guaranteed to be complete, so `jit_verify_cache()` can safely read it.

#### 5.8.3 Anti-Collision Verification

Since FNV-128 is non-cryptographic, there is a (negligible but non-zero) collision probability. Verification compares the stored source text against the current source:

```c
int
jit_verify_cache (const char *fingerprint, const char *current_source)
{
  char meta_path[512], *meta_content, *stored_source;
  size_t file_size;

  snprintf(meta_path, sizeof(meta_path),
           "%s/%s/meta.json", jit_cache_dir, fingerprint);

  meta_content = jit_read_file(meta_path, &file_size);
  if (!meta_content) return 0;

  stored_source = jit_json_extract(meta_content, "source_text");
  free(meta_content);

  if (!stored_source) return 0;

  int match = (strcmp(stored_source, current_source) == 0);
  free(stored_source);

  return match;
}
```

Verification frequency:

| When | Verify? | Reason |
|------|---------|--------|
| First discovery of `compiled.py` | Yes | Transition from `is_compiled=0` to `1` |
| Subsequent executions | No | Already verified, cached locally |
| `meta.json` mtime changed | Yes | Detect external modification |

#### 5.8.4 Invalidation

- **File deletion**: If `compiled.py` is deleted, JIT automatically deactivated (next `access()` fails)
- **FAILED file**: Daemon won't retry compilation for this fingerprint
- **Manual**: `jit clear` or `rm -r $BASH_JIT_CACHE_DIR/<fingerprint>/`
- **TTL**: Daemon removes directories older than configurable days (default: 30)
- **Source mismatch**: Auto-delete entire snippet directory, fall back to bash
- **Function redefinition**: When a function's generation counter changes, all cache entries referencing that function are invalidated

### 5.9 State Synchronization

Since Python runs as a subprocess, bash's internal state is not directly accessible. The design takes a **conservative** approach: only compile commands that don't depend on bash-internal state.

**What IS synchronized** (via subprocess inheritance):
- Exported environment variables (inherited by `execve`)
- Working directory (inherited by `fork`)
- Open file descriptors 0-2 (stdin/stdout/stderr, inherited by `fork`)
- Signal dispositions (inherited, with standard fork semantics)

**What is NOT synchronized** (and therefore commands using these are INELIGIBLE):
- Non-exported shell variables (the majority)
- Special parameters (`$?`, `$#`, `$@`, `$*`, `$$`, `$!`, `$_`)
- Shell options (`set -e`, `set -u`, `set -o pipefail`)
- Function definitions (Python cannot call bash functions natively)
- Trap handlers
- Aliases
- Open file descriptors beyond 0-2 (unless explicitly redirected)
- Shell-level `umask` changes

This is a **hard semantic boundary**. The eligibility check (Section 5.2) enforces it. Commands that depend on any of the above are never JIT'd.

### 5.10 Initialization and Daemon Startup

#### 5.10.1 Bash-side Initialization

In `shell.c` `main()`, after `initialize_shell_variables()`:

```c
#if defined (BASH_JIT)
  bash_jit_init();
#endif
```

`bash_jit_init()`:
1. Check `BASH_JIT` env var. If not set, `bash_jit_enabled = 0` — zero overhead.
2. Read configuration: `BASH_JIT_THRESHOLD`, `BASH_JIT_CACHE_DIR`, etc.
3. Connect to daemon's Unix socket.

#### 5.10.2 Daemon Auto-Start with Readiness Signal

If the daemon is not running, bash must start it. A naive "fork then connect" has a race condition: the parent's `connect()` may fire before the child has created the socket.

**Solution: pipe-based readiness signal**:

```c
int
jit_connect_or_start_daemon (void)
{
  const char *socket_path = jit_get_socket_path();

  /* 1. Try to connect to existing daemon */
  jit_socket = jit_connect_socket(socket_path);
  if (jit_socket >= 0)
    return 0;  /* Daemon already running */

  /* 2. Create a pipe for readiness signaling */
  int ready_pipe[2];
  if (pipe(ready_pipe) < 0)
    return -1;

  /* 3. Fork daemon process */
  pid_t pid = fork();
  if (pid < 0)
    {
      close(ready_pipe[0]);
      close(ready_pipe[1]);
      return -1;
    }

  if (pid == 0)
    {
      /* Child: start daemon */
      close(ready_pipe[0]);  /* Close read end */
      char pipe_fd_str[16];
      snprintf(pipe_fd_str, sizeof(pipe_fd_str), "%d", ready_pipe[1]);

      /* Pass pipe FD to daemon via environment variable */
      setenv("BASH_JIT_READY_PIPE", pipe_fd_str, 1);
      execlp(jit_daemon_path, "bash_jitd", NULL);
      _exit(127);  /* execlp failed */
    }

  /* Parent: wait for readiness signal */
  close(ready_pipe[1]);  /* Close write end */
  char ready_byte;
  ssize_t n = read(ready_pipe[0], &ready_byte, 1);
  close(ready_pipe[0]);

  if (n <= 0)
    return -1;  /* Daemon failed to start */

  /* 4. Daemon is ready — connect */
  jit_socket = jit_connect_socket(socket_path);
  return (jit_socket >= 0) ? 0 : -1;
}
```

**Daemon side**: After binding the socket, write a byte to `BASH_JIT_READY_PIPE`:

```python
# In bash_jitd startup:
async def start_server(self):
    server = await asyncio.start_unix_server(
        self.handle_client, path=self.socket_path)
    os.chmod(self.socket_path, 0o600)

    # Signal readiness
    ready_pipe = os.environ.get('BASH_JIT_READY_PIPE')
    if ready_pipe:
        fd = int(ready_pipe)
        os.write(fd, b'\x00')
        os.close(fd)
```

### 5.11 Cleanup and Lifecycle

When the bash process exits, all JIT resources must be cleaned up:

```c
void
bash_jit_cleanup (void)
{
  if (!bash_jit_enabled)
    return;

  /* Close daemon socket */
  if (jit_socket >= 0)
    {
      close(jit_socket);
      jit_socket = -1;
    }

  /* Flush and dispose local cache */
  if (jit_local_cache)
    {
      hash_flush(jit_local_cache, jit_free_entry);
      hash_dispose(jit_local_cache);
      jit_local_cache = NULL;
    }
}

static void
jit_free_entry (PTR_T data)
{
  jit_snippet_entry *entry = (jit_snippet_entry *)data;
  if (entry)
    {
      FREE(entry->fingerprint);
      free(entry);
    }
}
```

Register cleanup in `bash_jit_init()`:

```c
void
bash_jit_init (void)
{
  /* ... initialization ... */

  /* Register cleanup on shell exit */
  add_unwind_protect((Function *)bash_jit_cleanup, NULL);
}
```

### 5.12 CLI Tool: `jit`

A standalone command-line tool for managing the JIT system. Connects to the daemon's Unix socket for request-response operations.

```bash
# View daemon status and hot code
jit status

# Manually compile a .sh file (each top-level command is compiled)
jit compile script.sh

# Manually compile a bash string
jit compile 'for i in $(seq 100); do echo "$i"; done'

# Force recompilation (even if previously compiled or failed)
jit compile --force script.sh

# Clear all compiled cache
jit clear

# Clear only failed compilations (allows retry)
jit clear --failed

# Stop daemon
jit stop

# Start daemon (usually auto-started, but can be manual)
jit start
```

## 6. Configuration

### 6.1 Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BASH_JIT` | (unset) | Set to `1` to enable JIT. Disabled by default. |
| `BASH_JIT_THRESHOLD` | `100` | Global execution count before compilation |
| `BASH_JIT_CACHE_DIR` | `$XDG_CACHE_HOME/bash_jit` | Cache directory |
| `BASH_JIT_DAEMON` | `bash_jitd` | Path to daemon executable |
| `BASH_JIT_LLM_MODEL` | (none) | LLM model identifier |
| `BASH_JIT_LLM_API_KEY` | (none) | API key for LLM service |
| `BASH_JIT_LLM_ENDPOINT` | `https://api.anthropic.com/v1/messages` | LLM API endpoint |
| `BASH_JIT_LOG` | (unset) | Log file path for debugging |
| `BASH_JIT_MIN_COMPLEXITY` | `50` | Minimum source length (chars) for eligibility |
| `BASH_JIT_EXCLUDE` | (unset) | Colon-separated fingerprint prefixes to exclude |

### 6.2 Daemon Config File (`~/.config/bash_jit/config.json`)

```json
{
  "threshold": 100,
  "llm": {
    "model": "claude-sonnet-4-20250514",
    "api_key_env": "ANTHROPIC_API_KEY",
    "endpoint": "https://api.anthropic.com/v1/messages",
    "max_tokens": 4096,
    "temperature": 0
  },
  "cache": {
    "dir": "~/.cache/bash_jit",
    "max_size_mb": 500,
    "ttl_days": 30
  },
  "validation": {
    "enabled": true,
    "timeout_seconds": 5,
    "trust_verify_count": 5
  },
  "min_complexity": 50
}
```

## 7. Fallback Strategy

Every JIT operation falls back safely to normal bash execution:

| Failure | Response |
|---------|----------|
| `BASH_JIT` not set | Zero overhead, all JIT code is no-op (`#if defined(BASH_JIT)`) |
| Daemon not running | `jit_socket < 0`, skip reporting, execute normally |
| Daemon crashes | Socket write fails silently, no impact on bash |
| LLM API failure | Daemon marks as failed, retries with backoff |
| Validation failure | `FAILED` marker written, no retry |
| Python runtime crash | `wait_for()` returns signal death, bash reports exit code |
| Python not installed | `execve` fails, child exits 127, fall back |
| Cache file deleted | `access()` fails, execute normally |
| Eligibility check fails | Skip JIT entirely, zero additional overhead |
| `make_command_string()` returns NULL | Return `JIT_CHECK_NORMAL` immediately |

## 8. Build System Changes

### 8.1 Files to Create

| File | Language | Description |
|------|----------|-------------|
| `bash_jit.c` | C | Fingerprint, eligibility, cache check, daemon communication, command replacement |
| `bash_jit.h` | C | `JIT_CHECK_*` constants, function declarations |
| `bash_jitd` | Python | Daemon: counter management, auto-compilation, LLM translation, validation, caching |
| `jit` | Python | CLI tool: `jit compile`, `jit status`, `jit clear`, `jit stop` |

### 8.2 Files to Modify

| File | Change | Location |
|------|--------|----------|
| `eval.c` | Wrap `execute_command(current_command)` with `bash_jit_check()` | Line ~183 |
| `builtins/evalstring.c` | Wrap `execute_command_internal(command, ...)` with `bash_jit_check()` | Line ~567 |
| `execute_cmd.c` | Wrap function execution with `bash_jit_function_check()`; register function defs | Lines ~5206, ~6336 |
| `shell.c` | Add `bash_jit_init()` call in `main()` | After `initialize_shell_variables()` |
| `configure.ac` | Add `AC_ARG_ENABLE([jit], ...)` and conditional compilation | Near line 261 |
| `config.h.in` | Add `#undef BASH_JIT` | Near line 189 |
| `Makefile.in` | Add `$(JIT_O)` to OBJECTS list; add `JIT_O = @JIT_O@` substitution | Lines ~526, ~535 |

### 8.3 Build System Pattern

Follow the exact pattern used by `ARITH_FOR_COMMAND` (a feature that is conditionally compiled):

**`configure.ac`** (near line 261, among other `AC_ARG_ENABLE` entries):

```m4
AC_ARG_ENABLE([jit],
  [AS_HELP_STRING([--enable-jit], [Enable JIT compilation via LLM translation])],
  [opt_jit=$enableval],
  [opt_jit=no])

if test "$opt_jit" = yes; then
  AC_DEFINE(BASH_JIT)
  JIT_O=bash_jit.o
fi
AC_SUBST(JIT_O)
```

**`config.h.in`** (near line 189):

```c
#undef BASH_JIT
```

**`Makefile.in`** (near line 526):

```makefile
JIT_O = @JIT_O@
```

And in the OBJECTS list (line ~535):

```makefile
OBJECTS = shell.o eval.o ... $(SIGNAMES_O) $(JIT_O)
```

Dependency rule (append near end of Makefile.in):

```makefile
bash_jit.o: bash_jit.c bash_jit.h config.h shell.h command.h execute_cmd.h hashlib.h
```

### 8.4 Conditional Compilation Guards

All JIT code in bash core files is wrapped in `#if defined (BASH_JIT)`:

```c
#if defined (BASH_JIT)
  #include "bash_jit.h"
#endif

/* ... later in code ... */

#if defined (BASH_JIT)
  bash_jit_init();
#endif
```

When `BASH_JIT` is not defined (the default), the preprocessor strips all JIT code. The compiled bash binary has zero JIT overhead.

## 9. Performance Overhead Analysis

### 9.1 Overhead per Execution Path

| Scenario | Overhead |
|----------|----------|
| `BASH_JIT` not set | 0 (preprocessor removes all JIT code) |
| `BASH_JIT` set, but command ineligible | `savestring(make_command_string())` + eligibility check (~0.05ms) |
| First-time eligible snippet | Above + hash computation + hash table insert + socket write (~0.1ms) |
| Repeated snippet (not compiled) | Hash table lookup + counter increment + socket write (~0.05ms) |
| Compiled snippet (variable injection) | Hash table lookup + `jit_inject_variables()` scan + `maybe_make_export_env()` + fork+exec python3 (~2-5ms) |

### 9.2 When JIT Provides Net Benefit

The JIT does NOT make individual commands faster — the fork+exec of `python3` adds ~2-5ms per invocation. The benefit comes from **eliminating bash's per-iteration overhead in loops**.

**Bash's per-iteration overhead** in a `for` loop:
- Variable expansion (`$i`, `$PREFIX`) + word splitting: ~0.05ms per expansion
- Command dispatch (`echo`, external commands): ~0.1ms per command
- Subshell for `$(seq N)`: ~5ms one-time

**Example: `for i in $(seq 1000); do echo "$PREFIX: $i"; done`**

| | Bash (interpreted) | Python (JIT) |
|---|---|---|
| `$(seq 1000)` expansion | 1000 word-split items, ~5ms | `range(1, 1001)`, ~0ms |
| Per iteration: expand + echo | ~0.1ms × 1000 = **100ms** | Native `print()`, ~0.01ms × 1000 = **10ms** |
| python3 fork+exec | — | **3ms** one-time |
| Variable injection | — | **0.5ms** one-time |
| **Total** | **~105ms** | **~13.5ms** |
| **Speedup** | — | **~7.8x** |

**Break-even analysis**: The fork+exec + variable injection overhead (~4ms) must be amortized over loop iterations. For a loop with ~0.1ms bash overhead per iteration:
- Break-even at ~40 iterations
- Net gain grows linearly beyond 40 iterations
- For 1000-iteration loops, the gain is ~90ms (85% reduction)

**Why the minimum complexity threshold is 50 chars** (lowered from 100): A `for` loop with 50+ characters typically has enough iterations or complexity to amortize the fork+exec cost. Single-line commands (`echo hello`) are filtered out. The threshold is configurable via `BASH_JIT_MIN_COMPLEXITY`.

### 9.3 Variable Injection Overhead

The `jit_inject_variables()` function scans the source text for `$VAR` patterns and looks up each variable. For a source with N variable references:
- Text scan: O(source_length) — fast, no allocations
- Variable lookup: O(N) hash lookups — ~0.01ms each
- `maybe_make_export_env()`: rebuilds the environment array — ~0.1ms for typical environments (< 200 variables)

Total injection overhead: ~0.5ms for most scripts. This is a one-time cost per JIT execution, amortized over the loop.

## 10. Security Considerations

1. **Code privacy**: Bash source is sent to the LLM API. Support local LLM endpoints (Ollama, vLLM). Allow `BASH_JIT_EXCLUDE` for sensitive scripts.
2. **Daemon socket**: Use `$XDG_RUNTIME_DIR/bash_jit_$UID/socket` with mode 0700.
3. **Cache files**: Mode 0600, directory mode 0700.
4. **Static analysis**: Validation pipeline checks for dangerous patterns in LLM output.
5. **Eligibility boundary**: The conservative eligibility check prevents JIT compilation of security-sensitive constructs (`eval`, `exec`, `source`).
6. **LLM prompt injection**: The prompt explicitly forbids `eval()`/`exec()` in generated Python code. Static analysis verifies compliance.

## 11. Testing Strategy

### 11.1 LLM API Configuration

During development and testing, LLM API calls (for bash→Python translation) use the API key configured in `~/.claude/settings.json`. The daemon reads the key from the `ANTHROPIC_API_KEY` environment variable or from the `api_key_env` field in `~/.config/bash_jit/config.json` (which references the same key name).

### 11.2 Test Suites

1. **Unit tests** (C): Fingerprint computation, cache path resolution, eligibility check, context hash, variable injection scanning
2. **Integration tests**:
   - Run `for i in $(seq 1000); do echo "$i"; done` with JIT enabled
   - Verify identical stdout before/after JIT compilation
   - Verify exit codes match
3. **Eligibility tests**: Verify that:
   - Ineligible commands (`eval`, state-modifying builtins, process substitution, variable assignments) are never JIT'd
   - Eligible commands (pure builtins like `echo`/`printf`, non-exported variable references, `for` loops) ARE JIT'd
4. **Cross-process tests**:
   - Run `bash script.sh` 200 times in a loop
   - Verify JIT activates after threshold
   - Verify daemon counters persist across processes
5. **Fallback tests**: Kill daemon mid-compilation, verify bash continues normally
6. **Context invalidation tests**: Redefine a function, verify cache entries are invalidated
7. **Redirect tests**: Verify that `compiled_cmd > file.txt`, `cmd1 | compiled_cmd | cmd3` work correctly
8. **Variable injection tests**:
   - Script with non-exported variables: `PREFIX=hello; for i in $(seq 10); do echo "$PREFIX: $i"; done`
   - Verify Python process receives injected variables in environment
   - Verify `temporary_env` is cleaned up after JIT execution
9. **Trust-but-verify tests**: Verify stdout/stderr/exit-code comparison catches semantic mismatches in first M executions
10. **Performance regression tests**: Verify that JIT-disabled mode has zero measurable overhead

### 11.3 JIT Correctness and Performance Test Suite

A dedicated test suite that runs each test case under two configurations and compares results:

- **Configuration A**: `BASH_JIT=0` (native bash execution) — produces the reference output
- **Configuration B**: `BASH_JIT=1` (JIT-enabled execution with pre-compiled Python)

For each test case:

1. Run under Config A, capture: stdout, stderr, exit code, execution time
2. Run under Config B, capture: stdout, stderr, exit code, execution time
3. **Correctness check**: stdout, stderr, and exit code must be identical between A and B
4. **Performance check**: Report execution time ratio (B / A). For eligible loop-heavy snippets, expect B < A; for simple commands, B >= A is acceptable

**Test case categories**:

| Category | Example | What it validates |
|----------|---------|-------------------|
| Simple for loop | `for i in $(seq 100); do echo "$i"; done` | Loop translation, echo → print() |
| While loop with condition | `i=0; while [ $i -lt 100 ]; do echo $i; i=$((i+1)); done` | While loop, test → Python expr |
| Variable injection | `PREFIX=hello; for i in $(seq 10); do echo "$PREFIX: $i"; done` | Non-exported variable access |
| External commands | `for f in *.txt; do wc -l "$f"; done` | subprocess.run() translation |
| Redirects | `for i in $(seq 10); do echo "$i"; done > output.txt` | Redirect inheritance |
| Pipes | `for i in $(seq 100); do echo "$i"; done \| sort -n` | Pipeline integration |
| Mixed builtins | `for i in $(seq 10); do printf "item-%03d\n" "$i"; done` | printf → string formatting |
| Arithmetic for | `for ((i=0; i<100; i++)); do echo $i; done` | C-style for loop |
| Nested loops | `for i in $(seq 10); do for j in $(seq 10); do echo "$i,$j"; done; done` | Nested loop performance |
| Edge: empty input | `for x in; do echo "$x"; done` | Empty iteration handling |

The test suite runs as part of `make check-jit` and produces a summary report with correctness pass/fail counts and performance ratios per test case.

### 11.4 LLM Translation Accuracy Test Suite

A corpus of bash snippets with expected Python output and expected execution results. Used to evaluate LLM translation quality and track regression across model versions. Covers: loop patterns, variable references, builtin translation, edge cases in word splitting and quoting.

## Appendix A: Bash Source Interception Points

```
Text Input (script file, -c string, stdin, source/eval)
    |
    v
yyparse() / parse_command() -- produces COMMAND* in global_command
    |
    +-- reader_loop() [eval.c:183]          [INTERCEPT POINT 1]
    |     execute_command(current_command)
    |
    +-- parse_and_execute() [evalstring.c:567]  [INTERCEPT POINT 2]
          execute_command_internal(command, ...)
              |
              +-- cm_simple -> execute_simple_command()
              |                  |
              |                  +-- find_function() -> execute_function()  [INTERCEPT POINT 3]
              |                  +-- execute_builtin()
              |                  +-- execute_disk_command()
              |
              +-- cm_for/while/until/if/case -> compound handlers (recursive)
              +-- cm_connection -> execute_connection() (pipes, &&, ||)
              +-- cm_function_def -> execute_intern_function()  [INTERCEPT POINT 4]
```

## Appendix B: Existing Bash Infrastructure Used

| Component | File | Purpose |
|-----------|------|---------|
| `make_command_string()` | `print_cmd.c:152` | COMMAND tree -> normalized source text (static buffer!) |
| `HASH_TABLE` / `hash_search()` / `hash_flush()` / `hash_dispose()` | `hashlib.h`, `hashlib.c` | Local cache tracking and cleanup |
| `make_word_list()` / `make_word()` / `copy_word()` | `make_cmd.c` | Build replacement command's word list |
| `execute_command()` / `execute_command_internal()` | `execute_cmd.c` | Execute the replacement command |
| `dispose_command()` | `dispose_cmd.c` | Free replacement command after execution |
| `make_child()` | `jobs.c` | Fork for Python subprocess (via execute_disk_command) |
| `wait_for()` | `jobs.c` | Wait for subprocess exit |
| `maybe_make_export_env()` | `variables.c` | Build environment for execve |
| `export_env` | `variables.c` | Current environment array |
| `get_string_value()` | `variables.c` | Read shell variables for config |
| `find_function()` / `function_cell()` | `variables.c` | Function lookup and body access |
| `named_function_string()` | `print_cmd.c:1400` | Function source extraction |
| `bind_function()` | `variables.c` | Detect function definition (for registration) |
| `savestring()` | `general.h` | Heap-copy a string (critical for static buffer safety) |
| `add_unwind_protect()` | `unwind_prot.c` | Register cleanup on shell exit |

## 12. Whole-Script JIT Compilation

### 12.1 Motivation

The per-command JIT (Sections 2-11) compiles individual hot commands. This has limited value because:
- Small code fragments have limited optimization headroom
- Python process startup (~2-5ms) eats into gains for short snippets
- A script like `source-stats.sh` takes 9s in bash but 146ms in Python — only whole-script compilation captures this

Whole-script JIT compiles the **entire script file** to Python and `execvp`'s the Python interpreter, replacing the bash process entirely.

### 12.2 Execution Flow

**First run (no compiled cache):**
1. bash starts → `bash_jit_init()` initializes
2. `bash_jit_try_script("script.sh")` reads script, computes fingerprint
3. No `compiled.py` in cache → sends script to daemon for async compilation
4. Returns, bash executes script normally (normal bash speed)
5. daemon compiles in background, writes `<cache_dir>/<fp>/compiled.py`

**Second run (compiled cache exists):**
1. bash starts → `bash_jit_init()` initializes
2. `bash_jit_try_script("script.sh")` reads script, computes fingerprint
3. Finds `compiled.py` in cache → `execvp("python3", ...)` replaces process
4. Python runs, user sees Python speed

**Pre-compiled (via `jit compile --stdin < script.sh`):**
1. CLI reads script, sends to daemon
2. daemon compiles with matching fingerprint, writes cache
3. Next `BASH_JIT=1 bash script.sh` hits cache immediately

### 12.3 Fingerprint Unification

Current mismatch:
- C side: `fnv128_hex(source + context)` (Section 5.1.2)
- Daemon CLI: `md5(source) + md5(source)` (different hash)

Unified approach: **use fnv128 of script content only** (no context). Both sides implement the same fnv128:

**C side** (`bash_jit.c:64-83`): Already exists.

**Python side** (new, in `bash_jitd`):
```python
def fnv128_hex(data: str) -> str:
    h1, h2 = 2166136261, 2166136263
    h3, h4 = h1 ^ 0x5bd1e995, h2 ^ 0x5bd1e995
    for ch in data:
        c = ord(ch)
        mask = 0xFFFFFFFF
        h1 = ((h1 ^ c) + ((h1<<1)+(h1<<4)+(h1<<7)+(h1<<8)+(h1<<24))) & mask
        h2 = ((h2 ^ c) + ((h2<<1)+(h2<<4)+(h2<<7)+(h2<<8)+(h2<<24))) & mask
        h3 = ((h3 ^ c) + ((h3<<1)+(h3<<4)+(h3<<7)+(h3<<8)+(h3<<24))) & mask
        h4 = ((h4 ^ c) + ((h4<<1)+(h4<<4)+(h4<<7)+(h4<<8)+(h4<<24))) & mask
    return f"{h1:08x}{h2:08x}{h3:08x}{h4:08x}"
```

### 12.4 Parameter Passing

Compiled Python needs:
- `$0` / `$BASH_SOURCE` → env var `BASH_JIT_SCRIPT` (original script path)
- `$1`...`$n` → `sys.argv[1:]`
- Shell variables → `os.environ` (inherited naturally)

```c
// In bash_jit_try_script():
setenv("BASH_JIT_SCRIPT", script_path, 1);
execvp("python3", argv);  // argv = ["python3", "<cache>/<fp>/compiled.py", "$1", "$2", ...]
```

### 12.5 LLM Prompt (Updated for Whole Scripts)

The current prompt targets code snippets. Updated prompt handles:
- Shebang lines (skip)
- Function definitions (translate to Python functions)
- `source`/`.` commands (subprocess call to bash)
- `$0` via `os.environ["BASH_JIT_SCRIPT"]`
- Positional params via `sys.argv[1:]`

### 12.6 Changes

#### `bash_jit.c` — New function `bash_jit_try_script()`

```c
// Read script file → compute fingerprint → check cache → execvp or send to daemon
// Returns: 0 if execvp'd (never returns), -1 if fall through to bash
int bash_jit_try_script(const char *script_path);
```

Steps:
1. `jit_read_file(script_path)` — read entire script content
2. `fnv128_hex(content, fp)` — compute fingerprint (content only, no context)
3. Check `<cache_dir>/<fp>/compiled.py` exists via `access()`
4. **Exists**: set `BASH_JIT_SCRIPT` env var, build argv with positional params, `execvp("python3", argv)`
5. **Not exists**: send `{"type":"exec_script","fingerprint":fp,"source":content}` to daemon, return -1

Reuses existing:
- `jit_read_file()` (`bash_jit.c:148`) — file reading
- `fnv128_hex()` (`bash_jit.c:64`) — fingerprint
- `jit_cache_dir` (`bash_jit.c:55`) — cache directory
- Socket send mechanism (same as `jit_send_exec_report`)

#### `bash_jit.h` — Declare new function

```c
extern int bash_jit_try_script (const char *script_path);
```

#### `shell.c:782` — Intercept before `open_shell_script()`

```c
if (shell_script_filename)
    {
      #if defined (BASH_JIT)
      if (bash_jit_enabled)
        bash_jit_try_script (shell_script_filename);
      #endif
      open_shell_script (shell_script_filename);
    }
```

This is the optimal interception point: JIT initialized, `$0` and positional params set, startup files executed, script file not yet opened.

#### `scripts/bash_jitd` — Four changes

1. **Add `fnv128_hex()` Python implementation** (matching C exactly)
2. **`_handle_compile()`**: Replace `md5+md5` with `fnv128_hex(source)`
3. **New `exec_script` message handler**: Receive fingerprint + source, trigger compilation
4. **Update LLM prompt** (`_call_llm`): Handle whole scripts with shebangs, functions, source commands

### 12.7 Relationship to Per-Command JIT

Per-command JIT (`bash_jit_check()`) is **preserved** for interactive shells. Whole-script JIT only activates when `shell_script_filename` is set (i.e., running a script file). The two paths don't interfere:

| Scenario | JIT path |
|----------|----------|
| `bash script.sh` | Whole-script (`bash_jit_try_script`) |
| Interactive shell | Per-command (`bash_jit_check`) |
| `bash -c "..."` | Per-command (no `shell_script_filename`) |

### 12.8 Verification

```bash
# 1. Build JIT version
./scripts/build.sh --clean

# 2. Pre-compile via CLI
./tests/jit/jit_run_it.sh ./scripts/source-stats.sh

# 3. Run with compiled cache (should be <1s)
./tests/jit/jit_run_it.sh ./scripts/source-stats.sh

# 4. Compare with baseline
./tests/jit/baseline_run_it.sh ./scripts/source-stats.sh

# 5. First run without pre-compile (bash speed, triggers async compilation)
BASH_JIT=1 ~/local/bash-jit/bin/bash ./scripts/source-stats.sh

# 6. Second run (Python speed, cache hit)
BASH_JIT=1 ~/local/bash-jit/bin/bash ./scripts/source-stats.sh

# 7. Disable JIT (falls back to bash)
BASH_JIT=0 ~/local/bash-jit/bin/bash ./scripts/source-stats.sh

# 8. Run existing test suites
./tests/jit/run_jit_tests.sh
```
