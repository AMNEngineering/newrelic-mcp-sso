# newrelic-mcp-sso

Client-side installers that add the **New Relic MCP server** to supported Claude and GitHub Copilot clients, authenticating **directly to `mcp.newrelic.com`** via OAuth 2.0 federated through OneLogin.

**Who this is for**: engineers using delegated, per-user New Relic OAuth. Claude Code users on the AMN APIM gateway should use [`AMNEngineering/newrelic-mcp-apim`](https://github.com/AMNEngineering/newrelic-mcp-apim) instead.

## What it does

The Claude installer merges a `newrelic` entry into `~/.claude/.mcp.json` (or creates the file if absent) with an OAuth-direct config:

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

It backs up any existing `~/.claude/.mcp.json` to `~/.claude/.mcp.json.bak-<timestamp>` before merging.

The Copilot installers use each supported client's native schema:

| Surface | Configuration | Support |
|---|---|---|
| GitHub Copilot CLI | `~/.copilot/mcp-config.json` (`mcpServers`) | Supported. Native remote HTTP OAuth is discovered from the New Relic server. |
| GitHub Copilot app | Imports the Copilot CLI user MCP configuration | Supported by the same `~/.copilot/mcp-config.json` entry. |
| GitHub Copilot in VS Code | `<workspace>/.vscode/mcp.json` (`servers`) | Supported. VS Code opens a browser for New Relic OAuth on first connection. |

Every installer backs up an existing destination before merging. The installers do **not** touch unrelated MCP servers or user-owned keys.

The Copilot configuration intentionally contains no `Authorization` header, GitHub token, New Relic API key, client secret, or stored bearer token. Copilot's GitHub login authenticates Copilot only; New Relic starts its own delegated OAuth flow and stores its resulting credentials through the client's credential storage.

## Prerequisites

- **Claude Code ≥ v2.1.195** (for OAuth resource-metadata discovery).
- **GitHub Copilot CLI** for the CLI/app target, or **VS Code ≥ 1.99 with GitHub Copilot** for the VS Code target.
- Your organization must allow MCP servers in GitHub Copilot.
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

### GitHub Copilot app, CLI, and VS Code

The default configures the Copilot app and CLI for your user. VS Code is opt-in because it requires an explicit existing workspace.

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/AMNEngineering/newrelic-mcp-sso/main/install-copilot.sh | bash
```

If a conflicting `newrelic` entry already exists, explicitly replace it:

```bash
curl -fsSL https://raw.githubusercontent.com/AMNEngineering/newrelic-mcp-sso/main/install-copilot.sh |
  bash -s -- --force
```

**Windows (PowerShell):**

```powershell
iwr -useb https://raw.githubusercontent.com/AMNEngineering/newrelic-mcp-sso/main/install-copilot.ps1 | iex
```

Or, from a local clone:

```powershell
.\install-copilot.ps1
```

VS Code configuration requires a local clone or downloaded installer plus an explicit existing workspace:

```bash
bash install-copilot.sh --target vscode --workspace /path/to/repository
```

```powershell
.\install-copilot.ps1 -Target VSCode -Workspace C:\path\to\repository
```

Use `--target all` / `-Target All` with the same workspace option to configure both destinations. `--check` / `-Check` reports without writing, and `--force` / `-Force` explicitly replaces a conflicting `newrelic` entry.

## Verify

1. Restart Claude Code (fully quit + relaunch — MCP config is read at startup).
2. Run `/mcp` — `newrelic` will initially show **needs authentication**.
3. Sign in: `claude mcp login newrelic` (or click the sign-in affordance in the `/mcp` panel). A browser opens → New Relic → OneLogin → back to Claude.
4. `/mcp` should now show `newrelic: ✔ Connected`. Ask for a read, e.g. "list the New Relic accounts I can access."
5. Restart Claude Code again to confirm session persistence (refresh_token keeps you signed in).

### Verify GitHub Copilot

1. Restart Copilot CLI or the GitHub Copilot app.
2. In Copilot CLI, run `copilot mcp get newrelic`. In the app, open **Settings → MCP Servers**.
3. Ask Copilot to use a New Relic tool. Complete the separate New Relic → OneLogin browser flow.
4. In VS Code, open the configured workspace, run **MCP: List Servers**, start `newrelic`, and complete the same New Relic OAuth flow.

Do not provide Copilot's GitHub OAuth token to New Relic. It is a credential for a different resource and is not used by these installers.

## Uninstall

Remove the `newrelic` block from the applicable file:

- Claude Code: `~/.claude/.mcp.json`
- Copilot app/CLI: `~/.copilot/mcp-config.json`
- VS Code: `<workspace>/.vscode/mcp.json`

Any browser session with New Relic can be revoked in the New Relic UI under Account Settings.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `/mcp` doesn't show `newrelic` at all | Claude Code didn't reload the config. Fully quit + relaunch (Command-Q / File → Exit). |
| `newrelic` shows "needs authentication" and browser sign-in fails | Confirm you can log into `one.newrelic.com` via OneLogin directly. If not, it's an NR user-admin issue, not a Claude issue. Request `AZ_JobRole_Observability_NewRelicMcp_User`. |
| Sign-in loops back to "needs authentication" | Try `claude mcp logout newrelic` then `claude mcp login newrelic`. |
| Claude Code < v2.1.195 | Upgrade Claude Code — older versions can't discover the OAuth server via `/.well-known/oauth-protected-resource`. |
| Copilot app does not show `newrelic` | Restart the app. The app imports MCP servers configured for Copilot CLI. |
| Copilot CLI shows an OAuth error | Upgrade Copilot CLI, remove its cached `newrelic` OAuth state, and reconnect. The New Relic endpoint requires its own browser flow. |
| VS Code does not show `newrelic` | Confirm the intended workspace contains `.vscode/mcp.json`, then run **MCP: List Servers**. |

## Security posture

- **Per-user RBAC.** Every action attributes to *your* NR user identity and is bounded by *your* NR role. A read-only role gets read-only access, automatically.
- **No shared key.** Tokens are session-scoped, revocable from the NR UI at any time.
- **No token in MCP config.** OAuth tokens are managed by the client credential store, not written by these installers. Copilot CLI documents a local fallback under `~/.copilot/mcp-oauth-config/` only when keychain-backed storage is unavailable.
- **Separate trust domains.** GitHub/Copilot authentication is never reused as New Relic authorization.

## GitHub Copilot product limitations

- **GitHub.com Copilot cloud agent and Copilot code review are not configured.** GitHub explicitly does not support remote MCP servers that use OAuth on those surfaces.
- **GitHub.com Copilot Chat does not accept arbitrary user-configured remote MCP servers.**
- **JetBrains, Xcode, and Eclipse are not automated here.** GitHub documents their GitHub MCP OAuth experience, but not a portable generic third-party OAuth configuration for New Relic.
- **Visual Studio is not automated here.** Visual Studio supports generic MCP OAuth, but New Relic's current official client setup documents VS Code, not a tested Visual Studio configuration.

## Tests

Run the hosted-safe gate locally:

```powershell
pwsh -File ./Run-Tests.ps1 -Detailed
```

The gate performs local syntax and isolated config-merge tests only. It does not contact GitHub, New Relic, OneLogin, or Azure.

## References

- [GitHub: Adding MCP servers for Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-mcp-servers)
- [GitHub: Customizing the GitHub Copilot app](https://docs.github.com/en/copilot/how-tos/github-copilot-app/customize-github-copilot-app)
- [GitHub: Extending Copilot Chat with MCP servers](https://docs.github.com/en/copilot/how-tos/provide-context/use-mcp-in-your-ide/extend-copilot-chat-with-mcp)
- [VS Code: MCP configuration reference](https://code.visualstudio.com/docs/agents/reference/mcp-configuration)
- [GitHub: Configure MCP servers for a repository](https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/configure-mcp-servers)
- [New Relic: Set up New Relic MCP](https://docs.newrelic.com/docs/agentic-ai/mcp/setup/)

## History

- **2026-08-06** — added delegated OAuth installers for GitHub Copilot CLI, the GitHub Copilot app, and VS Code.
- **2026-07-29** — `amn-ops-observability` plugin v1.2.0 shipped this OAuth-direct MCP config bundled with the observability skills.
- **2026-07-30** — plugin v1.3.0 removed the MCP from the plugin. Skills stayed universal; the MCP moved here.
- **Sibling repo**: [`AMNEngineering/newrelic-mcp-apim`](https://github.com/AMNEngineering/newrelic-mcp-apim) — same MCP, but authenticated via Entra bearer at APIM with a KV-injected NR key (no per-user NR token). For AMN engineers on the APIM Claude Code path.
