# Roadmap

> Tracks planned features, improvements, and known issues for future iterations.
> Last updated: 2026-03-03 (bugfix #B1, RAG sprint added, declined claude-mem/claude-context).

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

## Known Bugs

### #B1 Browser MCP loaded when `browser.enabled: false` ✓ FIXED

**Fixed in**: `refactor/managed-integrations/convention`

**Root causes fixed**:

1. **Stale files on host**: `cmd-start.sh` now explicitly `rm -f .managed/browser.json .managed/.browser-port` when `browser_enabled != "true"`. Files moved to `.managed/` (gitignored).

2. **Additive-only MCP merge**: `entrypoint.sh` now resets `mcpServers = {}` before each session, then re-merges from source files. The entrypoint uses a generic loop over `/workspace/.managed/*.json` — only present when browser is enabled, so disabling browser removes it cleanly.

3. **`.managed/` gitignored**: migration 003 adds `.managed/` to each project's `.gitignore`.

---

## Implementation Order

Features are prioritized by impact for third-party users adopting claude-orchestrator. Each sprint can be implemented independently.

```
Bugfix (pre-sprint)
┌──────────────────────┐
│ #B1 Browser MCP      │
│     leak fix         │
└──────────────────────┘

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
Sprint 8 (polish)              Sprint 9 (distribuzione)
┌──────────────────────┐       ┌──────────────────────┐
│ #10 cco project edit │       │ #11 Config Vault     │
└──────────────────────┘       │ #12 Sharing/Import   │
                               └──────────────────────┘
Sprint 10 (intelligence)
┌──────────────────────┐
│ #13 Project RAG      │
│     (default MCP)    │
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

#### #10b Status bar improvements

Improve the StatusLine hook (`config/hooks/statusline.sh`) for better usability.

**Issues**:
1. **Cost display not useful for Max subscribers**: the `$cost` field shows cumulative USD spend, which is meaningless for users on Claude Max (flat-rate subscription). They would rather see remaining session/conversation budget as a percentage.
2. **Context % stale after /compact**: the `ctx` percentage does not update immediately after `/compact` or other context-reducing events — it takes an additional prompt before the value refreshes. This is likely a Claude Code limitation in how frequently it calls the StatusLine hook, but we should investigate workarounds.

**Proposed changes**:
- Detect subscription type from session data and show remaining session % instead of cost for Max users (requires investigation of available fields in StatusLine JSON input)
- Investigate whether `Notification` or `Stop` hook events can trigger a StatusLine refresh to fix stale context %
- If Claude Code does not expose subscription/session data, document the limitation and request the feature upstream
- Add configurable status bar format (e.g., `statusline.format` in global settings) so users can customize what is shown

---

### Sprint 9 — Config Vault & Sharing

Personal versioning and team sharing of packs, project configs, and global settings — powered by a dedicated git repo managed by the CLI.

#### #11 Config Vault — Git-backed versioning for global/ and projects/

A dedicated git repository (separate from claude-orchestrator itself) that versions the user's configuration: `global/` settings, project configs, and packs. The CLI manages this repo transparently.

**Motivation**: today `global/` and `projects/` are gitignored. Users have no way to version, backup, diff, or roll back their configuration. If something breaks or a machine is lost, all config is gone.

**Key design points**:
- `cco vault init` — initialize a git repo backing `global/` and `projects/` (or a subset)
- `cco vault sync` — commit current state with auto-generated message (or custom)
- `cco vault diff` — show what changed since last sync
- `cco vault log` — show config change history
- `cco vault restore <ref>` — restore config from a previous commit
- `cco vault remote add <url>` — link to a remote repo for push/pull backup
- The vault repo is distinct from claude-orchestrator (framework is generic, vault is personal)
- Sensitive files (`secrets.env`, `.credentials.json`) excluded by default with `.gitignore`
- Works with any git remote (GitHub, GitLab, private server)

**Scope**:
- `lib/cmd-vault.sh` — vault management commands
- Vault `.gitignore` template (exclude secrets, runtime files, `docker-compose.yml`)
- Auto-commit hooks (optional: auto-sync on `cco stop`)
- Test coverage for vault operations

#### #12 Sharing & Import — Multi-resource bundles

Share packs, project templates, and config bundles between users via git repos or archives.

**Motivation**: packs are currently local to a single user. There is no way to share a well-tuned pack, a project template, or a set of rules with a colleague.

**Key design points**:
- **Multi-resource repos**: a single git repo can contain multiple packs, project templates, and rules (avoids repo proliferation)
- `cco share install <git-url> [--resource <name>]` — install one or all resources from a shared repo
- `cco share export <type> <name>` — export a pack, project template, or rule set as a shareable archive or git-ready directory
- `cco share list` — list installed shared resources and their source repos
- `cco share update [<source>]` — pull latest from shared repos

**Shared repo structure** (convention):
```
my-team-config/
  packs/
    react-guidelines/
      pack.yml
      knowledge/...
    api-conventions/
      pack.yml
      ...
  templates/
    fullstack-project/
      project.yml      # Uses {{variables}} for user-specific paths
      .claude/
        CLAUDE.md
    microservice/
      project.yml
      ...
  rules/
    code-style.md
    security.md
  share.yml             # Manifest: lists available resources with descriptions
```

- **Project templates**: `project.yml` with placeholder variables (`{{REPO_PATH}}`, `{{PROJECT_NAME}}`) resolved at install time
- **Conflict handling**: warn if a resource already exists locally, offer merge/overwrite/skip
- **Versioning**: shared repos are git repos — users can pin to a tag/branch

**Open questions** (to discuss):
- Should `cco vault` and `cco share` be separate commands, or a unified `cco config` namespace?
- Should shared repos be registered globally (available to all projects) or per-project?
- How to handle pack updates from shared repos when the user has local modifications?
- Should we support a public registry/index of shared repos (future, not Sprint 9)?

---

### Sprint 10 — Project RAG

Integrated semantic search over project knowledge, providing Claude with relevant context from large codebases and documentation without consuming the full context window.

#### #13 Default RAG MCP Integration

Provide a built-in, opt-in RAG system that indexes project files and serves relevant context to Claude via MCP. Users can already add any RAG MCP server manually (via `mcp-packages.txt` or `mcp.json`), but a default integration adds significant value:
- Lowers the barrier (no research/configuration needed)
- Tested, integrated out-of-the-box experience
- Differentiator for claude-orchestrator adoption
- User can override with their own preferred MCP server

**Activation** (same pattern as browser):
```yaml
# project.yml
rag:
  enabled: false          # true to activate project RAG
  provider: local-rag     # default provider (can be overridden)
  paths: []               # directories to index (default: all repos)
  exclude: []             # glob patterns to exclude from indexing
```

**Provider options evaluated**:

| Provider | Storage | Local | API cost | Code-specific | Complexity |
|---|---|---|---|---|---|
| **mcp-local-rag** (LanceDB) | File-based | 100% | None | No | Low |
| **Qdrant MCP** (official) | Qdrant | Yes | None (FastEmbed) | No | Medium |
| **RagCode MCP** (Qdrant+Ollama) | Qdrant+Ollama | 100% | None | Yes (AST) | High (~8GB) |
| claude-context (Zilliz) | Zilliz Cloud | No | OpenAI | Yes | Medium |

**Recommended default provider**: `mcp-local-rag` — zero external dependencies, file-based LanceDB (no server process), ~90MB embedding model download, single `npx` command. Good balance of simplicity and capability.

**Alternative for power users**: Qdrant MCP with FastEmbed for local embedding — more capable but requires Qdrant instance (can run as sibling container via docker compose).

**Key design points**:
- Auto-generate RAG MCP config at `cco start` (same pattern as `.managed/browser.json` → `.managed/rag.json`)
- Index on first session start; incremental updates on subsequent starts
- Provider-agnostic: `rag.provider` selects which MCP server to configure; custom providers supported
- Respect `.gitignore` and `rag.exclude` patterns
- Indexing runs in background (non-blocking session start)
- Storage in `projects/<name>/rag-data/` (gitignored, persistent across sessions)

**Scope**:
- `project.yml` schema extension (`rag:` section)
- RAG MCP generation in `cmd-start.sh` (parallel to browser MCP)
- Entrypoint merge support (third merge source after global + browser)
- Migration for existing projects
- Documentation and user guide
- Test coverage for RAG enable/disable/provider switching

**Open questions**:
- Should indexing happen at `cco start` time (host-side) or inside the container (entrypoint)?
- Should we support a `cco rag reindex` command for manual re-indexing?
- For Qdrant provider: auto-start Qdrant as sibling container, or require user to manage it?
- Should the index be shared across projects that mount the same repos?

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

### claude-mem integration

**Evaluated**: 2026-03-03. [github.com/thedotmack/claude-mem](https://github.com/thedotmack/claude-mem) — automatic persistent memory for Claude Code via SQLite + ChromaDB, with AI-powered compression and progressive disclosure.

**Decision**: Do not integrate. Reasons:
- **Heavy dependencies**: Requires Bun, Python (for ChromaDB), SQLite, Node.js — too many runtimes inside an already complex container
- **Overhead per tool call**: Every tool use triggers a hook (timeout up to 120s). With agent teams in tmux, the slowdown multiplies
- **Hidden API costs**: AI compression consumes Anthropic tokens every session, even when the user doesn't search memory
- **Architecture mismatch**: Uses Claude Code's plugin system, not the lifecycle hooks standard. Integration with cco's entrypoint would be fragile
- **License**: AGPL-3.0 (restrictive for commercial use); `ragtime/` directory uses PolyForm Noncommercial
- **Overlap**: claude-orchestrator already provides per-project auto memory isolation (`claude-state/memory/`) and `MEMORY.md` auto-loaded by Claude Code. The native system covers most use cases adequately
- **Value/complexity ratio**: High complexity for incremental benefit over the native memory system

Users who want claude-mem can install it independently as a Claude Code plugin — it doesn't require framework integration.

### claude-context (Zilliz) as default RAG

**Evaluated**: 2026-03-03. [github.com/zilliztech/claude-context](https://github.com/zilliztech/claude-context) — semantic code search via Zilliz Cloud (managed Milvus) with hybrid BM25 + dense vector retrieval.

**Decision**: Do not use as default RAG provider. Reasons:
- **Cloud dependency**: Requires Zilliz Cloud — cannot function offline or without external service
- **Requires OpenAI API key**: Additional cost for embeddings (unless using alternative providers)
- **Privacy concern**: Source code is sent to third-party cloud services (Zilliz + OpenAI) — unacceptable for many commercial/proprietary projects
- **Vendor lock-in**: Strongly tied to Zilliz/Milvus ecosystem

However, claude-context could be supported as an **optional provider** in the RAG system (Sprint 10, `rag.provider: claude-context`) for users who accept cloud-based indexing. The default provider should be fully local.
