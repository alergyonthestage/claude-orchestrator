# Roadmap

> Tracks planned features, improvements, and known issues for future iterations.
> Last updated: 2026-02-26 (prioritized implementation order).

---

## Completed

### Automated Testing ✓

Pure bash test suite (`bin/test`) covering 154 test cases across 11 test files. Tests run without a Docker container using `--dry-run` and file-system assertions. Zero external dependencies.

**Coverage**: `cco init`, `cco project create`, `cco start --dry-run` (docker-compose generation), knowledge pack generation, workspace.yml generation, YAML parser edge cases, `cco stop`, `cco project list`.

### Knowledge Packs — Full Schema (knowledge + skills + agents + rules) ✓

Packs now support the full expanded schema: `knowledge:` section for document mounts, plus `skills:`, `agents:`, and `rules:` for project-level tooling. Skills/agents/rules are copied at `cco start` time (not mounted, to avoid Docker volume collisions with multi-pack setups).

Knowledge files are injected automatically via `session-context.sh` hook (no `@.claude/packs.md` in CLAUDE.md required).

### /init-workspace Skill ✓

Custom project initialization skill at `defaults/system/.claude/skills/init-workspace/SKILL.md` (synced to `global/.claude/skills/` by system sync). Uses a distinct name to avoid clashing with the built-in `/init` command. Reads `workspace.yml`, explores repositories, generates a structured CLAUDE.md, and writes descriptions back to `workspace.yml`.

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

### Fix tmux copy-paste (Sprint 2) ✓

Improved tmux configuration for clipboard and selection:
- `default-terminal` upgraded from `screen-256color` to `tmux-256color` (full terminfo)
- Explicit `terminal-features` clipboard capability for non-xterm terminals
- `allow-passthrough on` for DCS sequences (iTerm2 inline images, etc.)
- `MouseDragEnd1Pane` auto-copy on mouse release (no need to press `y`)
- `C-v` rectangle selection toggle in copy-mode
- Fixed bypass key documentation (Terminal.app uses `fn`, not `Shift`)
- Full copy-paste user guide in display-modes.md (setup per terminal, 3 methods, troubleshooting)
- In-container OAuth login section with copy-paste instructions
- Cross-reference from project-setup.md Authentication section

**Analysis**: [terminal-clipboard-and-mouse.md](../analysis/terminal-clipboard-and-mouse.md)

---

## Implementation Order

Features are prioritized by impact for third-party users adopting claude-orchestrator. Each sprint can be implemented independently.

```
Sprint 3 (differenziante)       Sprint 4 (ecosistema)
┌──────────────────────┐        ┌──────────────────────┐
│ #2 Git Worktree      │        │ #4 cco pack create   │
│    Isolation          │        │ #5 Pack inheritance  │
│ #3 Session Resume    │        └──────────────────────┘
└──────────────────────┘
                                Sprint 5 (polish)
                                ┌──────────────────────┐
                                │ #6 cco project edit  │
                                │ #7 cco update        │
                                │ #8 Browser MCP       │
                                └──────────────────────┘
```

---

### Sprint 3 — Feature differenziante

#### #2 Git Worktree Isolation

Opt-in git isolation for container sessions. When enabled, repos are mounted at `/git-repos/` and the entrypoint creates worktrees at `/workspace/` on a dedicated branch (`cco/<project>`). Claude works in the worktrees transparently.

**Why here**: Auth is now implemented, enabling the full PR/merge workflow that makes worktree isolation valuable.

**Activation**: `cco start <project> --worktree` or `worktree: true` in `project.yml`.

**Key design points**:
- Worktrees created inside the container (consistent paths, no `.git` file rewriting)
- Commits persist in host repo via bind-mounted object store
- Post-session cleanup integrated in `cmd_start()` (no `cco stop` needed)
- Multiple merge/PR cycles during a single session via standard `gh pr create`
- Session resume: branch `cco/<project>` persists, next `--worktree` start reuses it

**Docs**: [analysis](../analysis/worktree-isolation.md) | [design](./worktree-design.md) | [ADR-10](./architecture.md)

#### #3 Session resume

`cco resume <project>` — reattach to a running tmux session inside a running container. Complements worktree isolation: resume work on the same branch.

---

### Sprint 4 — Ecosistema Pack

#### #4 `cco pack create <name>` command

Scaffold a new pack definition interactively, similar to `cco project create`. Lowers the barrier for creating packs.

#### #5 Pack inheritance / composition

Allow packs to extend other packs:
```yaml
extends: base-client
files:
  - additional-doc.md
```

---

### Sprint 5 — Automazione e polish

#### #6 `cco project edit <name>` command

Open project.yml in `$EDITOR` and regenerate docker-compose.yml after save.

#### #7 `cco update` — merge intelligente config

Metodo per aggiornare `projects/` e `global/` quando l'orchestratore aggiunge skill, template o modifica strutture, senza perdere customizzazioni utente (merge intelligente defaults → user config).

#### #8 Browser Automation MCP in Docker

Enable Claude to navigate and analyze web pages from within a container session using a headless browser MCP server.

**Approach**:
- Install Chromium in the `Dockerfile` (`apt-get install -y chromium`)
- Add a Playwright or Puppeteer MCP server to `global/mcp.json`
- Browser runs headless inside the container — no display or VNC required

**Note**: With environment extensibility (now implemented), users can already install Chromium via `global/setup.sh`. This item becomes providing an out-of-the-box solution with `cco build --with-browser`.

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
