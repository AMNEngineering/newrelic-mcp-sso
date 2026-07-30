#!/usr/bin/env bash
# install.sh — add the New Relic MCP (OAuth-direct via OneLogin) to Claude Code.
#
# Merges an `newrelic` server entry into ~/.claude/.mcp.json non-destructively.
# Idempotent: re-running is a no-op. Use --check to validate without modifying.
#
# For AMN engineers on the Anthropic-direct Claude Code subscription cohort.
# APIM Claude Code users should install from AMNEngineering/newrelic-mcp-apim
# instead.

set -euo pipefail

# ------ ui helpers ------
c_ok='\033[32m'; c_warn='\033[33m'; c_fail='\033[31m'; c_head='\033[36m'; c_reset='\033[0m'
ok()   { printf "${c_ok}✓${c_reset} %s\n" "$*"; }
warn() { printf "${c_warn}!${c_reset} %s\n" "$*"; }
fail() { printf "${c_fail}✗${c_reset} %s\n" "$*" 1>&2; }
info() { printf "  %s\n" "$*"; }
head() { printf "\n${c_head}== %s ==${c_reset}\n" "$*"; }

# ------ args ------
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check|-c) CHECK_ONLY=1 ;;
    --help|-h)
      cat <<'HELP'
install.sh — add New Relic MCP (SSO / OAuth-direct) to Claude Code.

Usage:
  install.sh            Install (merge into ~/.claude/.mcp.json).
  install.sh --check    Validate + report only, no modifications.
  install.sh --help     Show this help.
HELP
      exit 0
      ;;
    *) warn "unknown arg: $arg" ;;
  esac
done

head "New Relic MCP — SSO / OAuth-direct install"

# ------ locate config file ------
CLAUDE_DIR="${HOME}/.claude"
CFG_FILE="${CLAUDE_DIR}/.mcp.json"

if [[ ! -d "$CLAUDE_DIR" ]]; then
  if [[ $CHECK_ONLY -eq 1 ]]; then
    warn "~/.claude does not exist. Claude Code may not be installed for this user."
    exit 0
  fi
  info "Creating $CLAUDE_DIR"
  mkdir -p "$CLAUDE_DIR"
fi

# ------ prereq check: Claude Code CLI ------
if ! command -v claude >/dev/null 2>&1; then
  warn "'claude' CLI not found on PATH. Install Claude Code first (see AMNEngineering/amn-claude-code-client)."
  # Don't fail — the config can still be dropped for later CLI installs / for the Desktop app.
fi

# ------ prereq check: jq (for the merge) ------
if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required for a safe non-destructive merge. Install: brew install jq  (macOS) / apt install jq  (Debian)."
  exit 1
fi

# ------ current state ------
if [[ -f "$CFG_FILE" ]]; then
  info "Found existing $CFG_FILE"
  if jq empty "$CFG_FILE" >/dev/null 2>&1; then
    ok "existing config is valid JSON"
  else
    fail "existing $CFG_FILE is not valid JSON — refusing to touch it. Fix or move aside and re-run."
    exit 1
  fi
  HAS_NEWRELIC=$(jq -r '.mcpServers.newrelic // empty | if . == "" then "no" else "yes" end' "$CFG_FILE" 2>/dev/null || echo "no")
  if [[ "$HAS_NEWRELIC" == "yes" ]]; then
    warn "an 'newrelic' MCP entry already exists in $CFG_FILE."
    info "Current entry:"
    jq '.mcpServers.newrelic' "$CFG_FILE" | sed 's/^/    /'
    if [[ $CHECK_ONLY -eq 1 ]]; then
      info "Check-only: no changes made."
      exit 0
    fi
    info "This installer will OVERWRITE the existing 'newrelic' entry with the SSO/OAuth-direct config."
    printf "Continue? (y/N) "
    read -r resp
    case "$resp" in [yY]|[yY][eE][sS]) : ;; *) info "Aborted."; exit 0 ;; esac
  fi
fi

# ------ the SSO/OAuth-direct entry ------
NEWRELIC_ENTRY=$(cat <<'JSON'
{
  "type": "http",
  "url": "https://mcp.newrelic.com/mcp/",
  "oauth": { "scopes": "openid profile email" }
}
JSON
)

if [[ $CHECK_ONLY -eq 1 ]]; then
  ok "Check-only mode. Would merge this into $CFG_FILE:"
  echo "$NEWRELIC_ENTRY" | sed 's/^/    /'
  exit 0
fi

# ------ backup ------
if [[ -f "$CFG_FILE" ]]; then
  BACKUP="${CFG_FILE}.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$CFG_FILE" "$BACKUP"
  ok "backed up existing config → $BACKUP"
fi

# ------ merge ------
if [[ -f "$CFG_FILE" ]]; then
  jq --argjson entry "$NEWRELIC_ENTRY" \
     '.mcpServers = ((.mcpServers // {}) | .newrelic = $entry)' \
     "$CFG_FILE" > "${CFG_FILE}.tmp"
  mv "${CFG_FILE}.tmp" "$CFG_FILE"
else
  jq --argjson entry "$NEWRELIC_ENTRY" \
     -n '{ mcpServers: { newrelic: $entry } }' \
     > "$CFG_FILE"
fi

ok "newrelic MCP added to $CFG_FILE"

# ------ verify JSON well-formed after write ------
if ! jq empty "$CFG_FILE" >/dev/null 2>&1; then
  fail "post-write validation failed. Restoring backup."
  [[ -n "${BACKUP:-}" ]] && cp "$BACKUP" "$CFG_FILE" && info "restored from $BACKUP"
  exit 1
fi

head "Next steps"
info "1. Fully quit Claude Code (Cmd-Q / File → Exit) and relaunch."
info "2. Run /mcp — 'newrelic' will show 'needs authentication'."
info "3. Run 'claude mcp login newrelic' — a browser will open."
info "4. Sign in via OneLogin. /mcp should then show 'newrelic: ✔ Connected'."
echo ""
info "You must be in the AZ_JobRole_Observability_NewRelicMcp_User AD group for"
info "the OneLogin → New Relic handshake to succeed. If it fails, request the group"
info "via ServiceNow, then re-run 'claude mcp login newrelic'."
echo ""
