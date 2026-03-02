# Roadmap

> Tracks planned features, improvements, and known issues for future iterations.
> Last updated: 2026-02-27 (prioritized implementation order).

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

### Scope Hierarchy Refactor (Sprint 3) ✓

Riorganizzazione della gerarchia di configurazione per sfruttare il livello **Managed** nativo di Claude Code (`/etc/claude-code/`). File infrastrutturali (hooks, env, deny rules) protetti nel livello Managed; agents, skills, rules e preferenze spostati nel livello User dove sono personalizzabili e mai sovrascritti.

**Cosa è cambiato**:
- `defaults/system/` eliminato → sostituito da `defaults/managed/` (baked nell'immagine Docker)
- `managed-settings.json` contiene solo hooks, env vars, statusLine, deny rules (non sovrascrivibile)
- Agents, skills, rules, settings.json spostati in `defaults/global/.claude/` (user-owned)
- `_sync_system_files()` eliminata → sostituita da `_migrate_to_managed()` (migrazione one-time)
- `system.manifest` eliminato (managed files baked nell'immagine Docker via `COPY`)
- Dockerfile aggiornato: `COPY defaults/managed/ /etc/claude-code/`
- Test suite aggiornata: `test_system_sync.sh` → `test_managed_scope.sh` (15 test)

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

Sprint 5 (differenziante)      Sprint 6 (ecosistema)
┌──────────────────────┐       ┌──────────────────────┐
│ #5 Git Worktree      │       │ #7 cco pack create   │
│    Isolation          │       │ #8 Pack inheritance  │
│ #6 Session Resume    │       └──────────────────────┘
└──────────────────────┘
                               Sprint 7 (polish)
                               ┌──────────────────────┐
                               │ #9  cco project edit │
                               │ #10 cco update       │
                               └──────────────────────┘
```

---

### Sprint 4 — Browser Automation

Necessario per testing e debugging frontend. Richiede scope hierarchy stabile (Sprint 3) per il corretto posizionamento della configurazione MCP.

#### #4 Browser MCP Integration

Enable Claude to control a browser via Chrome DevTools MCP, with the browser visible to the user on the host OS.

**Approach** (see [analysis](./future/browser-mcp/analysis.md)):
- Native "Claude in Chrome" doesn't work from Docker (IPC-local, no network transport)
- Use **chrome-devtools-mcp** (Google, CDP-based, 29 tools) connecting to Chrome on the host via `host.docker.internal:9222`
- Two modes: `host` (Chrome on host, native UI, user sees actions) and `container` (sibling Chrome container + noVNC)
- Configured via `browser:` section in `project.yml`
- `cco chrome` helper command for host-side Chrome launch
- Telemetry disabled by default (`--no-usage-statistics --no-performance-crux`)

**Key design points**:
- Pre-install `chrome-devtools-mcp` in Dockerfile for instant startup
- MCP config injected in `.mcp.json` at `cco start` when `browser.enabled: true`
- `extra_hosts: host.docker.internal:host-gateway` in docker-compose for Linux compatibility
- Container mode uses `selenium/standalone-chrome` with noVNC on port 7900

**Docs**: [analysis](./future/browser-mcp/analysis.md)

---

### Sprint 5 — Feature differenziante

#### #5 Git Worktree Isolation

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

#### #6 Session resume

`cco resume <project>` — reattach to a running tmux session inside a running container. Complements worktree isolation: resume work on the same branch.

---

### Sprint 6 — Ecosistema Pack

#### #7 `cco pack create <name>` command

Scaffold a new pack definition interactively, similar to `cco project create`. Lowers the barrier for creating packs.

#### #8 Pack inheritance / composition

Allow packs to extend other packs:
```yaml
extends: base-client
files:
  - additional-doc.md
```

---

### Sprint 7 — Automazione e polish

#### #9 `cco project edit <name>` command

Open project.yml in `$EDITOR` and regenerate docker-compose.yml after save.

#### #10 `cco update` — merge intelligente config

Metodo per aggiornare `projects/` e `global/` quando l'orchestratore aggiunge skill, template o modifica strutture, senza perdere customizzazioni utente (merge intelligente defaults → user config).

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

Proposta dalla review (§2 gap 3): hook per bloccare `rm -rf /`, `git push --force`, accesso fuori `/workspace`.

**Decisione**: Non implementare. Docker è il sandbox (ADR-1). Il container opera con mount point limitati. Eventuali comandi specifici da bloccare possono essere aggiunti puntualmente in futuro se emerge un bisogno concreto.
