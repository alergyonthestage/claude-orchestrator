# Authentication

> Guide to configuring authentication for containerized Claude Code sessions.

---

## Overview

claude-orchestrator sessions require two types of authentication:

1. **Claude OAuth** — authentication with the Claude API (required)
2. **GitHub Token** — for `git push`, `gh` CLI, and GitHub MCP (optional but recommended)

Both are managed automatically by the framework. In most cases, you just need to configure the tokens once and subsequent sessions work without intervention.

---

## Claude OAuth (default method)

### How it works

Claude Code uses OAuth to authenticate with the Claude API. On macOS, credentials are saved in the system Keychain. The flow is as follows:

1. **At the first `cco start`**: the CLI reads credentials from the macOS Keychain and copies them to `user-config/global/claude-state/.credentials.json`
2. **In subsequent sessions**: the container uses the saved credentials. If the access token has expired, Claude automatically renews it with the refresh token
3. **If you log in on the host** (e.g., after ~90 days of expiry): `cco start` detects the new credentials in the Keychain and automatically updates the file

Credentials are saved in two files (both gitignored):

| File | Contents |
|------|-----------|
| `user-config/global/claude-state/claude.json` | Preferences, onboarding state, MCP |
| `user-config/global/claude-state/.credentials.json` | OAuth tokens (access + refresh) |

Both files are mounted read-write in the container, so renewed credentials are automatically saved.

### Prerequisite

You must have logged in with Claude Code on the host at least once:

```bash
# On the host (outside the container)
claude
# Follow the OAuth flow in the browser
```

After the first login, `cco start` handles everything automatically.

---

## API Key (alternative)

If you prefer to use an API key instead of OAuth (e.g., for CI environments, or if you don't have access to Keychain), you can configure it like this:

### Via secrets.env

```bash
# user-config/global/secrets.env
ANTHROPIC_API_KEY=sk-ant-api03-...
```

### Via --env flag

```bash
cco start my-project --env ANTHROPIC_API_KEY=sk-ant-api03-...
```

### Via project.yml

```yaml
auth:
  method: api_key
```

When `auth.method` is `api_key`, the CLI does not attempt OAuth seeding from Keychain. The key must be available as an environment variable (via `secrets.env` or `--env`).

---

## GitHub Token

The `GITHUB_TOKEN` enables three functionalities in the container:

- **`git push`** — via HTTPS through the `gh` credential helper
- **`gh` CLI** — PR creation, issue management, etc.
- **GitHub MCP** — the GitHub MCP server reads the token from the environment

### Configuration

**1. Create a fine-grained PAT on GitHub:**

Go to GitHub > Settings > Developer Settings > Fine-grained personal access tokens.

Recommended permissions:
- Repository access: select specific repos
- Permissions: Contents (read/write), Pull requests (read/write)

**2. Save the token in secrets.env:**

```bash
echo "GITHUB_TOKEN=github_pat_..." >> ~/claude-orchestrator/user-config/global/secrets.env
```

**3. Start the session:**

```bash
cco start my-project
# [entrypoint] GitHub: authenticated gh CLI via GITHUB_TOKEN
# [entrypoint] GitHub: configured git credential helper
```

The container entrypoint automatically configures `gh auth login` and `gh auth setup-git` when it finds `GITHUB_TOKEN` in the environment.

### Per-project token

If you want to use different tokens for different projects (e.g., PATs with different scopes), create a `secrets.env` per project:

```bash
# projects/my-project/secrets.env
GITHUB_TOKEN=github_pat_project_specific...
```

Per-project secrets override global ones for keys with the same name.

---

## Secret management

Secrets are managed via `.env` files at two levels, both gitignored:

### Global level

```bash
# user-config/global/secrets.env — available in all projects
GITHUB_TOKEN=ghp_...
LINEAR_API_KEY=lin_api_...
SLACK_BOT_TOKEN=xoxb_...
```

### Project level

```bash
# projects/my-project/secrets.env — only for this project
GITHUB_TOKEN=github_pat_project_specific...   # overrides the global one
STRIPE_KEY=sk_test_...                        # only for this project
```

### --env flag

For temporary or session variables:

```bash
cco start my-project --env DEBUG=true --env API_URL=http://localhost:8080
```

### How they are injected

Secrets are passed as `-e` flags to `docker compose run` at startup time. They are never written to `docker-compose.yml` or other generated files.

Precedence order (last one wins):
1. `user-config/global/secrets.env`
2. `projects/<name>/secrets.env`
3. `--env` from CLI

### Format

```bash
# Format: KEY=VALUE (one per line)
# Empty lines and comments (#) are ignored
GITHUB_TOKEN=ghp_...
# This is a variable with spaces in the value
MY_VAR=hello world
```

Malformed lines are ignored with a warning:
```
Warning: secrets.env:3: skipping malformed line (expected KEY=VALUE)
```

---

## Config Repo Authentication

When using `cco pack install`, `cco pack publish`, or `cco project install` with
remote Config Repos, authentication depends on the URL scheme and repository
visibility.

### SSH (recommended for private repos)

SSH-based URLs authenticate via your local SSH key. No additional configuration
is needed:

```bash
cco remote add team git@github.com:my-org/cco-config.git
cco pack install git@github.com:my-org/cco-config.git
cco pack publish my-pack team
```

This is the simplest approach if you have SSH keys configured for GitHub.

### HTTPS with per-remote tokens

For HTTPS-based repos (required when SSH is not available, e.g., CI or
restricted networks), you can save a token per remote:

```bash
# Register remote with token
cco remote add team https://github.com/my-org/cco-config.git --token ghp_xxx

# Or set token separately
cco remote add team https://github.com/my-org/cco-config.git
cco remote set-token team ghp_xxx
```

Once saved, the token is used automatically for all operations involving that
remote — no need to pass `--token` each time:

```bash
cco pack publish my-pack team          # token resolved automatically
cco pack install https://github.com/my-org/cco-config.git  # matched by URL
```

Token management commands:

| Command | Description |
|---|---|
| `cco remote add <n> <url> --token <t>` | Register remote with token |
| `cco remote set-token <name> <token>` | Save or update token |
| `cco remote remove-token <name>` | Remove saved token |
| `cco remote list` | Show remotes with `[token]` indicator |

Tokens are stored in `$USER_CONFIG_DIR/.cco-remotes`, which is gitignored
(machine-specific, never committed to vault).

### HTTPS with --token flag

You can always override or provide a one-time token via `--token`:

```bash
cco pack install https://github.com/other-org/config.git --token ghp_yyy
```

The `--token` flag takes precedence over any saved token.

### HTTPS with GITHUB_TOKEN

If `GITHUB_TOKEN` is set in your environment and the URL contains `github.com`,
it is used as a fallback when no other token is available:

```bash
export GITHUB_TOKEN=ghp_zzz
cco pack install https://github.com/my-org/cco-config.git
```

### Token resolution order

When performing HTTPS operations, CCO resolves the token in this order:

1. `--token` flag (explicit, per-command)
2. Saved token for the remote name (`cco remote set-token`)
3. Saved token matched by URL (`remote_resolve_token_for_url`)
4. `GITHUB_TOKEN` environment variable (for `github.com` URLs)

### Repository visibility scenarios

| Repo type | Install | Publish | Token needed? |
|---|---|---|---|
| **Public** | Anyone | Write access holders | Install: no. Publish: yes |
| **Private** | Repo members | Write access holders | Always |
| **Internal** (org) | Org members | Write access holders | Always |

### Access control patterns

**Read-only for team (only you publish):**

On GitHub, add team members with **Read** access. They can install packs but
cannot push. Create a fine-grained PAT with `contents:read` scope for them.

You (the maintainer) use a PAT with `contents:write` scope, or SSH with push
access.

**Read-write for team (everyone can publish):**

Add team members with **Write** access (or create a GitHub Team with write
permissions). Everyone uses a PAT with `contents:write` scope.

### Multiple organizations

When working with Config Repos from different GitHub organizations or accounts,
each remote can have its own token:

```bash
cco remote add team-a https://github.com/org-a/cco-config.git --token ghp_aaa
cco remote add team-b https://github.com/org-b/cco-config.git --token ghp_bbb
```

Each token can have different scopes and permissions. Operations automatically
use the correct token based on the remote.

### Creating a GitHub fine-grained PAT for Config Repos

1. Go to GitHub > Settings > Developer Settings > Fine-grained personal access tokens
2. Select the target organization
3. Repository access: select the `cco-config` repository
4. Permissions:
   - **For install only**: Contents → Read
   - **For publish**: Contents → Read and write
5. Generate and save with `cco remote set-token`

---

## First authentication (without Keychain)

If you don't have credentials in the macOS Keychain (e.g., first installation, or on Linux), Claude Code requests authentication directly in the container:

1. Start the session: `cco start my-project`
2. Claude Code displays a URL for OAuth login
3. Copy the URL from the terminal (see the copy-paste section in the [Agent Teams guide](agent-teams.md))
4. Open the URL in your browser and complete authentication
5. Credentials are saved in `user-config/global/claude-state/.credentials.json`
6. Subsequent sessions use the saved credentials automatically

---

## Troubleshooting

### "Not logged in" after `cco start`

1. **Check the Keychain** (macOS):
   ```bash
   security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w \
     | python3 -c "import sys,json; print('OK' if json.load(sys.stdin).get('claudeAiOauth',{}).get('accessToken') else 'NO TOKEN')"
   ```

2. **Check the credentials file**:
   ```bash
   jq '.claudeAiOauth | keys' user-config/global/claude-state/.credentials.json
   ```

3. **Check permissions**:
   ```bash
   ls -la user-config/global/claude-state/.credentials.json
   # Must be 600 (-rw-------)
   ```

4. **Force re-seeding**:
   ```bash
   rm user-config/global/claude-state/.credentials.json
   cco start my-project
   ```

### Onboarding screen ("theme: dark")

This happens when `claude.json` has `hasCompletedOnboarding: false`, typically after logout+login on the host. The CLI automatically forces this value to `true` before starting the container. If the problem persists:

```bash
jq '.hasCompletedOnboarding = true' user-config/global/claude-state/claude.json > /tmp/fix.json \
  && mv /tmp/fix.json user-config/global/claude-state/claude.json
```

### Expired token (after ~90 days)

1. Log in on the host: run `claude` and authenticate via browser
2. Start the session: `cco start my-project` — the CLI detects the new credentials in the Keychain and updates automatically

### API key doesn't work

- Verify that `auth.method: api_key` is set in `project.yml`
- Verify that `ANTHROPIC_API_KEY` is present in `secrets.env` or passed with `--env`
- Check that the key starts with `sk-ant-api`
