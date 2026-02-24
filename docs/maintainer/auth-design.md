# Design: Authentication & Secrets

> Version: 0.1.0
> Status: Design — pending implementation
> Related: [analysis](../analysis/authentication-and-secrets.md) | [architecture.md](./architecture.md) (ADR-11) | [worktree-design.md](./worktree-design.md)

---

## 1. Overview

Unified authentication for container sessions using `GITHUB_TOKEN` (fine-grained PAT) as the primary mechanism. Handles `git push`, `gh` CLI, MCP GitHub, and other MCP servers. Per-project `secrets.env` for token scoping.

---

## 2. Architecture

### 2.1 Token Flow

```
global/secrets.env                    projects/<name>/secrets.env
├── GITHUB_TOKEN=github_pat_aaa      ├── GITHUB_TOKEN=github_pat_bbb  (override)
├── LINEAR_API_KEY=lin_xxx            └── STRIPE_KEY=sk_test_xxx       (project-only)
└── SLACK_BOT_TOKEN=xoxb_xxx
        │                                      │
        └──────────────┬───────────────────────┘
                       │
                cco start <project>
                load_global_secrets()
                load_project_secrets()     ← NEW
                       │
                docker compose run -e GITHUB_TOKEN=... -e LINEAR_API_KEY=... claude
                       │
                entrypoint.sh
                ├── gh auth login --with-token  (if GITHUB_TOKEN set)
                ├── gh auth setup-git           (configures git credential helper)
                ├── ssh-keyscan github.com      (known_hosts, no private keys)
                └── claude --dangerously-skip-permissions
                    │
                    ├── git push          → uses gh credential helper (HTTPS)
                    ├── gh pr create      → uses gh auth token
                    └── MCP GitHub        → reads GITHUB_TOKEN from env
```

### 2.2 What Changes vs Current

| Component | Current | New |
|-----------|---------|-----|
| SSH keys | Mounted `:ro` (broken) | **Removed from default**. Opt-in via `docker.mount_ssh_keys: true` |
| `.gitconfig` | Mounted `:ro` | Unchanged (commit identity) |
| `gh` CLI | Not installed | **Installed in Dockerfile** |
| `gh` auth | N/A | **Entrypoint: `gh auth login --with-token`** |
| Git credential helper | None | **Entrypoint: `gh auth setup-git`** |
| `known_hosts` | Via mounted `~/.ssh` | **Entrypoint: `ssh-keyscan github.com`** |
| `secrets.env` | Global only | **Global + per-project with override** |

---

## 3. Component Changes

### 3.1 Dockerfile — Install `gh` CLI

Add after the Docker CLI installation block:

```dockerfile
# ── GitHub CLI ─────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) \
       signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
       https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*
```

### 3.2 `config/entrypoint.sh` — Auth Setup

New section after MCP merge, before debug log:

```bash
# ── GitHub / Git authentication ───────────────────────────────────
# Authenticate gh CLI and configure git credential helper if GITHUB_TOKEN is set.
# This enables: git push (HTTPS), gh pr create, and MCP GitHub server.
if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "$GITHUB_TOKEN" | gosu claude gh auth login --with-token 2>&1 >&2 \
        && echo "[entrypoint] GitHub: authenticated gh CLI via GITHUB_TOKEN" >&2
    gosu claude gh auth setup-git 2>&1 >&2 \
        && echo "[entrypoint] GitHub: configured git credential helper" >&2
fi

# ── SSH known_hosts (no private keys) ─────────────────────────────
# Populate known_hosts so git doesn't prompt for host verification.
# Private SSH keys are NOT mounted by default (use docker.mount_ssh_keys for SSH remotes).
mkdir -p /home/claude/.ssh
ssh-keyscan -t ed25519,rsa github.com gitlab.com bitbucket.org \
    >> /home/claude/.ssh/known_hosts 2>/dev/null
chown -R claude:claude /home/claude/.ssh
chmod 700 /home/claude/.ssh
```

### 3.3 `config/entrypoint.sh` — Optional SSH Key Fix

Only when `MOUNT_SSH_KEYS=true` (set by compose when `docker.mount_ssh_keys: true`):

```bash
# ── SSH key permission fix (opt-in) ──────────────────────────────
# When SSH keys are mounted (for non-GitHub remotes), fix permissions.
if [ "${MOUNT_SSH_KEYS:-}" = "true" ] && [ -d /home/claude/.ssh-mounted ]; then
    cp -r /home/claude/.ssh-mounted/* /home/claude/.ssh/
    find /home/claude/.ssh -type f -name "id_*" ! -name "*.pub" \
        -exec chmod 600 {} \;
    chown -R claude:claude /home/claude/.ssh
    echo "[entrypoint] SSH: keys copied from mount, permissions fixed" >&2
fi
```

### 3.4 `bin/cco` — Per-Project Secrets

New function and integration in `cmd_start()`:

```bash
# Load secrets from a file into an array of -e flags
# Usage: load_secrets_file array_name file_path
load_secrets_file() {
    local -n _arr="$1"
    local file="$2"
    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))
        # Skip empty lines and comments
        [[ -z "$line" || "$line" == \#* ]] && continue
        # Validate KEY=VALUE format
        if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            _arr+=(-e "$line")
        else
            warn "$(basename "$file"):${line_num}: skipping malformed line (expected KEY=VALUE)"
        fi
    done < "$file"
}

# In cmd_start(), after load_global_secrets:
load_global_secrets run_env

# Load project secrets (override global values)
local project_secrets="$PROJECT_DIR/secrets.env"
if [[ -f "$project_secrets" ]]; then
    load_secrets_file run_env "$project_secrets"
fi
```

### 3.5 `bin/cco` — Compose Volume Changes

Remove SSH key mount from default, add opt-in:

```bash
# Current (remove from default):
# echo "      - \${HOME}/.ssh:/home/claude/.ssh:ro"

# New: only if mount_ssh_keys is true
local mount_ssh
mount_ssh=$(yml_get "$project_yml" "docker.mount_ssh_keys")
if [[ "$mount_ssh" == "true" ]]; then
    echo "      - \${HOME}/.ssh:/home/claude/.ssh-mounted:ro"
    echo "      - MOUNT_SSH_KEYS=true"   # in environment section
fi
```

### 3.6 `project.yml` — New Fields

```yaml
# ── Docker options ───────────────────────────────────────────────────
docker:
  mount_ssh_keys: false    # default: false. Set true for non-GitHub SSH remotes.
```

### 3.7 `defaults/_template/` — New Files

**`defaults/_template/secrets.env`**:
```bash
# Project-specific secrets — overrides values from global/secrets.env
# Format: KEY=VALUE (one per line, no spaces around =)
# This file is gitignored.
#
# GITHUB_TOKEN=github_pat_...
# LINEAR_API_KEY=lin_api_...
```

---

## 4. User Setup Flow

### First-time setup

```bash
# 1. Create a fine-grained PAT on GitHub:
#    GitHub → Settings → Developer Settings → Fine-grained personal access tokens
#    - Repository access: select specific repos
#    - Permissions: Contents (read/write), Pull requests (read/write)

# 2. Save token:
echo "GITHUB_TOKEN=github_pat_..." >> ~/claude-orchestrator/global/secrets.env

# 3. Rebuild image (to get gh CLI, if not already built with it):
cco build

# 4. Start session — auth is automatic:
cco start my-project
# [entrypoint] GitHub: authenticated gh CLI via GITHUB_TOKEN
# [entrypoint] GitHub: configured git credential helper
```

### Per-project token

```bash
# Create a different PAT scoped to this project's repos
echo "GITHUB_TOKEN=github_pat_project_specific..." > \
    ~/claude-orchestrator/projects/my-project/secrets.env
```

---

## 5. Security Considerations

| Risk | Mitigation |
|------|------------|
| Token in `secrets.env` on disk | File is gitignored. User's responsibility to protect (like any credentials file) |
| Token in container env | Container is ephemeral (`--rm`). Token not persisted to disk inside container |
| Token scope too broad | Fine-grained PAT allows per-repo, per-permission scoping |
| Token in docker-compose.yml | Tokens are passed as runtime `-e` flags, NOT written to compose file |
| SSH keys exposure | Not mounted by default. Opt-in only for non-GitHub use cases |
| Token in shell history | `load_global_secrets` reads from file, not command-line args |

---

## 6. Implementation Checklist

- [ ] `Dockerfile`: Install `gh` CLI
- [ ] `config/entrypoint.sh`: Add GitHub auth section (`gh auth login`, `gh auth setup-git`)
- [ ] `config/entrypoint.sh`: Add `ssh-keyscan` for `known_hosts`
- [ ] `config/entrypoint.sh`: Add optional SSH key fix section
- [ ] `bin/cco`: Extract `load_secrets_file` helper function
- [ ] `bin/cco`: Add per-project `secrets.env` loading in `cmd_start()` and `cmd_new()`
- [ ] `bin/cco`: Remove default SSH mount from compose generation
- [ ] `bin/cco`: Add `docker.mount_ssh_keys` support in compose generation
- [ ] `defaults/_template/secrets.env`: Create template file
- [ ] `defaults/_template/project.yml`: Add `docker.mount_ssh_keys` (commented)
- [ ] `bin/test`: Tests for per-project secrets loading
- [ ] `bin/test`: Tests for SSH mount opt-in in dry-run compose
- [ ] Documentation: Update [cli.md](../reference/cli.md), [project-setup.md](../guides/project-setup.md)
