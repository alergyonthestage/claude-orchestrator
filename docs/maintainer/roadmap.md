# Roadmap

> Tracks planned features, improvements, and known issues for future iterations.
> Last updated: 2026-03-02 (prioritized implementation order, Sprint 5 tutorial added).

---

## Completed

### Automated Testing ✓

Pure bash test suite (`bin/test`) covering 154 test cases across 11 test files. Tests run without a Docker container using `--dry-run` and file-system assertions. Zero external dependencies.

**Coverage**: `cco init`, `cco project create`, `cco start --dry-run` (docker-compose generation), knowledge pack generation, workspace.yml generation, YAML parser edge cases, `cco stop`, `cco project list`.

### Knowledge Packs — Full Schema (knowledge + skills + agents + rules) ✓

Packs now support the full expanded schema: `knowledge:` section for document mounts, plus `skills:`, `agents:`, and `rules:` for project-level tooling. Skills/agents/rules are copied at `cco start` time (not mounted, to avoid Docker volume collisions with multi-pack setups).

Knowledge files are injected automatically via `session-context.sh` hook (no `@.claude/packs.md` in CLAUDE.md required).

### /init-workspace Skill ✓

Managed project initialization skill at `defaults/managed/.claude/skills/init-workspace/SKILL.md` (baked into the Docker image at `/etc/claude-code/.claude/skills/init-workspace/`). Uses a distinct name to avoid clashing with the built-in `/init` command. Reads `workspace.yml`, explores repositories, generates a structured CLAUDE.md, and writes descriptions back to `workspace.yml`. Non-overridable — updated only via `cco build`.

### Review Fixes Sprint 1 ✓

CLI robustness and settings alignment from the 24-02-2026 architecture review:
- Fixed test `test_packs_md_has_auto_generated_header` (assertion mismatch with generated output)
- Added `alwaysThinkingEnabled: true` to global settings (aligning doc and implementation)
- Simplified SessionStart hook to single catch-all matcher (was duplicated for startup + clear)
- Added session lock check — `cco start` now detects already-running containers and exits with a clear message
- Added `secrets.env` format validation — malformed lines are skipped with a warning
- Added `--claude-version` flag and `ARG CLAUDE_CODE_VERSION` for reproducible Docker builds

### Pack Manifest & Conflict Detection ✓

Pack resources are now tracked in a `.pack-manifest` file. On each `cco start`, stale files from the previous session are cleaned before fresh copies. Name conflicts between packs (same agent/rule/skill name) emit a warning. ADR-9 documents the copy-vs-mount design trade-off.

### Authentication & Secrets ✓

Unified auth for container sessions: `GITHUB_TOKEN` (fine-grained PAT) as primary mechanism, `gh` CLI in Dockerfile, per-project `secrets.env` with override semantics. `gh auth login --with-token` + `gh auth setup-git` in entrypoint. OAuth credentials seeded from macOS Keychain to `~/.claude/.credentials.json`.

### Environment Extensibility ✓

Full extensibility story implemented:
- `docker.image` in project.yml — custom Docker image per project
- Per-project `secrets.env` overrides `global/secrets.env`
- `global/setup.sh` — system packages at build time (via `SETUP_SCRIPT_CONTENT` build arg)
- `projects/<name>/setup.sh` — per-project runtime setup (mounted and run by entrypoint)
- `projects/<name>/mcp-packages.txt` — per-project npm MCP packages (installed at startup)

### Docker Socket Toggle ✓

`docker.mount_socket: false` in project.yml disables Docker socket mount for projects that don't need sibling containers.

### Update System ✓

Intelligent config merge system to update `projects/` and `global/` without losing user customizations.

**What's included**:
- `cco update` command: `--project`, `--all`, `--dry-run`, `--force`, `--keep`, `--backup` flags
- Hybrid checksum + migrations engine (`lib/update.sh`, `lib/cmd-update.sh`)
- `.cco-meta` file: schema versioning, file manifest with hashes, saved language choices
- Migration runner: `migrations/global/` and `migrations/project/` (NNN_name.sh convention)
- Backward compatibility for installations without `.cco-meta`
- `cco init` updated: generates `.cco-meta` with correct hashes on first setup
- `cco start` updated: shows hint if schema_version < latest
- Test suite: `tests/test_update.sh` (14 scenarios)

**Docs**: [update-system/design.md](./update-system/design.md)

---

### Scope Hierarchy Refactor (Sprint 3) ✓

Reorganization of the configuration hierarchy to leverage Claude Code's native **Managed** level (`/etc/claude-code/`). Infrastructure files (hooks, env, deny rules) are protected in the Managed level; agents, skills, rules, and preferences moved to the User level where they are customizable and never overwritten.

**What changed**:
- `defaults/system/` removed → replaced by `defaults/managed/` (baked into the Docker image)
- `managed-settings.json` contains only hooks, env vars, statusLine, deny rules (non-overridable)
- Agents, skills, rules, settings.json moved to `defaults/global/.claude/` (user-owned)
- `_sync_system_files()` removed → replaced by `_migrate_to_managed()` (one-time migration)
- `system.manifest` removed (managed files baked into the Docker image via `COPY`)
- Dockerfile updated: `COPY defaults/managed/ /etc/claude-code/`
- Test suite updated: `test_system_sync.sh` → `test_managed_scope.sh` (15 tests)

**Docs**: [analysis](./scope-hierarchy/analysis.md) | [ADR-3](./architecture.md) | [ADR-8](./architecture.md)

### Fix tmux copy-paste (Sprint 2) ✓

Improved tmux configuration for clipboard and selection:
- `default-terminal` upgraded from `screen-256color` to `tmux-256color` (full terminfo)
- Explicit `terminal-features` clipboard capability for non-xterm terminals
- `allow-passthrough on` for DCS sequences (iTerm2 inline images, etc.)
- `MouseDragEnd1Pane` auto-copy on mouse release (no need to press `y`)
- `C-v` rectangle selection toggle in copy-mode
- Fixed bypass key documentation (Terminal.app uses `fn`, not `Shift`)
- Full copy-paste user guide in agent-teams.md (setup per terminal, 3 methods, troubleshooting)
- In-container OAuth login section with copy-paste instructions
- Cross-reference from project-setup.md Authentication section

**Analysis**: [terminal-clipboard-and-mouse.md](./agent-teams/analysis.md)

---

## Implementation Order

Features are prioritized by impact for third-party users adopting claude-orchestrator. Each sprint can be implemented independently.

```
Sprint 4 (frontend)
┌──────────────────────┐
│ #4 Browser MCP       │
│    Integration       │
└──────────────────────┘

Sprint 5 (onboarding)
┌──────────────────────┐
│ #5 Interactive       │
│    Tutorial Project  │
└──────────────────────┘

Sprint 6 (differenziante)      Sprint 7 (ecosistema)
┌──────────────────────┐       ┌──────────────────────┐
│ #6 Git Worktree      │       │ #8 cco pack create   │
│    Isolation          │       │ #9 Pack inheritance  │
│ #7 Session Resume    │       └──────────────────────┘
└──────────────────────┘
                               Sprint 8 (polish)
                               ┌──────────────────────┐
                               │ #10 cco project edit │
                               └──────────────────────┘
```

---

### Sprint 4 — Browser Automation ✅

Required for frontend testing and debugging. Requires stable scope hierarchy (Sprint 3) for proper MCP configuration placement.

#### #4 Browser MCP Integration — Implemented

Enable Claude to control a browser via Chrome DevTools MCP, with the browser visible to the user on the host OS.

**What was implemented**:
- `browser.enabled` / `browser.mode: host` in `project.yml` + `--chrome` flag override
- `chrome-devtools-mcp` pre-installed in Docker image
- Auto-generated `browser-mcp.json` with privacy flags (`--no-usage-statistics`, `--no-performance-crux`)
- Third MCP merge source in `entrypoint.sh`
- CDP port conflict resolution with auto-assignment and `.browser-port` runtime file
- `cco chrome [start|stop|status]` host-side helper with `--project` port resolution
- `extra_hosts: host.docker.internal:host-gateway` for Linux compatibility
- Support for custom `mcp_args` via `yml_get_list`
- 18 new tests (12 dry-run + 6 chrome command)

**Deferred to future sprint**: container mode (`mode: container` — sibling Chrome + noVNC)

**Docs**: [analysis](./browser-mcp/analysis.md) | [design](./browser-mcp/design.md)

---

### Sprint 5 — Interactive Tutorial Project

Required before open-source publication. Provides a guided, hands-on onboarding experience that teaches new users how to use claude-orchestrator effectively.

#### #5 Interactive Tutorial Project — AI-Guided Onboarding

A self-contained example project that users launch with `cco start tutorial` (or similar). Once inside the session, an AI agent guides the user through claude-orchestrator's features interactively — explaining concepts, demonstrating workflows, and answering questions in real time.

**Goals**:
- Lower the barrier to entry for new users adopting claude-orchestrator
- Showcase key features (project setup, knowledge packs, agent teams, browser MCP, etc.) through hands-on exercises
- Serve as living documentation — the tutorial itself uses the features it teaches
- Clarify common doubts about architecture, configuration, and advanced techniques
- Prepare the repository for open-source publication with a polished first-run experience

**Key design points**:
- Ships as a built-in example project (e.g. `examples/tutorial/`) with a pre-configured `project.yml`
- A dedicated knowledge pack provides the tutorial curriculum and structured lesson content
- An agent (skill or custom agent) orchestrates the interactive session: presents lessons, checks understanding, adapts to user pace
- Progressive curriculum: basics (project structure, repos, CLAUDE.md) → intermediate (packs, secrets, MCP) → advanced (agent teams, worktrees, custom images)
- Each lesson includes a practical exercise the user performs inside the tutorial session
- The agent can answer free-form questions about claude-orchestrator at any point (FAQ mode)
- `cco tutorial` shortcut command (alias for `cco start tutorial`) for discoverability

**Scope**:
- Tutorial project scaffold (`examples/tutorial/` or `defaults/tutorial/`)
- Knowledge pack with curriculum content (lessons, exercises, reference material)
- Tutorial agent/skill with interactive guidance logic
- CLI integration (`cco tutorial` command or documented `cco start` usage)
- Minimal test coverage for tutorial project generation

**Open questions**:
- Should the tutorial be a standalone `cco tutorial` command or a regular project the user creates via `cco project create --template tutorial`?
- How many lessons / what depth for v1? Suggest starting with 5-7 core lessons covering the essentials
- Should the tutorial track user progress across sessions (resume where you left off)?

---

### Sprint 6 — Differentiating feature

#### #6 Git Worktree Isolation

Opt-in git isolation for container sessions. When enabled, repos are mounted at `/git-repos/` and the entrypoint creates worktrees at `/workspace/` on a dedicated branch (`cco/<project>`). Claude works in the worktrees transparently.

**Why here**: Auth is now implemented, enabling the full PR/merge workflow that makes worktree isolation valuable.

**Activation**: `cco start <project> --worktree` or `worktree: true` in `project.yml`.

**Key design points**:
- Worktrees created inside the container (consistent paths, no `.git` file rewriting)
- Commits persist in host repo via bind-mounted object store
- Post-session cleanup integrated in `cmd_start()` (no `cco stop` needed)
- Multiple merge/PR cycles during a single session via standard `gh pr create`
- Session resume: branch `cco/<project>` persists, next `--worktree` start reuses it

**Docs**: [analysis](./future/worktree/analysis.md) | [design](./future/worktree/design.md) | [ADR-10](./architecture.md)

#### #7 Session resume

`cco resume <project>` — reattach to a running tmux session inside a running container. Complements worktree isolation: resume work on the same branch.

---

### Sprint 7 — Pack ecosystem

#### #8 `cco pack create <name>` command

Scaffold a new pack definition interactively, similar to `cco project create`. Lowers the barrier for creating packs.

#### #9 Pack inheritance / composition

Allow packs to extend other packs:
```yaml
extends: base-client
files:
  - additional-doc.md
```

---

### Sprint 8 — Automation and polish

#### #10 `cco project edit <name>` command

Open project.yml in `$EDITOR` and regenerate docker-compose.yml after save.

---

## Long-term / Exploratory

### Remote sessions

Mount repos from remote hosts via SSHFS or similar, enabling orchestrator sessions on remote development machines.

### Multi-project sessions

A single Claude session with repos from multiple projects, for cross-project refactoring or analysis tasks.

### Web UI

Optional lightweight web dashboard for listing projects, starting/stopping sessions, viewing logs, and editing project configurations.

---

## Declined / Won't Do

### PreToolUse safety hook

Proposal from review (§2 gap 3): hook to block `rm -rf /`, `git push --force`, access outside `/workspace`.

**Decision**: Do not implement. Docker is the sandbox (ADR-1). The container operates with limited mount points. Specific commands to block can be added case-by-case in the future if a concrete need emerges.
