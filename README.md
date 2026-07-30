# newrelic-mcp-sso

Client-side installer that adds the **New Relic MCP server** to Claude Code, authenticating **directly to `mcp.newrelic.com`** via OAuth 2.0 federated through OneLogin.

**Who this is for**: engineers on the **Anthropic-direct Claude Code subscription** cohort at AMN. If you run Claude Code through the AMN APIM gateway (the default for AMN users), use [`AMNEngineering/newrelic-mcp-apim`](https://github.com/AMNEngineering/newrelic-mcp-apim) instead.

## What it does

1. Merges an `newrelic` entry into `~/.claude/.mcp.json` (or creates the file if absent) with an OAuth-direct config:

   ```json
   {
     "mcpServers": {
       "newrelic": {
         "type": "http",
         "url": "https://mcp.newrelic.com/mcp/",
         "oauth": { "scopes": "openid profile email" }
       }
     }
   }
   ```

2. Backs up any existing `~/.claude/.mcp.json` to `~/.claude/.mcp.json.bak-<timestamp>` before merging.

3. Prints a one-liner reminder to restart Claude Code + run `/mcp` to complete the OAuth handshake.

The installer does **not** touch any other MCP servers you have configured, and it does **not** clobber user-owned keys — the merge is additive.

## Prerequisites

- **Claude Code ≥ v2.1.195** (for OAuth resource-metadata discovery).
- **A New Relic account + role** on the AMN NR tenant. Access is bound to your NR user role (read-only observers should be in a read-only NR role).
- **Membership in `AZ_JobRole_Observability_NewRelicMcp_User`** (Entra AD group) — request via ServiceNow.
- **You are on the Anthropic-direct Claude Code subscription.** If Claude Code sets `CLAUDE_CODE_USE_FOUNDRY=1` or `ANTHROPIC_FOUNDRY_BASE_URL`, you're on the APIM path — use the APIM install repo instead.

## Install

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/AMNEngineering/newrelic-mcp-sso/main/install.sh | bash
```

Or, from a local clone: `bash install.sh`

**Windows (PowerShell):**

```powershell
iwr -useb https://raw.githubusercontent.com/AMNEngineering/newrelic-mcp-sso/main/install.ps1 | iex
```

Or, from a local clone: `.\install.ps1`

Both installers accept `-Check` / `--check` to validate + report without modifying anything.

## Verify

1. Restart Claude Code (fully quit + relaunch — MCP config is read at startup).
2. Run `/mcp` — `newrelic` will initially show **needs authentication**.
3. Sign in: `claude mcp login newrelic` (or click the sign-in affordance in the `/mcp` panel). A browser opens → New Relic → OneLogin → back to Claude.
4. `/mcp` should now show `newrelic: ✔ Connected`. Ask for a read, e.g. "list the New Relic accounts I can access."
5. Restart Claude Code again to confirm session persistence (refresh_token keeps you signed in).

## Uninstall

Remove the `newrelic` block from `~/.claude/.mcp.json` (or delete the file if that was its only entry). Any browser session with New Relic can be revoked in the New Relic UI under Account Settings.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `/mcp` doesn't show `newrelic` at all | Claude Code didn't reload the config. Fully quit + relaunch (Command-Q / File → Exit). |
| `newrelic` shows "needs authentication" and browser sign-in fails | Confirm you can log into `one.newrelic.com` via OneLogin directly. If not, it's an NR user-admin issue, not a Claude issue. Request `AZ_JobRole_Observability_NewRelicMcp_User`. |
| Sign-in loops back to "needs authentication" | Try `claude mcp logout newrelic` then `claude mcp login newrelic`. |
| Claude Code < v2.1.195 | Upgrade Claude Code — older versions can't discover the OAuth server via `/.well-known/oauth-protected-resource`. |

## Security posture

- **Per-user RBAC.** Every action attributes to *your* NR user identity and is bounded by *your* NR role. A read-only role gets read-only access, automatically.
- **No shared key.** Tokens are session-scoped, revocable from the NR UI at any time.
- **No key on disk.** OAuth refresh_token lives in Claude Code's OS-secured credential store, not in `~/.claude/.mcp.json`.

## History

- **2026-07-29** — `amn-ops-observability` plugin v1.2.0 shipped this OAuth-direct MCP config bundled with the observability skills.
- **2026-07-30** — plugin v1.3.0 removed the MCP from the plugin. Skills stayed universal; the MCP moved here.
- **Sibling repo**: [`AMNEngineering/newrelic-mcp-apim`](https://github.com/AMNEngineering/newrelic-mcp-apim) — same MCP, but authenticated via Entra bearer at APIM with a KV-injected NR key (no per-user NR token). For AMN engineers on the APIM Claude Code path.
