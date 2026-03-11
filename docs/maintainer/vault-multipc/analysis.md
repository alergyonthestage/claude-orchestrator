# Analysis: Multi-PC Vault Sync & Memory Policy

> **Status**: Analysis completed 2026-03-11. To be expanded into a design doc at the start of Sprint 7-Vault.
> **Related sprint**: [Sprint 7-Vault](../roadmap.md#sprint-7-vault--multi-pc-config-sync--memory-policy)

---

## 1. Context

This analysis was triggered by two observations made during a session (2026-03-11):

1. `claude-state/` (which contains auto memory and session transcripts) is gitignored from the vault by design, but no policy exists on *when* to use memory vs. project docs. This creates an implicit knowledge leak: important notes written to `MEMORY.md` by Claude are never versionable or portable.

2. `cco vault push/pull` operates on the entire `user-config/` directory as a single git operation, making it impossible to manage different project sets across multiple machines from a shared remote.

---

## 2. Auto Memory & claude-state Architecture

### 2.1 Current layout

```
user-config/projects/<name>/
├── claude-state/                     ← gitignored in vault
│   ├── memory/
│   │   ├── MEMORY.md                 ← auto-loaded first 200 lines every session
│   │   └── <topic>.md                ← topic files, loaded on demand
│   └── <session-transcripts>/        ← enables /resume across container rebuilds
└── .claude/
    └── CLAUDE.md                     ← versionated, synced via vault
```

Mount in docker-compose:
```yaml
- ./claude-state:/home/claude/.claude/projects/-workspace
```

Claude Code stores auto memory at `~/.claude/projects/<project-id>/memory/`. The project-id is derived from the working directory; since `/workspace` is not a git repo, Claude Code uses `-workspace` (leading dash) as the identifier.

### 2.2 Why claude-state is excluded from vault

The vault `.gitignore` explicitly excludes:
```gitignore
# Session state — transient, large, personal
global/claude-state/
projects/*/claude-state/
```

Reasons:
- **Session transcripts** grow large over time (10s–100s MB per project), not useful to version
- **Credentials** (`global/claude-state/.credentials.json`) must never be committed
- The entire directory was treated as a unit — no distinction between transcripts and memory files

### 2.3 The memory vs. docs boundary problem

No policy currently defines when Claude should write to `MEMORY.md` vs. project documentation. In practice:

| Information type | Where it often ends up | Problem |
|---|---|---|
| Learned code patterns | `MEMORY.md` | Local-machine only, lost on second PC |
| Architecture decisions | `MEMORY.md` or `docs/` (ad hoc) | Inconsistent, not versionated if in memory |
| Workflow preferences | `MEMORY.md` | Local-machine only |
| Session-specific notes | `MEMORY.md` | Correct placement |
| Discoveries, gotchas | `MEMORY.md` | Not in repo, not shared |

The risk: Claude accumulates critical knowledge in MEMORY that is never in the repo. On a second machine (or after `cco init --force`), that knowledge disappears.

### 2.4 Session resume — already solved natively

Claude Code's `/resume` command reads session transcripts from `claude-state/` to restore conversation context. This already works because `claude-state/` is mounted as a Docker volume that persists across container rebuilds. The proposed `cco resume` feature (reattach to a *currently running* container's tmux session) solves a different and much rarer problem. See [Section 5](#5-session-resume-assessment).

---

## 3. Proposed Memory Policy

A clear, documented boundary between memory and project docs:

**Use `MEMORY.md` for:**
- Session-specific working notes (scratch pad for the current task)
- Personal preferences for interaction style in this project
- Short-lived context that doesn't belong in any file (e.g., "we're mid-refactor, skip X for now")
- Observations about Claude Code itself (model behavior, tool quirks)

**Use project docs (`.claude/`, `docs/`) for:**
- Architecture decisions and rationale (ADRs)
- Learned patterns that future sessions should know (write to CLAUDE.md or a `docs/` file)
- Conventions and naming rules
- "Always do X when working on Y" rules → write to `.claude/rules/`
- Gotchas and known issues

**Implementation**: Add this policy to the global `CLAUDE.md` (user-owned, user-editable) and to the `/init-workspace` skill guidance. This is a **zero-code change** — documentation only.

### 3.1 Optional: vault memory separately from transcripts

If users want MEMORY.md to be versionated (synced across machines), a possible approach is to move `memory/` out of `claude-state/`:

```
user-config/projects/<name>/
├── claude-state/           ← gitignored (transcripts only)
└── memory/                 ← tracked by vault (MEMORY.md + topic files)
```

This requires a change to the docker-compose volume mount:
```yaml
- ./claude-state:/home/claude/.claude/projects/-workspace
- ./memory:/home/claude/.claude/projects/-workspace/memory  # override memory subdir
```

**Trade-off**: The memory directory is now separate from transcripts (easier to git-track), but adds complexity to the mount configuration. Needs validation that Claude Code resolves the symlink/override correctly.

**Decision**: Defer to Sprint 7-Vault implementation phase — validate the mount approach first.

---

## 4. Multi-PC Vault Sync

### 4.1 Current behavior

`cco vault push` = `git push -u <remote> <branch>`
`cco vault pull` = `git pull <remote>`

Single branch, entire `user-config/` directory. No granularity.

### 4.2 Use cases

**Case A — Same config on both PCs** (e.g., two identical work machines):
- Works with current vault push/pull
- Potential merge conflicts if both PCs modify files concurrently
- Mitigation: `git pull --rebase` strategy
- No feature gap, only needs documentation

**Case B — Different project sets per PC** (the primary gap):
- PC-A: work projects only
- PC-B: personal projects only
- Shared: global config, packs, templates
- Current behavior: push from PC-A → PC-B sees work projects; push from PC-B → PC-A sees personal projects
- Not the desired behavior

**Desired final state:**
```
@mygithub/cco-config              ← personal vault remote (all machines)
  ├── global/                     ← shared across all PCs
  ├── packs/                      ← shared across all PCs
  ├── templates/                  ← shared across all PCs
  └── projects/
      ├── work-proj-1/            ← only PC-A pushes/pulls this
      ├── work-proj-2/            ← only PC-A pushes/pulls this
      └── personal-1/             ← only PC-B pushes/pulls this

@myorg/cco-config                 ← team remote (pack and project sharing)
  ├── packs/team-pack/
  └── projects/shared-template/
```

### 4.3 Options evaluated

**Option 1 — Branch per machine**

```
main           ← global + packs + templates
├── pc-work    ← main + projects/work-*
└── pc-home    ← main + projects/personal-*
```

- Push/pull on machine-specific branch
- Sync global updates via merge from main
- Pros: pure git, no custom tooling needed
- Cons: merge workflow non-obvious for users, conflicts on `global/` if both PCs modify

**Option 2 — Sparse-checkout per machine**

Configure `.git/info/sparse-checkout` per machine to pull only relevant paths.

- Pros: git-native
- Cons: complex to manage, not user-friendly, sparse-checkout state is local (not committed)

**Option 3 — Selective sync (`cco vault push/pull --only <path>`)**

Add path-scoped push/pull:
```bash
cco vault push --only global
cco vault push --only projects/work-proj-1
cco vault pull --only global
cco vault pull --only packs
```

- Pros: granular, user-controlled
- Cons: single branch with mixed content; history is interleaved; divergence risk

**Option 4 — Profile-based vault (recommended)**

Each machine has a local `vault.yml` (gitignored) declaring what it syncs:

```yaml
# user-config/vault.yml  (gitignored — local machine config)
sync:
  global: true
  packs: true
  templates: true
  projects:
    - work-proj-1
    - work-proj-2
```

`cco vault push/pull` reads this file and only stages/checks out the declared paths.

- Pros: explicit, user-controlled, scales to N machines, single branch in remote, easy to understand
- Cons: `vault.yml` is machine-local (not synced — by design), users must maintain it manually

**Option 5 — Branch strategy + profile (combined, recommended)**

Combine Option 1 and Option 4:
- `main` branch holds shared content (global, packs, templates)
- Each machine pushes its projects to its own branch
- `cco vault pull --global` = merge from `main` into current branch
- `vault.yml` defines which projects this machine tracks

```bash
# PC-A setup
cco vault branch pc-work          # create/switch to pc-work branch
cco vault profile set projects work-proj-1 work-proj-2

# Daily workflow
cco vault sync "update work project"
cco vault push                    # pushes pc-work branch
cco vault pull --global           # merges main (global/packs/templates) into pc-work
```

### 4.4 Recommended approach

**Phase 1 (Sprint 7-Vault)**: Profile-based vault (Option 4) without branch strategy.
- Add `vault.yml` as machine-local config (gitignored)
- `cco vault profile init` — interactive setup
- `cco vault push/pull` reads profile to scope git operations
- `cco vault profile add-project <name>` / `remove-project`

**Phase 2 (future)**: Branch strategy on top of profiles.
- `cco vault branch <name>` to isolate per-machine history
- `cco vault pull --global` to sync shared content from main

Phase 1 solves the immediate problem (unwanted projects on wrong PC) without introducing git branch complexity for users.

### 4.5 Team remote (@myorg/cco-config)

This case is already handled by the existing sharing system:
- `cco pack install @myorg/cco-config` — install team packs
- `cco project install @myorg/cco-config` — install shared project templates
- `cco pack publish team-pack @myorg` — publish to team remote

The team remote does **not** use `vault push/pull` — it uses the publish/install model. No changes needed here.

---

## 5. Session Resume Assessment

### 5.1 Current state

`/resume` (native Claude Code command) already works in claude-orchestrator:
- Session transcripts are stored in `claude-state/` (mounted Docker volume)
- Transcripts persist across container rebuilds because of the bind mount
- On next `cco start`, Claude Code reads transcripts and `/resume` works normally

### 5.2 What `cco resume` would add

The proposed Sprint 8 feature `cco resume <project>` was scoped as: "reattach to a *currently running* container's tmux session." This addresses the case where:
1. A session is running in a container
2. The terminal window closes or detaches
3. The user wants to reattach without stopping/restarting

### 5.3 Assessment

- The use case (detached terminal, want to reattach) is real but rare in practice
- It is equivalent to: `docker exec -it <container> tmux attach`
- This could be a simple 3-line CLI command rather than a full sprint item
- The complementarity with worktree isolation is valid but premature — worktrees are Sprint 10
- **Recommendation**: move to Long-term/Exploratory; add a `cco attach <project>` one-liner as a convenience command if there is demand

---

## 6. Open Questions for Sprint 7-Vault Design

1. Should `vault.yml` be the configuration file, or should vault profiles be stored in `.cco-meta`?
2. How does `cco vault sync` handle untracked projects on the current machine? Warning? Auto-add?
3. Should `cco vault pull --global` be a separate subcommand or a flag on `pull`?
4. If memory files are separated from `claude-state/`, does the bind-mount override work correctly with Claude Code's internal path resolution?
5. Should `vault.yml` be created by `cco vault init` interactively, or by a separate `cco vault profile` subcommand?
6. For the branch strategy (Phase 2): should branch names be auto-derived from hostname, or user-specified?
