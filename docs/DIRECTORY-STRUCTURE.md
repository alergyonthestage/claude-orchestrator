# Directory Structure & File Inventory

> Version: 1.0.0
> Status: Draft — Pending Review
> Serves as implementation checklist — every file listed here must be created.

---

## Complete File Tree

```
claude-orchestrator/
│
├── docs/                                   # ── Documentation ──────────────
│   ├── SPEC.md                             # Requirements specification
│   ├── ARCHITECTURE.md                     # Architecture & design decisions
│   ├── DOCKER.md                           # Docker image, compose, networking
│   ├── CONTEXT.md                          # Context hierarchy & settings
│   ├── CLI.md                              # CLI commands specification
│   ├── SUBAGENTS.md                        # Subagent specs & creation guide
│   ├── DISPLAY-MODES.md                    # tmux vs iTerm2 setup guide
│   └── DIRECTORY-STRUCTURE.md              # This file
│
├── Dockerfile                              # Docker image definition
├── .dockerignore                           # Exclude docs, .git from build context
├── .gitignore                              # Ignore generated files, secrets
├── README.md                               # Quick start guide
│
├── config/                                 # ── Docker Config ──────────────
│   ├── entrypoint.sh                       # Container entrypoint script
│   └── tmux.conf                           # tmux config for agent teams
│
├── bin/                                    # ── CLI ────────────────────────
│   └── cc                                  # Main CLI script (bash)
│
├── global/                                 # ── GLOBAL SCOPE ──────────────
│   └── .claude/                            # Mounted → ~/.claude/ in container
│       ├── settings.json                   # Global settings (user-level)
│       ├── CLAUDE.md                       # Global instructions
│       ├── rules/                          # Modular global rules
│       │   ├── workflow.md                 # Development workflow phases
│       │   └── git-practices.md            # Git conventions
│       ├── agents/                         # Global subagents
│       │   ├── analyst.md                  # Analysis specialist (haiku, read-only)
│       │   └── reviewer.md                 # Code review specialist (sonnet, read-only)
│       └── skills/                         # Global skills (empty in v1)
│           └── .gitkeep
│
└── projects/                               # ── PROJECT SCOPE ─────────────
    └── _template/                          # Template for new projects
        ├── project.yml                     # Project metadata & repo list
        ├── .claude/                        # Mounted → /workspace/.claude/
        │   ├── CLAUDE.md                   # Project instructions (template)
        │   ├── settings.json               # Project settings (empty, for overrides)
        │   ├── rules/                      # Project-specific rules
        │   │   └── .gitkeep
        │   ├── agents/                     # Project-specific subagents
        │   │   └── .gitkeep
        │   └── skills/                     # Project-specific skills
        │       └── .gitkeep
        └── memory/                         # Auto memory (isolated per project)
            └── .gitkeep
```

---

## File Descriptions

### Root Files

| File | Purpose | Notes |
|------|---------|-------|
| `Dockerfile` | Docker image definition | See [DOCKER.md](./DOCKER.md) §1.1 |
| `.dockerignore` | Exclude files from Docker build context | Exclude: `docs/`, `.git/`, `projects/*/memory/` |
| `.gitignore` | Git ignore patterns | Ignore: `projects/*/docker-compose.yml` (generated), `projects/*/memory/` (auto memory data), `.env` |
| `README.md` | User-facing quick start | Install, build, create project, start session |

### config/

| File | Purpose | Notes |
|------|---------|-------|
| `entrypoint.sh` | Container entrypoint | Handles Docker socket perms, tmux launch, claude start. See [DOCKER.md](./DOCKER.md) §1.2 |
| `tmux.conf` | tmux configuration | Optimized for agent teams. See [DOCKER.md](./DOCKER.md) §1.3 |

### bin/

| File | Purpose | Notes |
|------|---------|-------|
| `cc` | CLI script | Single bash file. All commands. See [CLI.md](./CLI.md) |

### global/.claude/

| File | Purpose | Notes |
|------|---------|-------|
| `settings.json` | User-level settings | Agent teams, permissions, bypass mode. See [CONTEXT.md](./CONTEXT.md) §4.1 |
| `CLAUDE.md` | User-level instructions | Workflow, git practices, communication. See [CONTEXT.md](./CONTEXT.md) §4.2 |
| `rules/workflow.md` | Workflow phase rules | Detailed phase behaviors. See [CONTEXT.md](./CONTEXT.md) §4.3 |
| `rules/git-practices.md` | Git conventions | Branch naming, commit format. See [CONTEXT.md](./CONTEXT.md) §4.3 |
| `agents/analyst.md` | Analyst subagent | Haiku, read-only, user memory. See [SUBAGENTS.md](./SUBAGENTS.md) §2.1 |
| `agents/reviewer.md` | Reviewer subagent | Sonnet, read-only, user memory. See [SUBAGENTS.md](./SUBAGENTS.md) §2.2 |
| `skills/.gitkeep` | Placeholder | Empty in v1; skills added as patterns emerge |

### projects/_template/

| File | Purpose | Notes |
|------|---------|-------|
| `project.yml` | Project config template | Repos, ports, auth. See [CLI.md](./CLI.md) §4 |
| `.claude/CLAUDE.md` | Project instructions template | Placeholders for project-specific content |
| `.claude/settings.json` | Project settings template | Empty; overrides go here |
| `.claude/rules/.gitkeep` | Placeholder | Project-specific rules |
| `.claude/agents/.gitkeep` | Placeholder | Project-specific agents |
| `.claude/skills/.gitkeep` | Placeholder | Project-specific skills |
| `memory/.gitkeep` | Auto memory dir | Created empty; Claude populates it |

---

## Generated Files (Not in Git)

These files are generated by the CLI and should NOT be committed:

| File | Generated By | Purpose |
|------|-------------|---------|
| `projects/<n>/docker-compose.yml` | `cc start` | Docker compose for the project |
| `projects/<n>/memory/*.md` | Claude Code | Auto memory files |

---

## Implementation Order

Recommended order for building the repo:

| Phase | Files | Depends On |
|-------|-------|------------|
| 1. Docker | `Dockerfile`, `config/entrypoint.sh`, `config/tmux.conf`, `.dockerignore` | Nothing |
| 2. Global Config | `global/.claude/*` (all files) | Nothing |
| 3. Project Template | `projects/_template/*` (all files) | Nothing |
| 4. CLI | `bin/cc` | Phase 1-3 (needs files to reference) |
| 5. Root Files | `README.md`, `.gitignore` | Phase 1-4 |
| 6. Testing | Manual test: create project, start session, verify | Phase 1-5 |

---

## Validation Checklist

After implementation, verify:

- [ ] `cc build` creates the Docker image successfully
- [ ] `cc project create test-project --repo <any-repo>` creates project structure
- [ ] `cc start test-project` launches interactive Claude Code session
- [ ] Claude sees global CLAUDE.md (check with "What are your global instructions?")
- [ ] Claude sees project CLAUDE.md (check with "What project are you working on?")
- [ ] Claude sees repo .claude/ when reading repo files (if repo has one)
- [ ] Git operations work (commit, branch, push) inside container
- [ ] Docker commands work inside container (`docker ps`)
- [ ] Port mapping works (run `npx serve` on port 3000, access from host)
- [ ] Agent teams create teammates (visible in tmux panes)
- [ ] Auto memory persists across sessions (check `projects/<n>/memory/`)
- [ ] `cc new --repo <path>` works for temporary sessions
- [ ] `cc stop` stops running sessions
- [ ] `cc project list` shows available projects
