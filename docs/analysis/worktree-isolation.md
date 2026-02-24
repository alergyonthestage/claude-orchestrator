# Analysis: Git Worktree Isolation for Sessions

> Date: 2026-02-24
> Status: Approved — proceed to implementation
> Related: [worktree-design.md](../maintainer/worktree-design.md) | [architecture.md](../maintainer/architecture.md) (ADR-10)

---

## 1. Problem Statement

Repositories are bind-mounted directly from the host into the container. Host and container share the same git working tree, index, branch, and stash. There is zero git isolation.

**Consequences**:
- If the user runs `git checkout` on the host, the agent inside the container sees the change immediately — and vice versa
- Concurrent modifications to the same files (user on host + Claude in container) cause conflicts
- A `git stash` from either side disrupts the other
- The user cannot work on one branch while Claude works on another

**Current mitigation**: An implicit convention — "don't touch the repo while the agent is working." This is fragile and undocumented.

---

## 2. Context: Claude Code Native Worktree Support

Since version 2.1.50, Claude Code supports `--worktree` natively:

```bash
claude --worktree feature-auth
# Creates: <repo>/.claude/worktrees/feature-auth/
# Branch: worktree-feature-auth
# Auto-cleanup on exit
```

Key features:
- **Subagent isolation**: `isolation: worktree` in agent frontmatter
- **Hooks**: `WorktreeCreate` and `WorktreeRemove` for non-git VCS
- **Cleanup**: automatic if no changes; prompt if changes exist

**Why we can't use it directly**:
1. `--worktree` operates on a single repo (the cwd). Our `/workspace` is not a git repo — it's a directory containing multiple repos as subdirectories.
2. It creates worktrees inside the container. We need control from the host CLI (`cco`).
3. It manages one repo at a time. We need consistent worktree isolation across all repos in a project.

---

## 3. Options Analyzed

### Option A — No worktree (status quo)

Mount repos directly. Document the "don't touch while agent works" convention.

| Pro | Contra |
|-----|--------|
| Zero complexity | No git isolation |
| Immediate visibility in IDE | Concurrent work impossible |
| No merge step needed | Risk of accidental conflicts |

### Option B — Worktree created on host by `cco` CLI

`cco start` creates worktrees on the host before mounting, mounts worktrees instead of repos.

| Pro | Contra |
|-----|--------|
| Full isolation before container starts | `.git` file in worktree contains host-absolute paths — **breaks inside container** (gitdir points to host path unreachable from container) |
| User controls lifecycle | Requires mounting both worktree AND original repo for git objects |
| Clean host-side management | Complex volume mapping to fix path references |

**Critical issue**: A git worktree's `.git` file contains `gitdir: /absolute/host/path/.git/worktrees/<name>`. Inside the container, this path doesn't exist because the repo is mounted at a different location. Git operations fail.

### Option C — Worktree created inside container by entrypoint

Repos mounted at a non-workspace path (`/git-repos/`). Entrypoint creates worktrees at `/workspace/` using `git worktree add`.

| Pro | Contra |
|-----|--------|
| All paths consistent inside container | Worktree directory lost when container stops (but branch/commits persist in host repo via bind mount) |
| Claude sees only worktrees | Requires entrypoint changes |
| Standard git operations work | Slightly longer startup |
| Commits safe on host via shared objects | |

### Option D — `git clone --shared` inside container

Entrypoint clones repos with `--shared` flag (reuses objects from bind-mounted repo).

| Pro | Contra |
|-----|--------|
| Full isolation | Not a real worktree — separate reflog, different semantics |
| Simple to implement | Push/pull needed to sync back |
| | Confusing mental model |

---

## 4. Key Technical Challenge: `.git` File Path Resolution

A git worktree is a lightweight checkout that shares the object store with the main repo. The worktree directory contains a `.git` **file** (not directory) with a single line:

```
gitdir: /absolute/path/to/main-repo/.git/worktrees/<name>
```

This path must be valid wherever git commands run. If the worktree is created on the host (Option B), the path references the host filesystem — unreachable from inside the container.

**Solution in Option C**: Create the worktree inside the container, where the main repo is mounted at `/git-repos/<name>`. The `.git` file contains:

```
gitdir: /git-repos/my-repo/.git/worktrees/cco-myproject
```

This path is valid inside the container because `/git-repos/my-repo` is the bind-mounted host repo. Git operations work correctly. Commits are stored in `/git-repos/my-repo/.git/objects/` — which is the host's `.git/objects/` via bind mount — so they persist after the container stops.

---

## 5. Recommendation

**Option C — Worktree created inside container by entrypoint**, combined with Option A documentation improvements.

### Rationale

1. **Path consistency**: All git paths are valid inside the container. No rewriting needed.
2. **Commit safety**: Commits are in the host repo's object store (via bind mount). Container stop = worktree directory lost, but branch and commits survive.
3. **Transparency to Claude**: `/workspace/<repo>` is a worktree, but Claude sees a normal repo. No behavior change needed.
4. **Multi-repo support**: Works for all repos in a project. Each gets its own worktree on the same branch prefix.
5. **Opt-in**: Default behavior (no `--worktree`) is unchanged. Zero risk for existing users.
6. **Resumable**: The branch `cco/<project>` persists in the host repo. Next `cco start --worktree` recreates the worktree from the existing branch.

### Trade-offs accepted

- Worktree directory is ephemeral (lost on container stop). Acceptable because commits persist.
- Startup is slightly slower (one `git worktree add` per repo). Negligible for typical project sizes.
- Requires mounting repos at `/git-repos/` instead of `/workspace/` when worktree mode is active. Changes docker-compose generation but is backward-compatible.

---

## 6. Additional Finding: `cco stop` Unusable in Practice

During analysis, we identified that `cco stop` is effectively dead code for interactive sessions. The user is redirected to Claude Code's prompt input after `cco start` — there is no way to run CLI commands before exiting Claude with Ctrl+C.

**Key insight**: `docker compose run` blocks in `cmd_start()` until the container exits. After the container stops, execution continues in `cmd_start()`. This is the natural place for post-session cleanup (worktree prune, branch status check, user prompts).

This eliminates the need for `cco stop` for worktree lifecycle management. Cleanup runs automatically when the session ends.

---

## 7. Additional Finding: Merge/PR During Session

The user needs to create PRs and merge changes multiple times within a single session, verify results, and continue working. This is standard git workflow:

1. Claude commits on worktree branch (`cco/<project>`)
2. Claude runs `gh pr create` → PR created
3. User reviews and merges on GitHub
4. Claude runs `git fetch && git rebase origin/main`
5. Claude continues working, creates more PRs as needed

No special tooling needed. Git and `gh` CLI work identically in a worktree. The worktree is cleaned up only when the session ends.
