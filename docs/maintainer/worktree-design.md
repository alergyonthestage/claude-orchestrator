# Design: Git Worktree Isolation

> Version: 0.1.0
> Status: Design — pending implementation
> Related: [analysis](../analysis/worktree-isolation.md) | [architecture.md](./architecture.md) (ADR-10) | [cli.md](../reference/cli.md)

---

## 1. Overview

Optional git worktree isolation for container sessions. When enabled, each repo is mounted at a hidden path and a worktree is created at `/workspace/<repo>` by the entrypoint. Claude works in the worktree transparently — for Claude it is a normal repo.

**Activation**: `cco start <project> --worktree` (CLI flag) or `worktree: true` in `project.yml`.

---

## 2. Architecture

### 2.1 Container Layout — Without Worktree (default, unchanged)

```
/workspace/              ← WORKDIR
├── .claude/             ← project config (mount)
├── my-repo/             ← bind mount: host ~/projects/my-repo
└── other-repo/          ← bind mount: host ~/projects/other-repo
```

### 2.2 Container Layout — With Worktree

```
/git-repos/              ← repos mounted here (not visible to Claude's workspace)
├── my-repo/             ← bind mount: host ~/projects/my-repo
│   └── .git/            ← shared object store
└── other-repo/
    └── .git/

/workspace/              ← WORKDIR (Claude works here)
├── .claude/             ← project config (mount, unchanged)
├── my-repo/             ← git worktree (created by entrypoint)
│   └── .git             ← FILE pointing to /git-repos/my-repo/.git/worktrees/...
└── other-repo/          ← git worktree
    └── .git             ← FILE pointing to /git-repos/other-repo/.git/worktrees/...
```

### 2.3 Path Resolution

The worktree's `.git` file contains:
```
gitdir: /git-repos/my-repo/.git/worktrees/cco-myproject
```

This path is valid inside the container because `/git-repos/my-repo` is a bind mount of the host repo. All git operations (commit, push, log, diff) work correctly. Commits are stored in `/git-repos/my-repo/.git/objects/` = the host repo's object store.

---

## 3. Component Changes

### 3.1 `project.yml` — New Field

```yaml
# ── Git Worktree Isolation (optional) ──────────────────────────────
worktree: true            # default: false
worktree_branch: auto     # "auto" = cco/<project-name>; or explicit branch name
```

| Field | Required | Type | Default | Description |
|-------|----------|------|---------|-------------|
| `worktree` | No | bool | `false` | Enable worktree isolation |
| `worktree_branch` | No | string | `auto` | Branch name. `auto` = `cco/<project-name>` |

### 3.2 `bin/cco` — CLI Changes

#### New flag: `--worktree`

```
Usage: cco start <project> [--worktree] [OPTIONS]

Options:
  --worktree           Enable git worktree isolation for this session
```

The flag overrides `worktree: false` in `project.yml`. If `project.yml` has `worktree: true`, the flag is not needed.

#### Docker-compose generation changes

When worktree mode is active, repo volumes change target path:

```yaml
# Without worktree (current):
volumes:
  - ~/projects/my-repo:/workspace/my-repo

# With worktree:
volumes:
  - ~/projects/my-repo:/git-repos/my-repo
```

New environment variable added:
```yaml
environment:
  - WORKTREE_ENABLED=true
  - WORKTREE_BRANCH=cco/myproject    # or custom branch from config
```

#### Post-session cleanup

After `docker compose run` returns (container exited), `cmd_start()` continues with:

```bash
# Post-session cleanup (worktree mode only)
if [[ "$worktree_enabled" == true ]]; then
    info "Cleaning up worktrees..."
    while IFS=: read -r repo_path repo_name; do
        [[ -z "$repo_path" ]] && continue
        repo_path=$(expand_path "$repo_path")

        # Prune stale worktree references (worktree dir was in container, now gone)
        git -C "$repo_path" worktree prune 2>/dev/null

        # Check if branch has unmerged commits
        local branch="$worktree_branch"
        if git -C "$repo_path" rev-parse --verify "$branch" &>/dev/null; then
            local ahead
            ahead=$(git -C "$repo_path" rev-list --count "origin/main..$branch" 2>/dev/null || echo "?")
            if [[ "$ahead" == "0" ]]; then
                git -C "$repo_path" branch -d "$branch" 2>/dev/null
                info "  ${repo_name}: branch '$branch' merged — deleted"
            else
                warn "  ${repo_name}: branch '$branch' has $ahead unmerged commit(s) — kept"
            fi
        fi
    done <<< "$(yml_get_repos "$project_yml")"
fi
```

### 3.3 `config/entrypoint.sh` — Worktree Creation

New section after Docker socket handling, before Claude launch:

```bash
# ── Git worktree setup ────────────────────────────────────────────
if [ "${WORKTREE_ENABLED:-}" = "true" ]; then
    BRANCH="${WORKTREE_BRANCH:-cco/${PROJECT_NAME}}"
    echo "[entrypoint] Worktree mode: creating worktrees on branch '$BRANCH'" >&2

    for repo_dir in /git-repos/*/; do
        [ -d "${repo_dir}.git" ] || continue
        repo_name=$(basename "$repo_dir")
        wt_target="/workspace/${repo_name}"

        # If branch exists, use it (resume); otherwise create new
        if git -C "$repo_dir" rev-parse --verify "$BRANCH" &>/dev/null; then
            git -C "$repo_dir" worktree add "$wt_target" "$BRANCH" 2>&1 >&2
            echo "[entrypoint] Worktree: $repo_name → $wt_target (existing branch $BRANCH)" >&2
        else
            git -C "$repo_dir" worktree add -b "$BRANCH" "$wt_target" 2>&1 >&2
            echo "[entrypoint] Worktree: $repo_name → $wt_target (new branch $BRANCH)" >&2
        fi
    done
fi
```

### 3.4 `config/hooks/session-context.sh` — Updated Repo Discovery

No changes needed. The existing hook discovers repos by checking for `.git` under `/workspace/*/`:

```bash
for dir in /workspace/*/; do
    [ -d "${dir}.git" ] && ...    # .git directory (normal repo)
done
```

With worktrees, `/workspace/<repo>/.git` is a **file**, not a directory. The `[ -d ... ]` check fails.

**Fix**: Change to check for `.git` existence (file or directory):

```bash
for dir in /workspace/*/; do
    [ -e "${dir}.git" ] && ...    # .git file (worktree) or directory (normal repo)
done
```

This is backward-compatible — works for both normal repos and worktrees.

---

## 4. Session Lifecycle

### 4.1 Startup Flow

```
cco start myproject --worktree
│
├── 1. Read project.yml
├── 2. Determine worktree_enabled (flag || project.yml)
├── 3. Generate docker-compose.yml
│      Repos: ~/my-repo → /git-repos/my-repo (not /workspace/)
│      Env: WORKTREE_ENABLED=true, WORKTREE_BRANCH=cco/myproject
│
├── 4. docker compose run ... claude  ← blocks
│      │
│      ├── entrypoint.sh
│      │   ├── Docker socket GID fix
│      │   ├── MCP merge
│      │   ├── git worktree add /workspace/<repo> -b cco/myproject (per repo)
│      │   └── claude --dangerously-skip-permissions
│      │
│      ├── Claude works in /workspace/ (worktrees)
│      │   ├── Commits on branch cco/myproject
│      │   ├── gh pr create (repeatable, multiple PRs per session)
│      │   ├── git rebase origin/main (after PR merged)
│      │   └── ...
│      │
│      └── User exits (Ctrl+C / /exit)
│          Container stops
│
├── 5. Post-session cleanup (still in cmd_start)
│      ├── git worktree prune (per repo on host)
│      ├── Check branch status (merged? ahead?)
│      └── Print summary to user
│
└── Done. User is back in host shell.
```

### 4.2 Resume Flow

If the user runs `cco start myproject --worktree` again and branch `cco/myproject` exists:

1. Entrypoint detects existing branch: `git rev-parse --verify cco/myproject`
2. Uses `git worktree add /workspace/<repo> cco/myproject` (no `-b`, uses existing branch)
3. Claude resumes from the last commit on that branch
4. `/resume` in Claude Code also works (session transcripts persisted via `claude-state/` mount)

### 4.3 Merge/PR During Session

```
Session active on branch cco/myproject
│
├── Claude: work, commit A, commit B
├── Claude: gh pr create → PR #1 (cco/myproject → main)
├── User: reviews on GitHub, merges PR #1
├── Claude: git fetch origin && git rebase origin/main
│
├── Claude: work, commit C, commit D
├── Claude: gh pr create → PR #2
├── User: merges PR #2
├── Claude: git rebase origin/main
│
├── Claude: work, commit E (not yet PR'd)
└── User: Ctrl+C — exits
    │
    Post-session:
    ├── git worktree prune
    ├── Branch cco/myproject has 1 unmerged commit → kept
    └── User can: cco start myproject --worktree (resume)
                  or: git merge cco/myproject (on host)
                  or: gh pr create (on host)
```

---

## 5. Configuration Examples

### 5.1 CLI Flag (per-session)

```bash
# One-time worktree session
cco start my-saas --worktree
```

### 5.2 Project Config (persistent)

```yaml
# projects/my-saas/project.yml
name: my-saas
worktree: true

repos:
  - path: ~/projects/backend-api
    name: backend-api
  - path: ~/projects/frontend-app
    name: frontend-app
```

### 5.3 Custom Branch Name

```yaml
# projects/my-saas/project.yml
worktree: true
worktree_branch: feature/auth-refactor
```

---

## 6. Edge Cases

### 6.1 Branch Already Exists, Worktree Doesn't

Normal resume case. `git worktree add` with existing branch succeeds.

### 6.2 Branch Already Exists AND Has Active Worktree

Can happen if a previous container crashed without cleanup. The `.git/worktrees/<name>/` directory has a stale lock.

**Solution**: Run `git worktree prune` before `git worktree add` in the entrypoint.

```bash
git -C "$repo_dir" worktree prune 2>/dev/null
```

### 6.3 Repo Has Uncommitted Changes

The worktree is created from the branch tip. Uncommitted changes in the main repo working tree are not affected (they live in the main checkout, not the worktree).

However, if Claude pushes the worktree branch and creates a PR, the PR won't include the user's uncommitted changes. This is expected behavior — worktree isolation means independent working trees.

### 6.4 Multiple Projects Using Same Repo

Two projects can't have active worktrees on the same branch simultaneously (git limitation: one worktree per branch). Branch naming `cco/<project-name>` prevents collisions between projects.

However, two projects cannot run `--worktree` simultaneously on the same repo with the same branch. The second `git worktree add` would fail.

**Solution**: Detect and fail with a clear message:
```
Error: Repository 'backend-api' already has an active worktree for branch
'cco/project-a'. Stop that session first, or use worktree_branch to specify
a different branch.
```

### 6.5 Non-Git Directories in repos

If a repo path doesn't contain `.git`, the entrypoint skips worktree creation for that entry. It remains at `/git-repos/<name>` — not visible in `/workspace/`.

**Solution**: For non-git repos, fall back to direct mount at `/workspace/<name>`. The docker-compose generation should handle this:
- Git repos: mount at `/git-repos/<name>`
- Non-git dirs: mount at `/workspace/<name>` (same as without worktree mode)

### 6.6 Subagent Worktrees Inside Container Worktree

Claude Code's native `isolation: worktree` for subagents works inside a worktree. A worktree is a valid git checkout that supports `git worktree add`. Subagent worktrees are created as nested worktrees under `/workspace/<repo>/.claude/worktrees/`.

No special handling needed.

---

## 7. Documentation Changes Required

When implementing, update the following docs:

| Document | Change |
|----------|--------|
| [cli.md](../reference/cli.md) | Add `--worktree` flag to `cco start`, add `worktree` and `worktree_branch` to project.yml field reference |
| [architecture.md](./architecture.md) | ADR-10 added (done) |
| [roadmap.md](./roadmap.md) | Move worktree to near-term with link to this doc (done) |
| [project-setup.md](../guides/project-setup.md) | Add section on worktree usage and bind mount behavior |
| [docker.md](./docker.md) | Update compose template to show worktree volume variant |

---

## 8. Implementation Checklist

- [ ] `bin/cco`: Parse `--worktree` flag in `cmd_start()`
- [ ] `bin/cco`: Parse `worktree` and `worktree_branch` from `project.yml`
- [ ] `bin/cco`: Conditional volume generation (`/git-repos/` vs `/workspace/`)
- [ ] `bin/cco`: Add `WORKTREE_ENABLED` and `WORKTREE_BRANCH` env vars to compose
- [ ] `bin/cco`: Post-session cleanup after `docker compose run` returns
- [ ] `config/entrypoint.sh`: Worktree creation section
- [ ] `config/hooks/session-context.sh`: Change `[ -d "${dir}.git" ]` to `[ -e "${dir}.git" ]`
- [ ] `defaults/_template/project.yml`: Add commented `worktree:` field
- [ ] `bin/test`: Tests for `--worktree` docker-compose generation (dry-run)
- [ ] `bin/test`: Tests for post-session cleanup logic
- [ ] Documentation updates (see §7)
