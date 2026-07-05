#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == "" || ${2:-} == "" ]]; then
  echo "Usage: $0 <env-file> <workflow-template> [--render-only]" >&2
  exit 64
fi

env_file=$1
workflow_template=$2
mode=${3:-run}

if [[ ! -f "$env_file" ]]; then
  echo "Env file not found: $env_file" >&2
  exit 66
fi

if [[ ! -f "$workflow_template" ]]; then
  echo "Workflow template not found: $workflow_template" >&2
  exit 66
fi

env_file_sets_codex_command=0
if grep -Eq '^[[:space:]]*CODEX_COMMAND=' "$env_file"; then
  env_file_sets_codex_command=1
fi

# Treat the env file as the per-instance source of truth for routing/rendering
# variables. Without this, a previous render in the same long-lived shell can
# leak LINEAR_PROJECT_ID or other instance-specific values into the next render.
unset \
  SYMPHONY_INSTANCE_NAME SOURCE_REPO_URL LINEAR_PROJECT_SLUG LINEAR_PROJECT_ID \
  LINEAR_WEBHOOK_SECRET LINEAR_ASSIGNEE SYMPHONY_PORT SYMPHONY_HOST \
  SYMPHONY_WORKSPACE_ROOT SYMPHONY_LOGS_ROOT CODING_HARNESS CODEX_COMMAND \
  OPENCODE_BIN OPENCODE_MODEL OPENCODE_LOAD_HERMES_ENV OPENCODE_EXTRA_ARGS \
  OPENCODE_DISABLE_CLAUDE_CODE OPENCODE_DISABLE_CLAUDE_CODE_PROMPT \
  OPENCODE_DISABLE_CLAUDE_CODE_SKILLS SHOT_CALLER_SHARED_ENV SHOT_CALLER_CACHE_ROOT SHOT_CALLER_SHARED_VENV

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ELIXIR_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
RENDER_DIR="$ELIXIR_ROOT/.rendered"
mkdir -p "$RENDER_DIR"

export PATH="/home/airhorns/.local/bin:/home/airhorns/.npm-global/bin:/home/airhorns/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"

: "${SYMPHONY_INSTANCE_NAME:=default}"
: "${SOURCE_REPO_URL:=}"
: "${LINEAR_PROJECT_SLUG:=}"
: "${LINEAR_ASSIGNEE:=}"
: "${SYMPHONY_PORT:=0}"
: "${SYMPHONY_HOST:=127.0.0.1}"
: "${SYMPHONY_WORKSPACE_ROOT:=/home/airhorns/code/symphony-workspaces/${SYMPHONY_INSTANCE_NAME}}"
: "${SYMPHONY_LOGS_ROOT:=$ELIXIR_ROOT/log/${SYMPHONY_INSTANCE_NAME}}"
: "${CODING_HARNESS:=codex}"
: "${OPENCODE_BIN:=/home/airhorns/.local/bin/opencode}"
: "${OPENCODE_MODEL:=openrouter/z-ai/glm-5.2}"
: "${OPENCODE_LOAD_HERMES_ENV:=1}"
: "${OPENCODE_DISABLE_CLAUDE_CODE:=1}"

case "$CODING_HARNESS" in
  codex)
    default_agent_command='codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=high --model gpt-5.4-codex app-server'
    ;;
  opencode)
    default_agent_command="$ELIXIR_ROOT/deploy/harness/opencode_app_server.py"
    ;;
  custom)
    default_agent_command=''
    ;;
  *)
    echo "Unsupported CODING_HARNESS=$CODING_HARNESS; expected codex, opencode, or custom." >&2
    exit 78
    ;;
esac

if [[ "$env_file_sets_codex_command" == 0 && "$CODING_HARNESS" != "custom" ]]; then
  # Avoid leaking a CODEX_COMMAND exported by the invoking shell into an env-file
  # driven instance. Existing codex-backed env files set CODEX_COMMAND explicitly;
  # OpenCode-backed env files can select the harness without repeating the bridge
  # command path.
  CODEX_COMMAND="$default_agent_command"
elif [[ -z "${CODEX_COMMAND:-}" ]]; then
  if [[ -z "$default_agent_command" ]]; then
    echo "CODEX_COMMAND must be set when CODING_HARNESS=custom." >&2
    exit 78
  fi
  CODEX_COMMAND="$default_agent_command"
fi
export CODING_HARNESS OPENCODE_BIN OPENCODE_MODEL OPENCODE_LOAD_HERMES_ENV CODEX_COMMAND
export OPENCODE_DISABLE_CLAUDE_CODE OPENCODE_DISABLE_CLAUDE_CODE_PROMPT OPENCODE_DISABLE_CLAUDE_CODE_SKILLS OPENCODE_EXTRA_ARGS
export SHOT_CALLER_SHARED_ENV SHOT_CALLER_CACHE_ROOT SHOT_CALLER_SHARED_VENV SHOT_CALLER_SHARED_VENV

if [[ -z "$SOURCE_REPO_URL" ]]; then
  echo "SOURCE_REPO_URL must be set in $env_file" >&2
  exit 78
fi

if [[ "$mode" != "--render-only" ]]; then
  if [[ -z "$LINEAR_PROJECT_SLUG" || "$LINEAR_PROJECT_SLUG" == "REPLACE_ME" ]]; then
    echo "LINEAR_PROJECT_SLUG must be set in $env_file before starting Symphony." >&2
    exit 78
  fi
  if [[ -z "${LINEAR_API_KEY:-}" ]]; then
    echo "LINEAR_API_KEY is not set in the environment or env file." >&2
    exit 78
  fi
  case "$CODING_HARNESS" in
    codex)
      if ! command -v codex >/dev/null 2>&1; then
        echo "codex is not on PATH; expected it under ~/.local/bin or ~/.npm-global/bin." >&2
        exit 78
      fi
      ;;
    opencode)
      if [[ ! -x "$OPENCODE_BIN" ]] && ! command -v opencode >/dev/null 2>&1; then
        echo "opencode is not available; expected executable at $OPENCODE_BIN or on PATH." >&2
        exit 78
      fi
      if [[ ! -x "$ELIXIR_ROOT/deploy/harness/opencode_app_server.py" ]]; then
        echo "OpenCode app-server bridge is not executable: $ELIXIR_ROOT/deploy/harness/opencode_app_server.py" >&2
        exit 78
      fi
      if [[ "$OPENCODE_MODEL" == openrouter/* && -z "${OPENROUTER_API_KEY:-}" && ! -f /home/airhorns/.hermes/.env ]]; then
        echo "OPENCODE_MODEL uses OpenRouter, but OPENROUTER_API_KEY is not set and /home/airhorns/.hermes/.env is unavailable." >&2
        exit 78
      fi
      ;;
  esac
fi

mkdir -p "$SYMPHONY_WORKSPACE_ROOT" "$SYMPHONY_LOGS_ROOT"
rendered_workflow="$RENDER_DIR/${SYMPHONY_INSTANCE_NAME}.WORKFLOW.md"
export WORKFLOW_TEMPLATE="$workflow_template"
export RENDERED_WORKFLOW="$rendered_workflow"

python3 <<'PY'
import os
from pathlib import Path

template = Path(os.environ['WORKFLOW_TEMPLATE']).read_text()
replacements = {
    '{{LINEAR_PROJECT_SLUG}}': os.environ.get('LINEAR_PROJECT_SLUG', ''),
    '{{LINEAR_ASSIGNEE}}': os.environ.get('LINEAR_ASSIGNEE', ''),
    '{{SOURCE_REPO_URL}}': os.environ.get('SOURCE_REPO_URL', ''),
    '{{WORKSPACE_ROOT}}': os.environ.get('SYMPHONY_WORKSPACE_ROOT', ''),
    '{{SYMPHONY_HOST}}': os.environ.get('SYMPHONY_HOST', ''),
    '{{CODING_HARNESS}}': os.environ.get('CODING_HARNESS', ''),
    '{{OPENCODE_MODEL}}': os.environ.get('OPENCODE_MODEL', ''),
    '{{CODEX_COMMAND}}': os.environ.get('CODEX_COMMAND', ''),
}
rendered = template
for old, new in replacements.items():
    rendered = rendered.replace(old, new)
Path(os.environ['RENDERED_WORKFLOW']).write_text(rendered)
PY

if [[ "$mode" == "--render-only" ]]; then
  echo "$rendered_workflow"
  exit 0
fi

cd "$ELIXIR_ROOT"
exec ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "$SYMPHONY_LOGS_ROOT" \
  --port "$SYMPHONY_PORT" \
  "$rendered_workflow"
