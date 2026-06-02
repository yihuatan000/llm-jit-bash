/* bash_jit.c -- JIT compilation support for Bash via LLM translation. */

#include "config.h"

#if defined (BASH_JIT)

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <errno.h>
#include <time.h>

#include "shell.h"
#include "bashansi.h"
#include "command.h"
#include "general.h"
#include "xmalloc.h"
#include "hashlib.h"
#include "variables.h"
#include "arrayfunc.h"
#include "conftypes.h"
#include "array.h"
#include "quit.h"
#include "unwind_prot.h"
#include "dispose_cmd.h"
#include "make_cmd.h"
#include "execute_cmd.h"
#include "externs.h"
#include "builtins.h"
#include "builtins/common.h"
#include "bash_jit.h"

/* Forward declarations for flags.c variables */
extern int exit_immediately_on_error;
extern int disallow_filename_globbing;
extern int pipefail_opt;
extern int unbound_vars_is_error;

/* FNV-1a constants from hashlib.c */
#define FNV_OFFSET_A  2166136261u
#define FNV_OFFSET_B  2166136263u

/* Minimum source length for JIT eligibility */
static int jit_min_complexity = 50;

/* Global state */
static HASH_TABLE *jit_local_cache = NULL;
static int jit_socket = -1;
int bash_jit_enabled = 0;
static char *jit_cache_dir = NULL;
static char *jit_daemon_path = NULL;

/* Execution timing state */
static struct timespec jit_exec_start;
static char jit_pending_fingerprint[33];

/* ---- FNV-128 fingerprint computation ---- */

static void
fnv128_hex (const char *input, char out[33])
{
  unsigned int h1 = FNV_OFFSET_A, h2 = FNV_OFFSET_B;
  unsigned int h3 = FNV_OFFSET_A ^ 0x5bd1e995;
  unsigned int h4 = FNV_OFFSET_B ^ 0x5bd1e995;
  const unsigned char *s = (const unsigned char *)input;

  while (*s)
    {
      unsigned int c = *s++;
      h1 ^= c; h1 += (h1<<1) + (h1<<4) + (h1<<7) + (h1<<8) + (h1<<24);
      h2 ^= c; h2 += (h2<<1) + (h2<<4) + (h2<<7) + (h2<<8) + (h2<<24);
      h3 ^= c; h3 += (h3<<1) + (h3<<4) + (h3<<7) + (h3<<8) + (h3<<24);
      h4 ^= c; h4 += (h4<<1) + (h4<<4) + (h4<<7) + (h4<<8) + (h4<<24);
    }

  sprintf(out, "%08x%08x%08x%08x", h1, h2, h3, h4);
  out[32] = '\0';
}

/* ---- JSON helpers ---- */

static char *
jit_json_escape (const char *input)
{
  size_t len, out_size;
  char *out;
  const char *s;
  char *d;

  if (!input)
    return savestring ("");

  len = strlen (input);
  out_size = len * 6 + 1;  /* worst case: every char becomes \uXXXX */
  out = (char *)xmalloc (out_size);
  d = out;

  for (s = input; *s; s++)
    {
      unsigned char c = (unsigned char)*s;
      if (c == '\\') { *d++ = '\\'; *d++ = '\\'; }
      else if (c == '"') { *d++ = '\\'; *d++ = '"'; }
      else if (c == '\n') { *d++ = '\\'; *d++ = 'n'; }
      else if (c == '\r') { *d++ = '\\'; *d++ = 'r'; }
      else if (c == '\t') { *d++ = '\\'; *d++ = 't'; }
      else if (c == '\b') { *d++ = '\\'; *d++ = 'b'; }
      else if (c == '\f') { *d++ = '\\'; *d++ = 'f'; }
      else if (c < 0x20)
        { d += sprintf (d, "\\u%04x", c); }
      else
        { *d++ = c; }
    }
  *d = '\0';
  return out;
}

static char *
jit_json_extract (const char *json, const char *key)
{
  const char *p;
  char search[256];
  size_t key_len, val_start, val_len;
  char *result;

  snprintf (search, sizeof(search), "\"%s\"", key);
  key_len = strlen (search);

  p = strstr (json, search);
  if (!p) return NULL;

  p += key_len;
  while (*p == ' ' || *p == ':' || *p == '\t') p++;

  if (*p != '"') return NULL;
  p++;

  val_start = 0;
  /* We need to handle escape sequences, so build the result char by char */
  /* First pass: compute length */
  {
    const char *vp = p;
    while (*vp && *vp != '"')
      {
        if (*vp == '\\') { vp += 2; val_start++; }
        else { vp++; val_start++; }
      }
  }

  result = (char *)xmalloc (val_start + 1);
  val_len = 0;
  {
    const char *vp = p;
    while (*vp && *vp != '"')
      {
        if (*vp == '\\')
          {
            vp++;
            switch (*vp)
              {
              case '"': result[val_len++] = '"'; break;
              case '\\': result[val_len++] = '\\'; break;
              case 'n': result[val_len++] = '\n'; break;
              case 'r': result[val_len++] = '\r'; break;
              case 't': result[val_len++] = '\t'; break;
              case 'b': result[val_len++] = '\b'; break;
              case 'f': result[val_len++] = '\f'; break;
              default: result[val_len++] = *vp; break;
              }
            vp++;
          }
        else
          result[val_len++] = *vp++;
      }
  }
  result[val_len] = '\0';
  return result;
}

static char *
jit_read_file (const char *path, size_t *out_len)
{
  int fd;
  struct stat st;
  char *buf;
  ssize_t n;

  fd = open (path, O_RDONLY);
  if (fd < 0) return NULL;

  if (fstat (fd, &st) < 0) { close (fd); return NULL; }

  buf = (char *)xmalloc (st.st_size + 1);
  n = read (fd, buf, st.st_size);
  close (fd);

  if (n < 0) { free (buf); return NULL; }
  buf[n] = '\0';
  if (out_len) *out_len = (size_t)n;
  return buf;
}

/* ---- Context hash ---- */

static char *
jit_build_context (void)
{
  /* Build a context string from all function definitions + shell options */
  SHELL_VAR **funcs;
  int i;
  char *result;
  size_t result_size, result_len;

  result_size = 4096;
  result = (char *)xmalloc (result_size);
  result_len = 0;

  funcs = all_shell_functions ();
  if (funcs)
    {
      for (i = 0; funcs[i]; i++)
        {
          COMMAND *body = function_cell (funcs[i]);
          char *body_str;
          char body_hash[33];
          size_t name_len;

          if (!body) continue;

          body_str = named_function_string (
              funcs[i]->name, body, FUNC_MULTILINE | FUNC_EXTERNAL);
          if (!body_str) continue;

          fnv128_hex (body_str, body_hash);
          /* body_str points to the_printed_command (a reused global buffer);
             do NOT free it. */

          name_len = strlen (funcs[i]->name);

          /* Ensure space: name + \0 + 32 hash chars + \0 = name_len + 34 */
          while (result_len + name_len + 34 >= result_size)
            {
              result_size *= 2;
              result = (char *)xrealloc (result, result_size);
            }

          memcpy (result + result_len, funcs[i]->name, name_len);
          result_len += name_len;
          result[result_len++] = '\0';
          memcpy (result + result_len, body_hash, 32);
          result_len += 32;
          result[result_len++] = '\0';
        }
      free (funcs);
    }

  /* Append shell options bitmap */
  {
    unsigned int optbits = 0;
    char optbuf[32];
    int optlen;

    if (exit_immediately_on_error) optbits |= 0x01;
    if (unbound_vars_is_error)     optbits |= 0x04;
    if (pipefail_opt)              optbits |= 0x08;
    if (disallow_filename_globbing) optbits |= 0x10;

    optlen = snprintf (optbuf, sizeof(optbuf), "opts:%x", optbits);

    while (result_len + optlen + 1 >= result_size)
      {
        result_size *= 2;
        result = (char *)xrealloc (result, result_size);
      }
    memcpy (result + result_len, optbuf, optlen);
    result_len += optlen;
    result[result_len] = '\0';
  }

  return result;
}

/* ---- Eligibility check ---- */

static int
jit_is_state_modifying_builtin (const char *name)
{
  struct builtin *b;
  static const char *state_modifying[] = {
    "cd", "pushd", "popd", "dirs", "read", "shift",
    "trap", "umask", "ulimit", "getopts", "wait",
    "kill", "jobs", "bg", "fg", "disown", "suspend",
    "logout", "times", "hash", NULL
  };
  int i;

  b = builtin_address_internal (name, 1);
  if (!b || !(b->flags & BUILTIN_ENABLED))
    return 0;

  if (b->flags & SPECIAL_BUILTIN)
    return 1;

  if (b->flags & (ASSIGNMENT_BUILTIN | LOCALVAR_BUILTIN))
    return 1;

  for (i = 0; state_modifying[i]; i++)
    if (STREQ (name, state_modifying[i]))
      return 1;

  return 0;
}

static int
jit_has_assignments_in_simple (WORD_LIST *words)
{
  int saw_non_assignment = 0;
  WORD_LIST *w;

  for (w = words; w; w = w->next)
    {
      if (w->word->flags & W_ASSIGNMENT)
        {
          if (saw_non_assignment)
            return 1;
        }
      else
        saw_non_assignment = 1;
    }
  return 0;
}

static int
jit_has_assignments (COMMAND *command);

static int
jit_has_assignments_in_tree (COMMAND *cmd)
{
  if (!cmd) return 0;
  return jit_has_assignments (cmd);
}

static int
jit_has_assignments (COMMAND *command)
{
  if (!command) return 0;

  switch (command->type)
    {
    case cm_simple:
      return jit_has_assignments_in_simple (command->value.Simple->words);

    case cm_for:
      {
        COMMAND *body = command->value.For->action;
        return body ? jit_has_assignments (body) : 0;
      }

#if defined (ARITH_FOR_COMMAND)
    case cm_arith_for:
      {
        COMMAND *body = command->value.ArithFor->action;
        return body ? jit_has_assignments (body) : 0;
      }
#endif

    case cm_while:
    case cm_until:
      {
        COMMAND *test = command->value.While->test;
        COMMAND *body = command->value.While->action;
        return ((test ? jit_has_assignments (test) : 0) ||
                (body ? jit_has_assignments (body) : 0));
      }

    case cm_group:
      {
        COMMAND *gcmd = command->value.Group->command;
        return gcmd ? jit_has_assignments (gcmd) : 0;
      }

    default:
      return 0;
    }
}

static int
jit_is_eligible (COMMAND *command, const char *source)
{
  if (strlen (source) < (size_t)jit_min_complexity)
    return 0;

  switch (command->type)
    {
    case cm_simple:
    case cm_for:
    case cm_while:
#if defined (ARITH_FOR_COMMAND)
    case cm_arith_for:
#endif
    case cm_arith:
      break;
    default:
      return 0;
    }

  /* Check for excluded constructs in source text */
  if (strstr (source, "eval ") || strstr (source, "eval("))
    return 0;
  if (strstr (source, "exec "))
    return 0;
  if (strstr (source, "source ") || strstr (source, ". "))
    return 0;
  if (strstr (source, "<(") || strstr (source, ">("))
    return 0;
  if (strstr (source, "<<") || strstr (source, "<<<"))
    return 0;

  /* Check for variable assignments */
  if (jit_has_assignments (command))
    return 0;

  /* For cm_simple: check the command is not state-modifying */
  if (command->type == cm_simple)
    {
      WORD_LIST *words = command->value.Simple->words;
      while (words && (words->word->flags & W_ASSIGNMENT))
        words = words->next;
      if (words && words->word && words->word->word)
        {
          if (jit_is_state_modifying_builtin (words->word->word))
            return 0;
        }
    }

  return 1;
}

/* ---- Variable injection ---- */

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
      SHELL_VAR *var;
      char *val;

      if (*s != '$')
        continue;

      s++;
      if (*s == '{')
        {
          s++;
          vlen = 0;
          while (*s && *s != '}' && vlen < (int)sizeof(varname) - 1)
            {
              if (!isalnum ((unsigned char)*s) && *s != '_')
                break;
              varname[vlen++] = *s++;
            }
          varname[vlen] = '\0';
          if (*s == '}') s++;
          else continue;
        }
      else if (isalpha ((unsigned char)*s) || *s == '_')
        {
          vlen = 0;
          while (*s && (isalnum ((unsigned char)*s) || *s == '_')
                 && vlen < (int)sizeof(varname) - 1)
            varname[vlen++] = *s++;
          varname[vlen] = '\0';
          s--;
        }
      else
        continue;

      if (vlen == 0)
        continue;

      /* Skip special parameters */
      if (strlen (varname) == 1 && strchr ("?#@*!_", varname[0]))
        continue;

      var = find_variable (varname);
      if (!var)
        continue;

      if (exported_p (var) || function_p (var) || array_p (var))
        continue;

      val = get_variable_value (var);
      if (!val)
        continue;

      if (temporary_env == 0)
        temporary_env = hash_create (4);

      {
        SHELL_VAR *tvar;
        BUCKET_CONTENTS *item;

        item = hash_search (varname, temporary_env, 0);
        if (!item)
          {
            /* Create a new SHELL_VAR for temporary_env */
            tvar = (SHELL_VAR *)xmalloc (sizeof (SHELL_VAR));
            tvar->name = savestring (varname);
            tvar->value = NULL;
            CLEAR_EXPORTSTR (tvar);
            tvar->dynamic_value = NULL;
            tvar->assign_func = NULL;
            tvar->attributes = (att_exported | att_tempvar);
            tvar->context = 0;

            item = hash_insert (savestring (varname), temporary_env, HASH_NOSRCH);
            item->data = (PTR_T)tvar;
          }
        else
          {
            tvar = (SHELL_VAR *)item->data;
            FREE (value_cell (tvar));
          }

        var_setvalue (tvar, savestring (val));
      }
    }

  if (temporary_env)
    maybe_make_export_env ();
}

/* ---- Socket communication ---- */

static char *
jit_get_socket_path (void)
{
  static char path[512];
  const char *runtime_dir;

  runtime_dir = get_string_value ("XDG_RUNTIME_DIR");
  if (!runtime_dir)
    runtime_dir = "/tmp";

  snprintf (path, sizeof(path), "%s/bash_jit_%d/socket", runtime_dir, getuid ());
  return path;
}

static int
jit_connect_socket (const char *socket_path)
{
  int fd;
  struct sockaddr_un addr;

  fd = socket (AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -1;

  memset (&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy (addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);

  if (connect (fd, (struct sockaddr *)&addr, sizeof(addr)) < 0)
    {
      close (fd);
      return -1;
    }

  return fd;
}

static void
jit_send_exec_report (const char *fingerprint, const char *source)
{
  char msg[8192];
  int msg_len;
  char *escaped_fp, *escaped_src, *escaped_file;
  const char *source_file;

  if (jit_socket < 0)
    return;

  escaped_fp = jit_json_escape (fingerprint);
  escaped_src = jit_json_escape (source);
  source_file = get_string_value ("BASH_SOURCE");
  if (!source_file) source_file = "";
  escaped_file = jit_json_escape (source_file);

  msg_len = snprintf (msg, sizeof(msg),
    "{\"type\":\"exec\",\"fingerprint\":\"%s\",\"source\":\"%s\","
    "\"context\":{\"pid\":%d,\"source_file\":\"%s\"}}\n",
    escaped_fp, escaped_src, (int)getpid (), escaped_file);

  free (escaped_fp);
  free (escaped_src);
  free (escaped_file);

  if (msg_len > 0 && msg_len < (int)sizeof(msg))
    send (jit_socket, msg, msg_len, MSG_DONTWAIT | MSG_NOSIGNAL);
}

static void
jit_send_register_function (const char *name, const char *body_source)
{
  char msg[8192];
  int msg_len;
  char *escaped_name, *escaped_src;

  if (jit_socket < 0)
    return;

  escaped_name = jit_json_escape (name);
  escaped_src = jit_json_escape (body_source);

  msg_len = snprintf (msg, sizeof(msg),
    "{\"type\":\"register_function\",\"name\":\"%s\",\"source\":\"%s\","
    "\"context\":{\"pid\":%d}}\n",
    escaped_name, escaped_src, (int)getpid ());

  free (escaped_name);
  free (escaped_src);

  if (msg_len > 0 && msg_len < (int)sizeof(msg))
    send (jit_socket, msg, msg_len, MSG_DONTWAIT | MSG_NOSIGNAL);
}

/* ---- Cache verification ---- */

static int
jit_verify_cache (const char *fingerprint, const char *current_source)
{
  char meta_path[512];
  char *meta_content, *stored_source;
  size_t file_size;
  int match;

  snprintf (meta_path, sizeof(meta_path),
            "%s/%s/meta.json", jit_cache_dir, fingerprint);

  meta_content = jit_read_file (meta_path, &file_size);
  if (!meta_content) return 0;

  stored_source = jit_json_extract (meta_content, "source_text");
  free (meta_content);

  if (!stored_source) return 0;

  match = (strcmp (stored_source, current_source) == 0);
  free (stored_source);

  return match;
}

static void
jit_invalidate_cache (const char *fingerprint)
{
  char path[512];

  snprintf (path, sizeof(path), "%s/%s/compiled.py", jit_cache_dir, fingerprint);
  unlink (path);
  snprintf (path, sizeof(path), "%s/%s/meta.json", jit_cache_dir, fingerprint);
  unlink (path);
}

/* ---- Command replacement ---- */

static COMMAND *
jit_make_python_command (const char *fingerprint, COMMAND *original,
                         WORD_LIST *args, const char *source)
{
  COMMAND *cmd;
  SIMPLE_COM *simple;
  WORD_LIST *words, *tail;
  char python_path[512];

  jit_inject_variables (source);

  snprintf (python_path, sizeof(python_path),
            "%s/%s/compiled.py", jit_cache_dir, fingerprint);

  words = make_word_list (make_word ("python3"), NULL);
  tail = words;
  tail->next = make_word_list (make_word (python_path), NULL);
  tail = tail->next;

  /* Copy prefix assignment words from original */
  if (original->type == cm_simple)
    {
      WORD_LIST *orig_words = original->value.Simple->words;
      while (orig_words && (orig_words->word->flags & W_ASSIGNMENT))
        {
          WORD_LIST *assign_word;
          assign_word = make_word_list (copy_word (orig_words->word), NULL);
          assign_word->word->flags |= W_ASSIGNMENT;
          assign_word->next = words;
          words = assign_word;
          orig_words = orig_words->next;
        }
    }

  /* Append extra arguments (for function calls) */
  while (args)
    {
      tail->next = make_word_list (copy_word (args->word), NULL);
      tail = tail->next;
      args = args->next;
    }

  /* Extract redirects from the correct location */
  {
    REDIRECT *redirs;
    if (original->type == cm_simple)
      redirs = original->value.Simple->redirects;
    else
      redirs = original->redirects;

    simple = (SIMPLE_COM *)xmalloc (sizeof (SIMPLE_COM));
    simple->words = words;
    simple->redirects = redirs;
    simple->flags = 0;
    simple->line = original->line;

    cmd = (COMMAND *)xmalloc (sizeof (COMMAND));
    cmd->type = cm_simple;
    cmd->flags = original->flags;
    cmd->redirects = NULL;
    cmd->value.Simple = simple;
  }

  return cmd;
}

/* ---- Daemon connection and auto-start ---- */

static int
jit_connect_or_start_daemon (void)
{
  const char *socket_path;
  int ready_pipe[2];
  pid_t pid;

  socket_path = jit_get_socket_path ();

  /* Try to connect to existing daemon */
  jit_socket = jit_connect_socket (socket_path);
  if (jit_socket >= 0)
    return 0;

  if (pipe (ready_pipe) < 0)
    return -1;

  pid = fork ();
  if (pid < 0)
    {
      close (ready_pipe[0]);
      close (ready_pipe[1]);
      return -1;
    }

  if (pid == 0)
    {
      /* Child: start daemon */
      char pipe_fd_str[16];
      close (ready_pipe[0]);
      snprintf (pipe_fd_str, sizeof(pipe_fd_str), "%d", ready_pipe[1]);
      setenv ("BASH_JIT_READY_PIPE", pipe_fd_str, 1);
      execlp (jit_daemon_path, "bash_jitd", NULL);
      _exit (127);
    }

  /* Parent: wait for readiness signal */
  {
    char ready_byte;
    ssize_t n;
    close (ready_pipe[1]);
    n = read (ready_pipe[0], &ready_byte, 1);
    close (ready_pipe[0]);

    if (n <= 0)
      return -1;
  }

  /* Daemon is ready */
  jit_socket = jit_connect_socket (socket_path);
  return (jit_socket >= 0) ? 0 : -1;
}

/* ---- Main interface ---- */

int
bash_jit_check (COMMAND *command, WORD_LIST *args, COMMAND **replacement)
{
  char *source;
  char fingerprint[33];
  jit_snippet_entry *entry;
  BUCKET_CONTENTS *item;

  *replacement = NULL;

  if (!bash_jit_enabled)
    return JIT_CHECK_NORMAL;

  /* Skip non-simple commands entirely */
  if (command->type != cm_simple && command->type != cm_for
      && command->type != cm_while
      && command->type != cm_arith_for && command->type != cm_arith)
    return JIT_CHECK_NORMAL;

  /* 1. Get normalized source text */
  source = savestring (make_command_string (command));
  if (!source || !*source)
    {
      FREE (source);
      return JIT_CHECK_NORMAL;
    }

  /* 2. Check eligibility */
  if (!jit_is_eligible (command, source))
    {
      FREE (source);
      return JIT_CHECK_NORMAL;
    }

  /* 3. Compute fingerprint with context */
  {
    char *context;
    size_t src_len, ctx_len, total;
    char *fp_input;

    context = jit_build_context ();
    src_len = strlen (source);
    ctx_len = strlen (context);
    total = src_len + 1 + ctx_len;
    fp_input = (char *)xmalloc (total + 1);
    memcpy (fp_input, source, src_len + 1);
    memcpy (fp_input + src_len + 1, context, ctx_len + 1);
    fnv128_hex (fp_input, fingerprint);
    free (fp_input);
    free (context);
  }

  /* 4. Check local cache */
  item = hash_search (fingerprint, jit_local_cache, HASH_CREATE);
  if (item->data)
    {
      entry = (jit_snippet_entry *)item->data;
      if (entry->is_compiled == 1)
        {
          *replacement = jit_make_python_command (fingerprint, command, args, source);
          FREE (source);
          return JIT_CHECK_COMPILED;
        }

      entry->local_count++;

      /* Periodically check filesystem (every 10 invocations) */
      if (entry->is_compiled == 0 && entry->local_count % 10 == 0)
        {
          char cache_path[512];
          snprintf (cache_path, sizeof(cache_path),
                   "%s/%s/compiled.py", jit_cache_dir, fingerprint);
          if (access (cache_path, R_OK) == 0)
            {
              if (jit_verify_cache (fingerprint, source))
                {
                  entry->is_compiled = 1;
                  *replacement = jit_make_python_command (fingerprint, command, args, source);
                  FREE (source);
                  return JIT_CHECK_COMPILED;
                }
              else
                {
                  jit_invalidate_cache (fingerprint);
                  entry->is_compiled = -1;
                }
            }
          if (entry->local_count > 100)
            entry->is_compiled = -1;
        }
    }
  else
    {
      /* First time seeing this fingerprint */
      entry = (jit_snippet_entry *)xmalloc (sizeof (jit_snippet_entry));
      entry->local_count = 1;
      entry->is_compiled = 0;
      entry->fingerprint = savestring (fingerprint);
      item->data = (PTR_T)entry;
    }

  /* 5. Report to daemon */
  jit_send_exec_report (fingerprint, source);
  FREE (source);

  /* Record start time for duration tracking */
  clock_gettime (CLOCK_MONOTONIC, &jit_exec_start);
  memcpy (jit_pending_fingerprint, fingerprint, 33);

  return JIT_CHECK_NORMAL;
}

void
bash_jit_exec_done (void)
{
  struct timespec end;
  long ms;
  char msg[512];
  int msg_len;

  if (!bash_jit_enabled || jit_pending_fingerprint[0] == '\0')
    return;

  clock_gettime (CLOCK_MONOTONIC, &end);
  ms = (end.tv_sec - jit_exec_start.tv_sec) * 1000L
       + (end.tv_nsec - jit_exec_start.tv_nsec) / 1000000L;

  if (jit_socket >= 0 && ms >= 0)
    {
      msg_len = snprintf (msg, sizeof(msg),
        "{\"type\":\"exec_duration\",\"fingerprint\":\"%s\",\"duration_ms\":%ld}\n",
        jit_pending_fingerprint, ms);
      if (msg_len > 0 && msg_len < (int)sizeof(msg))
        send (jit_socket, msg, msg_len, MSG_DONTWAIT | MSG_NOSIGNAL);
    }

  jit_pending_fingerprint[0] = '\0';
}

/* ---- Function-specific JIT check ---- */

int
bash_jit_function_check (SHELL_VAR *var, WORD_LIST *words, COMMAND **replacement)
{
  char *body_source;
  char fingerprint[33];
  jit_snippet_entry *entry;
  BUCKET_CONTENTS *item;

  *replacement = NULL;

  if (!bash_jit_enabled)
    return JIT_CHECK_NORMAL;

  body_source = savestring (
    named_function_string (var->name, function_cell (var), FUNC_MULTILINE));
  if (!body_source)
    return JIT_CHECK_NORMAL;

  /* Check eligibility of function body */
  {
    COMMAND *body = function_cell (var);
    if (!body || !jit_is_eligible (body, body_source))
      {
        FREE (body_source);
        return JIT_CHECK_NORMAL;
      }
  }

  /* Compute fingerprint from function body */
  {
    char *context;
    size_t src_len, ctx_len, total;
    char *fp_input;

    context = jit_build_context ();
    src_len = strlen (body_source);
    ctx_len = strlen (context);
    total = src_len + 1 + ctx_len;
    fp_input = (char *)xmalloc (total + 1);
    memcpy (fp_input, body_source, src_len + 1);
    memcpy (fp_input + src_len + 1, context, ctx_len + 1);
    fnv128_hex (fp_input, fingerprint);
    free (fp_input);
    free (context);
  }

  /* Check local cache */
  item = hash_search (fingerprint, jit_local_cache, HASH_CREATE);
  if (item->data)
    {
      entry = (jit_snippet_entry *)item->data;
      if (entry->is_compiled == 1)
        {
          jit_inject_variables (body_source);
          *replacement = jit_make_python_command (fingerprint, NULL, words, body_source);
          FREE (body_source);
          return JIT_CHECK_COMPILED;
        }

      entry->local_count++;
      if (entry->is_compiled == 0 && entry->local_count % 10 == 0)
        {
          char cache_path[512];
          snprintf (cache_path, sizeof(cache_path),
                   "%s/%s/compiled.py", jit_cache_dir, fingerprint);
          if (access (cache_path, R_OK) == 0)
            {
              if (jit_verify_cache (fingerprint, body_source))
                {
                  entry->is_compiled = 1;
                  jit_inject_variables (body_source);
                  *replacement = jit_make_python_command (fingerprint, NULL, words, body_source);
                  FREE (body_source);
                  return JIT_CHECK_COMPILED;
                }
              else
                {
                  jit_invalidate_cache (fingerprint);
                  entry->is_compiled = -1;
                }
            }
          if (entry->local_count > 100)
            entry->is_compiled = -1;
        }
    }
  else
    {
      entry = (jit_snippet_entry *)xmalloc (sizeof (jit_snippet_entry));
      entry->local_count = 1;
      entry->is_compiled = 0;
      entry->fingerprint = savestring (fingerprint);
      item->data = (PTR_T)entry;
    }

  /* Report to daemon */
  jit_send_exec_report (fingerprint, body_source);
  FREE (body_source);

  return JIT_CHECK_NORMAL;
}

/* ---- Function registration ---- */

void
bash_jit_register_function (const char *name, COMMAND *body)
{
  if (!bash_jit_enabled)
    return;

  /* Don't call make_command_string() here — it can corrupt the command
     tree when called during function definition (the command tree is
     shared with the function variable).  The daemon only uses the
     registration for bookkeeping; the actual source is sent with the
     exec report when the function is called. */
  jit_send_register_function (name, "");
}

/* ---- Cleanup ---- */

static void
jit_free_entry (PTR_T data)
{
  jit_snippet_entry *entry = (jit_snippet_entry *)data;
  if (entry)
    {
      FREE (entry->fingerprint);
      free (entry);
    }
}

void
bash_jit_cleanup (void)
{
  if (!bash_jit_enabled)
    return;

  if (jit_socket >= 0)
    {
      close (jit_socket);
      jit_socket = -1;
    }

  if (jit_local_cache)
    {
      hash_flush (jit_local_cache, jit_free_entry);
      hash_dispose (jit_local_cache);
      jit_local_cache = NULL;
    }

  FREE (jit_cache_dir);
  FREE (jit_daemon_path);
}

static void
bash_jit_cleanup_wrapper (void *unused)
{
  (void)unused;
  bash_jit_cleanup ();
}

/* ---- Whole-script JIT compilation ---- */

/*
 * Try to execute a compiled Python version of the given script.
 * If a compiled version exists in cache, execvp() python3 (never returns).
 * If not, send the script to the daemon for async compilation and return -1.
 */
int
bash_jit_try_script (const char *script_path)
{
  char *content;
  size_t content_len;
  char fingerprint[33];
  char cache_path[512];
  char py_path[512];

  if (!bash_jit_enabled || !jit_cache_dir || !script_path)
    return -1;

  /* 1. Read script file */
  content = jit_read_file (script_path, &content_len);
  if (!content || content_len == 0)
    return -1;

  /* 2. Compute fingerprint from script content only */
  fnv128_hex (content, fingerprint);

  /* 3. Check if compiled.py exists */
  snprintf (cache_path, sizeof (cache_path),
            "%s/%s", jit_cache_dir, fingerprint);
  snprintf (py_path, sizeof (py_path),
            "%s/compiled.py", cache_path);

  if (access (py_path, R_OK) == 0)
    {
      /* Compiled version found — execvp python3 */
      char **new_argv;
      int argc, i;
      WORD_LIST *args;

      /* Count positional parameters: $1..$9 + rest_of_args */
      argc = 2; /* python3 + compiled.py */
      for (i = 1; i <= 9 && dollar_vars[i]; i++)
        argc++;
      for (args = rest_of_args; args; args = args->next)
        argc++;
      argc++; /* NULL terminator */

      new_argv = (char **)xmalloc (sizeof (char *) * argc);

      i = 0;
      new_argv[i++] = "python3";
      new_argv[i++] = py_path;

      for (int j = 1; j <= 9 && dollar_vars[j]; j++)
        new_argv[i++] = dollar_vars[j];
      for (args = rest_of_args; args; args = args->next)
        new_argv[i++] = args->word->word;
      new_argv[i] = NULL;

      /* Set BASH_JIT_SCRIPT so Python knows the original script path */
      setenv ("BASH_JIT_SCRIPT", script_path, 1);

      /* Close JIT socket before exec */
      if (jit_socket >= 0)
        {
          close (jit_socket);
          jit_socket = -1;
        }

      execvp ("python3", new_argv);

      /* execvp failed — fall through to bash */
      free (new_argv);
      unsetenv ("BASH_JIT_SCRIPT");
    }

  /* 4. No compiled version — send to daemon for async compilation */
  if (jit_socket >= 0)
    {
      char *escaped_fp, *escaped_src;
      char msg[65536];
      int msg_len;

      escaped_fp = jit_json_escape (fingerprint);
      escaped_src = jit_json_escape (content);

      msg_len = snprintf (msg, sizeof (msg),
        "{\"type\":\"exec_script\",\"fingerprint\":\"%s\",\"source\":\"%s\"}\n",
        escaped_fp, escaped_src);

      if (msg_len > 0 && msg_len < (int)sizeof (msg))
        send (jit_socket, msg, msg_len, MSG_DONTWAIT | MSG_NOSIGNAL);

      FREE (escaped_fp);
      FREE (escaped_src);
    }

  FREE (content);
  return -1;
}

/* ---- Initialization ---- */

void
bash_jit_init (void)
{
  const char *val;

  val = get_string_value ("BASH_JIT");
  if (!val || !*val)
    return;

  bash_jit_enabled = 1;

  /* Read configuration */
  val = get_string_value ("BASH_JIT_CACHE_DIR");
  if (val && *val)
    jit_cache_dir = savestring (val);
  else
    {
      const char *home;
      val = get_string_value ("XDG_CACHE_HOME");
      if (val && *val)
        {
          jit_cache_dir = (char *)xmalloc (strlen (val) + 10);
          sprintf (jit_cache_dir, "%s/bash_jit", val);
        }
      else
        {
          home = get_string_value ("HOME");
          if (!home) home = "/tmp";
          jit_cache_dir = (char *)xmalloc (strlen (home) + 25);
          sprintf (jit_cache_dir, "%s/.cache/bash_jit", home);
        }
    }

  val = get_string_value ("BASH_JIT_DAEMON");
  if (val && *val)
    jit_daemon_path = savestring (val);
  else
    jit_daemon_path = savestring ("bash_jitd");

  val = get_string_value ("BASH_JIT_MIN_COMPLEXITY");
  if (val && *val)
    jit_min_complexity = atoi (val);
  if (jit_min_complexity <= 0)
    jit_min_complexity = 50;

  /* Create local cache hash table */
  jit_local_cache = hash_create (DEFAULT_HASH_BUCKETS);

  /* Connect to daemon (auto-start if needed) */
  jit_connect_or_start_daemon ();

  /* Register cleanup on shell exit */
  add_unwind_protect (bash_jit_cleanup_wrapper, NULL);
}

#endif /* BASH_JIT */
