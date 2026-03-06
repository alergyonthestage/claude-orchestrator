# Analysis: Authentication & Secrets Management

> Date: 2026-02-24
> Status: Approved — proceed to implementation
> Related: [auth-design.md](./design.md) | [architecture.md](../architecture.md) (ADR-11) | [worktree-isolation.md](../future/worktree/analysis.md)

---

## 1. Problem Statement

Container sessions need to interact with external services — primarily GitHub (for `git push`, `gh pr create`, MCP GitHub) but also other APIs (Linear, Slack, Notion, etc.). The current setup mounts SSH keys and `.gitconfig` from the host, but:

- **SSH push fails**: keys are mounted `:ro` with host UID; the `claude` user (different UID) gets `Permission denied` from SSH strict permission checks
- **`gh` CLI not installed**: not in the Dockerfile, so `gh pr create` is unavailable
- **MCP GitHub**: works only if `GITHUB_TOKEN` is manually set in `secrets.env`, but there's no documented setup flow
- **No per-project secrets**: all projects share `global/secrets.env` — different token scopes per project are not possible

This is a blocker for the worktree workflow (see [worktree analysis](../future/worktree/analysis.md)), which relies on Claude creating PRs and pushing during sessions.

---

## 2. Current State

### What's in place

| Component | Location | Status |
|-----------|----------|--------|
| `.gitconfig` mount | `~/.gitconfig:/home/claude/.gitconfig:ro` | Works — commit identity is the user's |
| `.ssh` mount | `~/.ssh:/home/claude/.ssh:ro` | Broken — permission denied (UID mismatch + `:ro`) |
| `global/secrets.env` | Loaded by `cco start` as `-e` flags | Works — but global only, no per-project |
| `gh` CLI | Not in Dockerfile | Missing |
| OAuth token | Extracted from macOS Keychain for Claude Code auth | Works for Claude Code login, not for GitHub |

### Authentication paths analyzed

| Method | Git push | gh CLI | MCP GitHub | Security |
|--------|----------|--------|------------|----------|
| SSH keys (current, broken) | Would work if fixed | No | No | Over-permissive: grants access to ALL repos |
| `GITHUB_TOKEN` (fine-grained PAT) | Via credential helper | Via `gh auth login` | Reads env var directly | Best: scoped to specific repos + permissions |
| `GITHUB_TOKEN` (classic PAT) | Same | Same | Same | Broad scope, no repo-level granularity |
| GitHub App installation token | Via credential helper | Limited | Reads env var | Overkill for single-developer tool |
| OAuth device flow (`gh auth login`) | Via gh | Via gh | Needs token export | Interactive — doesn't work in non-interactive containers |

---

## 3. Options for Git Authentication

### Option A — Fix SSH key permissions

Copy SSH keys in entrypoint, fix ownership and permissions.

| Pro | Contra |
|-----|--------|
| Familiar to users who use SSH | Grants access to ALL repos the user has access to |
| No token management | SSH keys may have passphrases (unusable without ssh-agent in container) |
| | Copying private keys into container increases attack surface |
| | Doesn't help with `gh` or MCP |

### Option B — Fine-grained PAT via `GITHUB_TOKEN`

Install `gh` in Dockerfile. Authenticate via token in `secrets.env`. Configure git credential helper via `gh auth setup-git`.

| Pro | Contra |
|-----|--------|
| Single token handles git push, gh CLI, AND MCP GitHub | User must create a PAT on GitHub |
| Fine-grained: scope to specific repos + permissions | Token rotation is manual |
| No private key in container | |
| Works for HTTPS remotes (most common for PAT) | SSH remotes need URL rewriting or the user switches to HTTPS |

### Option C — Hybrid (B + limited A)

Use PAT as primary. Mount SSH `known_hosts` only (not private keys). Optionally allow SSH key mount for non-GitHub remotes.

| Pro | Contra |
|-----|--------|
| Covers GitHub + non-GitHub remotes | Two auth mechanisms to maintain |
| Secure by default | |

---

## 4. Recommendation

**Option B — Fine-grained PAT as the sole GitHub auth mechanism.**

SSH key mounting should be removed from the default compose template. For users with non-GitHub remotes that require SSH, provide opt-in via `project.yml`:

```yaml
docker:
  mount_ssh_keys: true    # default: false
```

### Rationale

1. **Principle of least privilege**: Fine-grained PAT scoped to specific repos is far more secure than SSH keys that grant access to everything
2. **Single mechanism**: One token handles `git push`, `gh pr create`, MCP GitHub, and any tool that reads `GITHUB_TOKEN`
3. **No private keys in container**: Reduces attack surface to a revocable, scoped token
4. **Industry standard**: GitHub recommends fine-grained PATs over SSH for automation

---

## 5. Secrets Management

### Current: global only

```
global/
└── secrets.env          ← KEY=VALUE, loaded as -e flags
```

### Proposed: global + per-project with override

```
global/
└── secrets.env          ← shared across all projects

projects/<name>/
└── secrets.env          ← project-specific, overrides global
```

**Override semantics**: Both files are loaded as Docker `-e` flags. Per-project flags are appended after global flags. For duplicate keys, Docker uses the last value — so project overrides global naturally.

**Use case**: Different `GITHUB_TOKEN` per project, scoped to only the repos that project uses.

| Project | Token scope |
|---------|-------------|
| `my-saas` | `org/backend-api`, `org/frontend` — Contents + PR |
| `devops-toolkit` | `org/infra` — Contents + PR + Actions |
| `personal-blog` | `user/blog` — Contents only |

### Template update

The `defaults/_template/secrets.env` should be created (empty, with comments):

```bash
# Project-specific secrets — overrides values from global/secrets.env
# Format: KEY=VALUE (one per line, no spaces around =)
# This file is gitignored.
#
# GITHUB_TOKEN=github_pat_...
```

---

## 6. Commit Identity

Currently, `.gitconfig` is mounted `:ro` from the host. Commits are made under the user's name and email. Claude Code adds `Co-Authored-By: Claude <noreply@anthropic.com>` to commit messages.

This is correct behavior — the user is responsible for the agent's work. No change needed.

The `.gitconfig` mount remains in the compose template (read-only, identity only).
