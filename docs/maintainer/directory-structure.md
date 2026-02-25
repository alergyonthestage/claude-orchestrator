# Directory Structure & File Inventory

> Version: 1.0.0
> Status: v1.0 — Current

---

## Complete File Tree

```
claude-orchestrator/
│
├── docs/                                   # ── Documentation ──────────────
│   ├── README.md                           # Documentation index
│   ├── guides/
│   │   ├── project-setup.md               # Project setup guide
│   │   ├── subagents.md                   # Custom subagents guide
│   │   └── display-modes.md              # tmux vs iTerm2 setup
│   ├── reference/
│   │   ├── cli.md                         # CLI commands & project.yml format
│   │   └── context.md                     # Context hierarchy & settings
│   └── maintainer/
│       ├── spec.md                        # Requirements specification
│       ├── architecture.md               # Architecture & design decisions
│       ├── docker.md                      # Docker image, compose, networking
│       ├── roadmap.md                     # Planned features
│       └── directory-structure.md        # This file
│
├── Dockerfile                              # Docker image definition
├── .dockerignore                           # Exclude docs, .git from build context
├── .gitignore                              # Ignore user config, secrets
├── README.md                               # Project overview
├── QUICK-START.md                          # Setup and usage guide
├── CLAUDE.md                               # Claude Code guidance for this repo
│
├── config/                                 # ── Docker Config ──────────────
│   ├── entrypoint.sh                       # Container entrypoint script
│   ├── tmux.conf                           # tmux config for agent teams
│   └── hooks/
│       ├── session-context.sh             # SessionStart hook: injects repo/MCP context
│       ├── subagent-context.sh            # SubagentStart hook: condensed context for subagents
│       ├── precompact.sh                  # PreCompact hook: guides context compaction
│       └── statusline.sh                  # StatusLine hook: shows model/context/cost
│
├── bin/                                    # ── CLI ────────────────────────
│   └── cco                                 # Main CLI script (bash)
│
├── defaults/                               # ── TOOL DEFAULTS (tracked) ────
│   ├── system/                             # System-managed files (always synced)
│   │   ├── system.manifest                 # Lists all system-managed paths
│   │   └── .claude/
│   │       ├── settings.json               # Global settings (permissions, hooks, teams)
│   │       ├── rules/
│   │       │   ├── workflow.md             # Development workflow phases
│   │       │   ├── git-practices.md        # Git conventions
│   │       │   └── diagrams.md             # Mermaid diagram conventions
│   │       ├── agents/
│   │       │   ├── analyst.md              # Analysis specialist (haiku, read-only)
│   │       │   └── reviewer.md             # Code review specialist (sonnet, read-only)
│   │       └── skills/
│   │           ├── analyze/SKILL.md        # /analyze skill
│   │           ├── commit/SKILL.md         # /commit skill
│   │           ├── design/SKILL.md         # /design skill
│   │           ├── init-workspace/SKILL.md # /init-workspace skill
│   │           └── review/SKILL.md         # /review skill
│   ├── global/                             # User defaults (copied once by cco init)
│   │   └── .claude/
│   │       ├── CLAUDE.md                   # Global workflow instructions
│   │       ├── mcp.json                    # Empty MCP server list (user populates)
│   │       ├── rules/
│   │       │   └── language.md             # Language preferences (with {{LANG}} vars)
│   │       ├── agents/.gitkeep             # Placeholder for user agents
│   │       └── skills/.gitkeep             # Placeholder for user skills
│   └── _template/                          # Default project template
│       ├── project.yml                     # Project metadata & config (with comments)
│       ├── .claude/
│       │   ├── CLAUDE.md                   # Project instructions template ({{PLACEHOLDERS}})
│       │   ├── settings.json               # Project settings (empty, overrides go here)
│       │   ├── rules/
│       │   │   └── language.md             # Language override (commented out by default)
│       │   ├── agents/.gitkeep             # Project-specific agents
│       │   └── skills/.gitkeep             # Project-specific skills
│       └── claude-state/                   # Claude state dir placeholder
│           ├── .gitkeep
│           └── memory/.gitkeep             # Auto memory subdir placeholder
│
├── global/                                 # ── USER CONFIG (gitignored) ───
│   └── .claude/                            # User defaults from defaults/global/ + system files from defaults/system/
│       ├── settings.json                   # Customized by user
│       ├── CLAUDE.md                       # Customized by user
│       ├── mcp.json                        # Global MCP servers
│       ├── rules/                          # User rule files
│       ├── agents/                         # User global agents
│       └── skills/                         # User global skills
│
│   (optional, in global/)
│   ├── packs/                              # Knowledge packs
│   │   └── <pack-name>/
│   │       ├── pack.yml                    # Pack manifest (knowledge, skills, agents, rules)
│   │       ├── knowledge/                  # Optional: pack's own knowledge files (no source:)
│   │       ├── skills/                     # Optional: skills copied to projects on cco start
│   │       ├── agents/                     # Optional: agents copied to projects on cco start
│   │       └── rules/                      # Optional: rules copied to projects on cco start
│   ├── secrets.env                         # Sensitive env vars (loaded at runtime)
│   └── mcp-packages.txt                    # MCP npm packages to pre-install in image
│
└── projects/                               # ── USER PROJECTS (gitignored) ─
    └── <project-name>/                     # Created by `cco project create`
        ├── project.yml                     # Source of truth for the project
        ├── .claude/
        │   ├── CLAUDE.md                   # Project-specific instructions
        │   ├── settings.json               # Project-specific settings overrides
        │   ├── packs.md                    # Auto-generated instructional file list (by cco start)
        │   ├── workspace.yml               # Auto-generated project structure summary (by cco start)
        │   ├── rules/                      # Project-specific rules
        │   ├── agents/                     # Project-specific agents
        │   └── skills/                     # Project-specific skills
        ├── claude-state/                   # Claude state: memory + session transcripts (mounted to ~/.claude/projects/-workspace/)
        │   └── memory/                     # Auto memory subdir
        ├── mcp.json                        # Optional project-level MCP servers
        └── docker-compose.yml              # Auto-generated by `cco start` (not committed)
```

---

## File Descriptions

### Root Files

| File | Purpose | Notes |
|------|---------|-------|
| `Dockerfile` | Docker image definition | See [docker.md](./docker.md) §1.1 |
| `.dockerignore` | Exclude files from Docker build context | Excludes: `docs/`, `.git/`, `projects/*/claude-state/` |
| `.gitignore` | Git ignore patterns | Ignores: `global/`, `projects/` (user data), `.env` |
| `README.md` | Project overview and documentation index | What it is, how it works, requirements |
| `QUICK-START.md` | Setup and usage guide | Clone, init, create project, start session |
| `CLAUDE.md` | Guidance for Claude Code when working on this repo | Commands, architecture, conventions |

### config/

| File | Purpose | Notes |
|------|---------|-------|
| `entrypoint.sh` | Container entrypoint | Docker socket perms, MCP injection, gosu, tmux launch. See [docker.md](./docker.md) §1.2 |
| `tmux.conf` | tmux configuration | Colors, navigation, history, mouse. See [docker.md](./docker.md) §1.3 |
| `hooks/session-context.sh` | SessionStart hook | Discovers repos, counts MCP servers, injects context JSON |
| `hooks/subagent-context.sh` | SubagentStart hook | Condensed project context for subagents |
| `hooks/precompact.sh` | PreCompact hook | Guides context compaction (what to preserve) |
| `hooks/statusline.sh` | StatusLine hook | Reads session JSON, displays `[project] model \| ctx XX% \| $cost` |

### bin/

| File | Purpose | Notes |
|------|---------|-------|
| `cco` | CLI script | Single bash file, no external deps. See [cli.md](../reference/cli.md) |

### defaults/system/

System-managed files, always synced from `defaults/system/` to `global/.claude/` on every `cco init`, `cco start`, and `cco new`. User modifications to these files will be overwritten. `system.manifest` lists every managed path.

| File | Purpose | Notes |
|------|---------|-------|
| `system.manifest` | Lists all system-managed paths | Used by `_sync_system_files()` for overlay and cleanup |
| `settings.json` | User-level settings | Agent teams, permissions, hooks, bypass mode. See [context.md](../reference/context.md) §4.1 |
| `rules/workflow.md` | Workflow phase rules | Analysis, Design, Implementation, Documentation phases |
| `rules/git-practices.md` | Git conventions | Branch naming, conventional commits |
| `rules/diagrams.md` | Diagram conventions | Always use Mermaid, never ASCII art |
| `agents/analyst.md` | Analyst subagent | Haiku, read-only tools, user memory. See [subagents.md](../guides/subagents.md) §2.1 |
| `agents/reviewer.md` | Reviewer subagent | Sonnet, read-only tools, user memory. See [subagents.md](../guides/subagents.md) §2.2 |
| `skills/analyze/SKILL.md` | `/analyze` skill | Structured codebase exploration mode |
| `skills/commit/SKILL.md` | `/commit` skill | Conventional commit creation with confirmation |
| `skills/design/SKILL.md` | `/design` skill | Implementation planning mode |
| `skills/review/SKILL.md` | `/review` skill | Structured code review with checklist |
| `skills/init-workspace/SKILL.md` | `/init-workspace` skill | Initialize/refresh project CLAUDE.md from workspace repos |

### defaults/global/.claude/

User defaults, copied to `global/.claude/` once by `cco init`. User owns these files after the initial copy. Not overwritten unless `cco init --force` is used.

| File | Purpose | Notes |
|------|---------|-------|
| `CLAUDE.md` | User-level instructions | Workflow, git practices, communication, Docker environment |
| `mcp.json` | Global MCP server list | Empty by default; user populates. See [context.md](../reference/context.md) §8 |
| `rules/language.md` | Language preferences | Has `{{COMM_LANG}}`, `{{DOCS_LANG}}`, `{{CODE_LANG}}` placeholders, substituted by `cco init --lang` |

### defaults/_template/

Default project template, used by `cco project create` to scaffold new projects.

| File | Purpose | Notes |
|------|---------|-------|
| `project.yml` | Project config template | Repos, ports, auth, packs. See [cli.md](../reference/cli.md) §4 |
| `.claude/CLAUDE.md` | Project instructions template | `{{PROJECT_NAME}}` and `{{DESCRIPTION}}` placeholders |
| `.claude/settings.json` | Project settings template | Empty; project-specific overrides go here |
| `.claude/rules/language.md` | Language override template | Commented out by default; uncomment to override global |
| `.claude/agents/.gitkeep` | Placeholder | Project-specific agents |
| `.claude/skills/.gitkeep` | Placeholder | Project-specific skills |
| `claude-state/.gitkeep` | Claude state dir | Mounted to `~/.claude/projects/workspace/`; persists memory and session transcripts |
| `claude-state/memory/.gitkeep` | Auto memory subdir | Created empty; Claude populates with project insights |

---

## Generated Files (Not in Git)

These files are generated by the CLI or Claude Code and must not be committed:

| File | Generated By | Purpose |
|------|-------------|---------|
| `projects/<n>/docker-compose.yml` | `cco start` | Docker Compose config for the project session |
| `projects/<n>/.claude/packs.md` | `cco start` | Instructional file list for activated knowledge packs; injected via hook |
| `projects/<n>/.claude/.pack-manifest` | `cco start` | Tracks files copied from packs (skills, agents, rules); used for stale cleanup on next start |
| `projects/<n>/.claude/workspace.yml` | `cco start` | Structured project summary (repos, packs); read by `/init-workspace` skill |
| `global/.claude/.system-manifest` | `_sync_system_files()` | Tracks installed system file paths for cleanup on updates |
| `projects/<n>/claude-state/memory/*.md` | Claude Code | Auto memory files (project insights, patterns) |
| `projects/<n>/claude-state/*.json` | Claude Code | Session transcripts (enables `/resume` across rebuilds) |
| `.env` | User / secrets.env | Runtime secrets (not committed) |

---

## Implementation Order

Recommended order for building the repo from scratch:

| Phase | Files | Depends On |
|-------|-------|------------|
| 1. Docker | `Dockerfile`, `config/entrypoint.sh`, `config/tmux.conf`, `config/hooks/*`, `.dockerignore` | Nothing |
| 2. Global Config | `defaults/system/.claude/*`, `defaults/global/.claude/*` | Nothing |
| 3. Project Template | `defaults/_template/*` (all files) | Nothing |
| 4. CLI | `bin/cco` | Phases 1–3 (needs files to reference) |
| 5. Root Files | `README.md`, `QUICK-START.md`, `CLAUDE.md`, `.gitignore` | Phases 1–4 |
| 6. Testing | Manual: create project, start session, verify | Phases 1–5 |

---

## Validation Checklist

After implementation (or after significant changes), verify:

- [ ] `cco build` creates the Docker image successfully
- [ ] `cco init` copies user defaults to global/, syncs system files, and creates projects/
- [ ] `cco project create test-project --repo <any-repo>` creates correct project structure
- [ ] `cco start test-project` launches interactive Claude Code session
- [ ] Claude sees global CLAUDE.md (ask: "What are your global instructions?")
- [ ] Claude sees project CLAUDE.md (ask: "What project are you working on?")
- [ ] Claude sees repo `.claude/` when reading repo files (if repo has one)
- [ ] Git operations work inside container (`git commit`, `git push`)
- [ ] Docker commands work inside container (`docker ps`, `docker compose up`)
- [ ] Port mapping works (run `npx serve` on port 3000, access from host browser)
- [ ] Agent teams create panes (visible in tmux or iTerm2)
- [ ] Auto memory persists across sessions (check `projects/<n>/claude-state/memory/`)
- [ ] `/resume` works after `cco build --no-cache` (session transcripts in `projects/<n>/claude-state/`)
- [ ] Knowledge packs: `packs.md` is generated with correct instructional list on `cco start`
- [ ] Knowledge packs: `additionalContext` contains pack file list (check Claude's initial context)
- [ ] `workspace.yml` is generated at `projects/<n>/.claude/workspace.yml` on `cco start`
- [ ] SessionStart hook fires and injects context (visible in Claude's initial context)
- [ ] StatusLine shows project/model/context info
- [ ] `cco new --repo <path>` works for temporary sessions
- [ ] `cco stop` stops running sessions cleanly
- [ ] `cco project list` lists available projects with status
