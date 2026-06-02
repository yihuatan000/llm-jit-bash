#!/usr/bin/env bash
# enter-jit-bash.sh -- configure and enter a JIT-enabled bash shell.
#
# What this script does:
#   1. Locates the JIT-enabled bash binary
#   2. Configures the LLM API key (Anthropic or OpenAI) / base URL
#   3. Sets up PATH, BASH_JIT_DAEMON, BASH_LOADABLES_PATH
#   4. Starts the daemon and drops you into a JIT-enabled bash
#
# Usage:
#   source scripts/enter-jit-bash.sh        # configure + enter shell
#   source scripts/enter-jit-bash.sh --quiet # minimal output
#
# It is meant to be *sourced* (not executed) so the env vars and shell
# stay in your current session.

set -e

QUIET=0
for arg in "$@"; do
  case "$arg" in
    --quiet|-q) QUIET=1 ;;
    --help|-h)
      sed -n '2,14p' "${BASH_SOURCE[0]}"
      return 0 2>/dev/null || exit 0
      ;;
  esac
done

msg()  { [[ $QUIET -eq 1 ]] || echo "$@"; }

# ---- 1. Locate the JIT-enabled bash ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BASH_BIN="${BASH_BIN:-$HOME/local/bash-jit/bin/bash}"

if [[ ! -x "$BASH_BIN" ]]; then
  msg ""
  msg "JIT-enabled bash not found at $BASH_BIN"
  msg "Building from source..."
  (cd "$PROJECT_DIR" && bash scripts/build.sh)
  if [[ ! -x "$BASH_BIN" ]]; then
    echo "ERROR: build succeeded but $BASH_BIN still missing" >&2
    return 1 2>/dev/null || exit 1
  fi
  msg "Build complete: $BASH_BIN"
fi

msg "1. bash: $BASH_BIN"

# ---- 2. Configure LLM API key (Anthropic or OpenAI) ----

# Priority: existing env var > ~/.claude/settings.json > prompt
read_claude_settings() {
  local settings="$HOME/.claude/settings.json"
  if [[ -f "$settings" ]]; then
    # Extract env values using python (portable, handles JSON properly)
    python3 -c "
import json, sys
try:
    with open('$settings') as f:
        data = json.load(f)
    env = data.get('env', {})
    for k in ('ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY', 'ANTHROPIC_BASE_URL',
              'OPENAI_API_KEY', 'OPENAI_BASE_URL', 'BASH_JIT_LLM_MODEL'):
        v = env.get(k, '')
        if v:
            print(f'{k}={v}')
except Exception:
    pass
" 2>/dev/null
  fi
}

resolve_api_config() {
  # Already set in environment? (Anthropic takes priority)
  if [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
    msg "2. API key: ANTHROPIC_AUTH_TOKEN (already set)"
    return
  fi
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    msg "2. API key: ANTHROPIC_API_KEY (already set)"
    return
  fi
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    msg "2. API key: OPENAI_API_KEY (already set)"
    return
  fi

  # Try ~/.claude/settings.json
  local settings_found=0
  while IFS='=' read -r key val; do
    [[ -z "$key" || -z "$val" ]] && continue
    case "$key" in
      ANTHROPIC_AUTH_TOKEN|ANTHROPIC_API_KEY|OPENAI_API_KEY)
        export "$key=$val"
        settings_found=1
        ;;
      ANTHROPIC_BASE_URL|OPENAI_BASE_URL|BASH_JIT_LLM_MODEL)
        export "$key=$val"
        ;;
    esac
  done < <(read_claude_settings)

  if [[ $settings_found -eq 1 ]]; then
    msg "2. API key: loaded from ~/.claude/settings.json"
    return
  fi

  # Prompt the user
  msg ""
  msg "No LLM API key found."
  msg "Set ANTHROPIC_API_KEY, OPENAI_API_KEY, or ANTHROPIC_AUTH_TOKEN to enable LLM compilation."
  msg ""
  if [[ -t 0 ]]; then
    read -rp "Enter your API key (Anthropic or OpenAI, or press Enter to skip): " api_key
    if [[ -n "$api_key" ]]; then
      export ANTHROPIC_API_KEY="$api_key"
      msg "2. API key: set from user input"
    else
      msg "2. API key: SKIPPED (compilation will be unavailable)"
    fi
  else
    msg "2. API key: SKIPPED (not interactive, no key found)"
  fi
}

resolve_base_url() {
  if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
    msg "3. Base URL: $ANTHROPIC_BASE_URL"
    return
  fi
  if [[ -n "${OPENAI_BASE_URL:-}" ]]; then
    msg "3. Base URL: $OPENAI_BASE_URL"
    return
  fi

  msg "3. Base URL: default"
}

resolve_model() {
  if [[ -n "${BASH_JIT_LLM_MODEL:-}" ]]; then
    msg "4. Model: $BASH_JIT_LLM_MODEL"
    return
  fi

  # Anthropic: daemon has correct default, no need to set BASH_JIT_LLM_MODEL
  if [[ -n "${ANTHROPIC_API_KEY:-}" || -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
    msg "4. Model: Anthropic default (daemon decides)"
  # OpenAI: model name varies by provider, must be configured
  elif [[ -n "${OPENAI_API_KEY:-}" ]]; then
    if [[ -t 0 ]]; then
      msg ""
      read -rp "Enter model name for your OpenAI endpoint (e.g. gpt-4o): " model_name
      if [[ -n "$model_name" ]]; then
        export BASH_JIT_LLM_MODEL="$model_name"
        msg "4. Model: $model_name"
      else
        export BASH_JIT_LLM_MODEL="gpt-4o"
        msg "4. Model: gpt-4o (OpenAI default)"
      fi
    else
      export BASH_JIT_LLM_MODEL="gpt-4o"
      msg "4. Model: gpt-4o (OpenAI default)"
    fi
  else
    msg "4. Model: SKIPPED (no API key configured)"
  fi
}

resolve_api_config
resolve_base_url
resolve_model

# ---- 3. Set up JIT environment ----

# Ensure bash_jitd is findable.
if [[ -z "${BASH_JIT_DAEMON:-}" ]]; then
  export BASH_JIT_DAEMON="$PROJECT_DIR/scripts/bash_jitd"
fi

# Add project scripts/ to PATH so 'jit' CLI and bash_jitd are accessible.
case ":$PATH:" in
  *":$PROJECT_DIR/scripts:"*) ;;
  *) export PATH="$PROJECT_DIR/scripts:$PATH" ;;
esac

# Loadable builtins — bash needs to know where .so files live.
LOADABLES_DIR="$HOME/local/bash-jit/lib/bash"
if [[ -d "$LOADABLES_DIR" ]]; then
  case ":${BASH_LOADABLES_PATH:-}:" in
    *":$LOADABLES_DIR:"*) ;;
    *) export BASH_LOADABLES_PATH="${BASH_LOADABLES_PATH:+$BASH_LOADABLES_PATH:}$LOADABLES_DIR" ;;
  esac
fi

# Master switch.
export BASH_JIT=1

msg "5. BASH_JIT=1"
msg "6. BASH_JIT_DAEMON=$BASH_JIT_DAEMON"
msg "7. PATH includes $PROJECT_DIR/scripts"
[[ -d "$LOADABLES_DIR" ]] && msg "8. BASH_LOADABLES_PATH includes $LOADABLES_DIR"

# ---- 4. Start daemon ----
if ! jit status >/dev/null 2>&1; then
  jit start
  sleep 0.5
  if jit status >/dev/null 2>&1; then
    msg "9. daemon started"
  else
    msg "9. daemon FAILED to start (JIT will auto-start on first command)"
  fi
else
  msg "9. daemon already running"
fi

# ---- 5. Enter JIT-enabled bash ----

# Put JIT bash first in PATH so that running 'bash' inside the shell uses
# the JIT-enabled build rather than the system /usr/bin/bash.
BASH_BIN_DIR="$(dirname "$BASH_BIN")"
case ":$PATH:" in
  *":$BASH_BIN_DIR:"*) ;;
  *) export PATH="$BASH_BIN_DIR:$PATH" ;;
esac

# Generate a custom rcfile that sources the user's ~/.bashrc first, then
# re-prepends the JIT bash directory to PATH.  This ensures that startup
# files cannot override our PATH priority.
JIT_RCFILE=$(mktemp "${TMPDIR:-/tmp}/bash-jit-rc.XXXXXX")
chmod 600 "$JIT_RCFILE"
cat > "$JIT_RCFILE" <<RCFILE
# -- bash-jit injected rcfile --
# Source the user's original ~/.bashrc
if [[ -f "$HOME/.bashrc" ]]; then
  source "$HOME/.bashrc"
fi

# Force-prepend JIT bash directory to PATH regardless of what .bashrc did
export PATH="$BASH_BIN_DIR:\$PATH"
RCFILE

msg ""
msg "Entering JIT-enabled bash.  Type 'exit' to return."
msg ""

exec "$BASH_BIN" --rcfile "$JIT_RCFILE"
