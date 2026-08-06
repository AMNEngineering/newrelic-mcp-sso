#!/usr/bin/env bash
# Add the New Relic OAuth MCP to GitHub Copilot clients.
#
# The Copilot target configures Copilot CLI and VS Code Agent Host. The GitHub
# Copilot app imports the same user-level config, but currently has known
# third-party OAuth host bugs. The VS Code target writes workspace config.

set -euo pipefail

c_ok='\033[32m'; c_warn='\033[33m'; c_fail='\033[31m'; c_head='\033[36m'; c_reset='\033[0m'
ok()   { printf "${c_ok}[OK]${c_reset} %s\n" "$*"; }
warn() { printf "${c_warn}!${c_reset} %s\n" "$*"; }
fail() { printf "${c_fail}[X]${c_reset} %s\n" "$*" 1>&2; }
info() { printf "  %s\n" "$*"; }
head() { printf "\n${c_head}== %s ==${c_reset}\n" "$*"; }

CHECK_ONLY=0
FORCE=0
TARGET="copilot"
WORKSPACE="$PWD"

while (($#)); do
  case "$1" in
    --check|-c)
      CHECK_ONLY=1
      shift
      ;;
    --force|-f)
      FORCE=1
      shift
      ;;
    --target)
      if (($# < 2)) || [[ -z "$2" || "$2" == -* ]]; then
        fail "--target requires a value (allowed: all, copilot, vscode)"
        exit 1
      fi
      TARGET="$2"
      shift 2
      ;;
    --target=*)
      TARGET="${1#--target=}"
      shift
      ;;
    --workspace)
      if (($# < 2)) || [[ -z "$2" || "$2" == -* ]]; then
        fail "--workspace requires a directory"
        exit 1
      fi
      WORKSPACE="$2"
      shift 2
      ;;
    --workspace=*)
      WORKSPACE="${1#--workspace=}"
      shift
      ;;
    --help|-h)
      cat <<'HELP'
install-copilot.sh - add New Relic MCP to supported GitHub Copilot clients.

Usage:
  install-copilot.sh                         Configure Copilot CLI/Agent Host (shared with app).
  install-copilot.sh --target copilot        Configure Copilot CLI/Agent Host (shared with app).
  install-copilot.sh --target vscode         Configure VS Code for the current workspace.
  install-copilot.sh --workspace /path/repo  Choose the VS Code workspace.
  install-copilot.sh --check                 Validate and report without modifying files.
  install-copilot.sh --force                 Replace a conflicting newrelic entry.

Targets: all, copilot, vscode
HELP
      exit 0
      ;;
    -*)
      fail "unknown option: $1"
      exit 1
      ;;
    *)
      fail "unexpected argument: $1"
      exit 1
      ;;
  esac
done

case "$TARGET" in
  all|copilot|vscode) : ;;
  *) fail "invalid --target: $TARGET (allowed: all, copilot, vscode)"; exit 1 ;;
esac

case "$TARGET" in
  all|vscode)
    if [[ ! -d "$WORKSPACE" ]]; then
      fail "VS Code workspace does not exist: $WORKSPACE"
      exit 1
    fi
    ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required for a safe non-destructive merge. Install: brew install jq (macOS) / apt install jq (Debian)."
  exit 1
fi

COPILOT_HOME_DIR="${COPILOT_HOME:-${HOME}/.copilot}"
COPILOT_CFG="${COPILOT_HOME_DIR}/mcp-config.json"
VSCODE_CFG="${WORKSPACE%/}/.vscode/mcp.json"

COPILOT_ENTRY=$(jq -n '{
  type: "http",
  url: "https://mcp.newrelic.com/mcp/",
  tools: ["*"]
}')
VSCODE_ENTRY=$(jq -n '{
  type: "http",
  url: "https://mcp.newrelic.com/mcp/"
}')

confirm_replace() {
  local cfg_file=$1

  if [[ $FORCE -eq 1 ]]; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    fail "a different 'newrelic' entry exists in $cfg_file; re-run interactively or pass --force."
    return 1
  fi

  printf "Replace the existing 'newrelic' entry in %s? (y/N) " "$cfg_file"
  read -r response
  case "$response" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) info "Skipped $cfg_file."; return 1 ;;
  esac
}

merge_entry() {
  local cfg_file=$1
  local section=$2
  local entry=$3
  local label=$4
  local current=""
  local desired
  local parent_dir
  local backup
  local temp_file

  desired=$(printf '%s' "$entry" | jq -S -c .)

  if [[ -f "$cfg_file" ]]; then
    info "Found existing $cfg_file"
    if ! jq empty "$cfg_file" >/dev/null 2>&1; then
      fail "existing $cfg_file is not valid JSON - refusing to touch it."
      return 1
    fi
    if ! jq -e --arg section "$section" \
      '(.[$section] == null) or (.[$section] | type == "object")' \
      "$cfg_file" >/dev/null; then
      fail "existing '$section' value in $cfg_file is not an object - refusing to replace it."
      return 1
    fi
    current=$(jq -S -c --arg section "$section" '.[$section].newrelic // empty' "$cfg_file")
  fi

  if [[ -n "$current" && "$current" == "$desired" ]]; then
    ok "$label is already configured in $cfg_file"
    return 0
  fi

  if [[ $CHECK_ONLY -eq 1 ]]; then
    if [[ -n "$current" ]]; then
      warn "$label has a different 'newrelic' entry in $cfg_file; install would replace it."
    else
      ok "$label would add 'newrelic' to $cfg_file"
    fi
    return 0
  fi

  if [[ -n "$current" ]] && ! confirm_replace "$cfg_file"; then
    return 1
  fi

  parent_dir=$(dirname "$cfg_file")
  mkdir -p "$parent_dir"

  if [[ -f "$cfg_file" ]]; then
    backup="${cfg_file}.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$cfg_file" "$backup"
    ok "backed up existing config -> $backup"
    temp_file=$(mktemp "${cfg_file}.tmp.XXXXXX")
    if ! jq --arg section "$section" --argjson entry "$entry" \
      '.[$section] = ((.[$section] // {}) | .newrelic = $entry)' \
      "$cfg_file" > "$temp_file"; then
      rm -f "$temp_file"
      fail "failed to merge $cfg_file"
      return 1
    fi
  else
    temp_file=$(mktemp "${cfg_file}.tmp.XXXXXX")
    jq -n --arg section "$section" --argjson entry "$entry" \
      '{($section): {newrelic: $entry}}' > "$temp_file"
  fi

  if ! jq empty "$temp_file" >/dev/null 2>&1; then
    rm -f "$temp_file"
    fail "post-write validation failed for $cfg_file"
    return 1
  fi

  mv "$temp_file" "$cfg_file"
  ok "$label added 'newrelic' to $cfg_file"
}

head "New Relic MCP - GitHub Copilot OAuth install"

case "$TARGET" in
  all|copilot)
    merge_entry "$COPILOT_CFG" "mcpServers" "$COPILOT_ENTRY" "Copilot CLI/Agent Host (shared with app)"
    ;;
esac

case "$TARGET" in
  all|vscode)
    merge_entry "$VSCODE_CFG" "servers" "$VSCODE_ENTRY" "VS Code GitHub Copilot"
    ;;
esac

if [[ $CHECK_ONLY -eq 1 ]]; then
  info "Check-only mode: no files changed."
  exit 0
fi

head "Next steps"
case "$TARGET" in
  all|copilot)
    info "Copilot CLI: restart it, run 'copilot mcp get newrelic', then use a New Relic tool."
    info "VS Code Agent Host reads this same user-level Copilot MCP configuration."
    warn "Copilot app imports this entry, but active third-party OAuth host bugs may block sign-in."
    info "If app authorization fails, use Copilot CLI or VS Code until the host bug is fixed."
    ;;
esac
case "$TARGET" in
  all|vscode)
    info "VS Code: reopen $WORKSPACE, run 'MCP: List Servers', and start newrelic."
    ;;
esac
info "On first connection, complete the separate New Relic > OneLogin OAuth flow."
info "New Relic issues a separate New Relic OAuth token for its MCP resource."
info "Your GitHub/Copilot sign-in and token are not sent to or reused by New Relic."
