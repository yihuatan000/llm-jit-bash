/* bash_jit.h -- JIT compilation interface for Bash. */

#if !defined (_BASH_JIT_H_)
#define _BASH_JIT_H_

#include "config.h"

#if defined (BASH_JIT)

#include "command.h"

/* Return values for bash_jit_check() */
#define JIT_CHECK_NORMAL     0   /* proceed with normal bash execution */
#define JIT_CHECK_COMPILED   1   /* use the replacement command */

/* Per-snippet tracking (in-process, for cache check optimization) */
typedef struct {
  unsigned long local_count;    /* in-process execution count */
  int is_compiled;              /* 1=compiled, 0=unchecked, -1=confirmed uncompiled */
  char *fingerprint;            /* heap-allocated 32-char hex string */
} jit_snippet_entry;

/* Initialization and cleanup */
extern void bash_jit_init (void);
extern void bash_jit_cleanup (void);

/* Global JIT state (visible for conditional checks in bash source) */
extern int bash_jit_enabled;

/* Main interface: check if a command should be JIT-accelerated */
extern int bash_jit_check (COMMAND *, WORD_LIST *, COMMAND **);

/* Function-specific JIT check */
extern int bash_jit_function_check (SHELL_VAR *, WORD_LIST *, COMMAND **);

/* Register a function definition with the daemon */
extern void bash_jit_register_function (const char *, COMMAND *);

/* Report execution duration (called after execute_command in normal path) */
extern void bash_jit_exec_done (void);

/* Try whole-script JIT: execvp python3 if compiled, else trigger compilation */
extern int bash_jit_try_script (const char *script_path);

#endif /* BASH_JIT */

#endif /* _BASH_JIT_H_ */
