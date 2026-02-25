# Claude Code OAuth Authentication in Docker

> Version: 1.0.0
> Status: Implemented
> Related: [architecture.md](./architecture.md) | [docker.md](./docker.md)

---

## 1. Problem

Claude Code runs inside a Docker container (Linux). The host is macOS. The user logs in to Claude on the host — the container must authenticate without requiring a separate login.

**Constraints:**
- Login from host should propagate to containers automatically
- Auth must persist across container restarts (`cco start` / `cco stop`)
- Auth must be shared across all projects (global, not per-project)
- When the container auto-refreshes the token, it must persist
- When the host re-authenticates (e.g., token expiry after ~90 days), the container must pick up the new token

---

## 2. Claude Code Credential Storage (internals)

Claude Code stores OAuth credentials differently per platform:

| Platform | Storage Mechanism | Read Path |
|----------|-------------------|-----------|
| **macOS** | macOS Keychain (`security find-generic-password -s "Claude Code-credentials"`) | Keychain API |
| **Linux** | Plaintext file `~/.claude/.credentials.json` | Direct file read |
| **Windows** | Windows Credential Manager | OS API |

### Key discovery: `~/.claude.json` vs `~/.claude/.credentials.json`

These are **two separate files** with different purposes:

| File | Purpose | Contains auth tokens? |
|------|---------|----------------------|
| `~/.claude.json` | Preferences, MCP servers, session metadata, onboarding state | **No** (on macOS) |
| `~/.claude/.credentials.json` | OAuth credentials (access token + refresh token) | **Yes** (on Linux) |

On macOS, `~/.claude.json` has an `oauthAccount` key with profile info (email, UUID, billing type) but **no tokens**. Tokens are exclusively in the Keychain.

On Linux, `~/.claude/.credentials.json` stores `claudeAiOauth` with:
```json
{
  "claudeAiOauth": {
    "accessToken": "sk-ant-oat01-...",
    "refreshToken": "sk-ant-ort01-...",
    "expiresAt": 1772044474163,
    "scopes": ["user:inference"],
    "subscriptionType": "...",
    "rateLimitTier": "..."
  }
}
```

### macOS Keychain entry format

The Keychain entry (`Claude Code-credentials`) stores the exact same JSON structure as `~/.claude/.credentials.json` on Linux. This makes cross-platform seeding straightforward.

### Source code references (Claude Code 2.1.56)

The credential store selector in `cli.js`:
```javascript
function iO() {
  if (process.platform === "darwin") return $24(H24, af8);  // Keychain + plaintext fallback
  return af8;  // Linux: plaintext only
}
```

The Linux plaintext store (`af8`):
```javascript
{
  name: "plaintext",
  read() {
    let { storagePath } = rf8();  // ~/.claude/.credentials.json
    if (existsSync(storagePath))
      return JSON.parse(readFileSync(storagePath, "utf8"));
    return null;
  },
  update(data) {
    let { storageDir, storagePath } = rf8();
    if (!existsSync(storageDir)) mkdirSync(storageDir);
    writeFileSync(storagePath, JSON.stringify(data), "utf8");
    chmodSync(storagePath, 0o600);  // owner read/write only
  }
}
```

---

## 3. What does NOT work

These approaches were tested and **do not** work for authenticating Claude Code in a Docker container:

| Approach | Why it fails |
|----------|-------------|
| Setting `claudeAiOauth` in `~/.claude.json` | Claude does not read auth tokens from this file (it uses the credential store) |
| `CLAUDE_CODE_OAUTH_TOKEN` env var | Only provides access token (no refresh token). Works for API calls (`-p "say hi"`) but interactive mode shows "Not logged in" |
| Mounting host `~/.claude.json` as seed | macOS `~/.claude.json` does not contain tokens (they're in Keychain) |
| `ANTHROPIC_AUTH_TOKEN` env var | For API gateways/custom auth, not for OAuth |

---

## 4. Implemented Solution

### Architecture

```
┌─── macOS Host ──────────────────────┐
│                                     │
│  macOS Keychain                     │
│  └── "Claude Code-credentials"      │
│      └── { claudeAiOauth: { ... } } │
│                                     │
│  cco start                          │
│  ├── Reads Keychain                 │
│  ├── Compares expiresAt             │
│  └── Seeds .credentials.json       │
│      if keychain is newer           │
│                                     │
│  global/claude-state/               │
│  ├── claude.json          (prefs)   │──── mounted as ~/.claude.json (rw)
│  └── .credentials.json   (auth)    │──── mounted as ~/.claude/.credentials.json (rw)
│                                     │
└─────────────────────────────────────┘
                    │
                    ▼
┌─── Docker Container (Linux) ────────┐
│                                     │
│  /home/claude/                      │
│  ├── .claude.json          (rw)     │  ← preferences, MCP, onboarding
│  └── .claude/                       │
│      ├── .credentials.json (rw)     │  ← OAuth tokens (access + refresh)
│      ├── settings.json     (ro)     │  ← permissions, hooks
│      └── ...                        │
│                                     │
│  Claude Code reads .credentials.json│
│  ├── accessToken valid? Use it      │
│  ├── Expired? Use refreshToken      │
│  └── Updated tokens written back    │
│      to .credentials.json (persists)│
│                                     │
└─────────────────────────────────────┘
```

### File locations

| Host path | Container path | Mode | Purpose |
|-----------|----------------|------|---------|
| `global/claude-state/claude.json` | `/home/claude/.claude.json` | rw | Preferences, MCP servers, onboarding state |
| `global/claude-state/.credentials.json` | `/home/claude/.claude/.credentials.json` | rw | OAuth tokens (access + refresh) |

Both files are in `global/claude-state/` (shared across all projects, gitignored).

### Seeding flow (`cmd_start`)

```bash
# 1. Read macOS Keychain
keychain_json=$(security find-generic-password \
  -s "Claude Code-credentials" -a "$(whoami)" -w)

# 2. Compare expiresAt
keychain_expires=$(jq -r '.claudeAiOauth.expiresAt // 0' <<< "$keychain_json")
file_expires=$(jq -r '.claudeAiOauth.expiresAt // 0' "$global_creds")

# 3. Seed only if Keychain is fresher
if [[ "$keychain_expires" -gt "$file_expires" ]]; then
    cp "$keychain_json" "$global_creds"
    chmod 600 "$global_creds"
fi
```

### Session lifecycle

| Scenario | What happens |
|----------|-------------|
| **First session** | No `.credentials.json` → Keychain seeded → container authenticated |
| **Normal restart** | `.credentials.json` has valid tokens → Claude uses them, auto-refreshes → tokens updated in file |
| **Token refresh** | Claude auto-refreshes inside container → writes updated tokens to `.credentials.json` → persists |
| **Host re-login** | User logs in on host (new Keychain tokens) → `cco start` detects higher `expiresAt` → re-seeds `.credentials.json` |
| **API key mode** | No Keychain seeding → `ANTHROPIC_API_KEY` passed as env var → `.credentials.json` unused |

### Preferences sync (`claude.json`)

`~/.claude.json` (preferences) is synced from host when host has a higher `numStartups`:

```bash
host_startups=$(jq -r '.numStartups // 0' "$HOME/.claude.json")
global_startups=$(jq -r '.numStartups // 0' "$global_claude_json")
if [[ "$host_startups" -gt "$global_startups" ]]; then
    cp "$HOME/.claude.json" "$global_claude_json"
fi
```

This ensures `hasCompletedOnboarding`, theme preferences, and other settings stay current without re-triggering onboarding inside the container.

---

## 5. Security

| Aspect | Detail |
|--------|--------|
| Token storage | Plaintext file with `chmod 600` (same security model as Claude Code on Linux natively) |
| Keychain access | `security find-generic-password` runs on macOS host only, never inside container |
| Token scope | OAuth access token scoped to Claude API only (not GitHub, not other services) |
| Token rotation | Refresh token allows automatic rotation without user interaction (~90 day lifetime) |
| Container isolation | Container runs as `claude` user (non-root). File is owned by `claude:claude` |
| File location | `global/claude-state/` is gitignored — never committed |

---

## 6. Troubleshooting

### "Not logged in" after `cco start`

1. **Check Keychain**: `security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w | python3 -c "import sys,json; print('OK' if json.load(sys.stdin).get('claudeAiOauth',{}).get('accessToken') else 'NO TOKEN')"`
2. **Check `.credentials.json`**: `jq '.claudeAiOauth | keys' global/claude-state/.credentials.json`
3. **Check permissions**: `ls -la global/claude-state/.credentials.json` (should be `600`)
4. **Re-seed manually**: `rm global/claude-state/.credentials.json && cco start <project>`

### "theme: dark" onboarding screen appears

The `claude.json` has `hasCompletedOnboarding: false`. Fix:
```bash
jq '.hasCompletedOnboarding = true' global/claude-state/claude.json > /tmp/fix.json \
  && mv /tmp/fix.json global/claude-state/claude.json
```
Or delete the file to re-sync from host: `rm global/claude-state/claude.json`

### Token expired (after ~90 days)

1. Login on host: `claude` → authenticate via browser
2. `cco start <project>` → Keychain has newer `expiresAt` → automatic re-seed
