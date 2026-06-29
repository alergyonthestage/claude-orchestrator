# Requirements Specification

> Version: 1.0.0
> Status: v1.0 — Current

---

## 1. Overview

**claude-orchestrator** is a repository that simplifies launching and managing Claude Code interactive sessions in Docker containers for multi-project, multi-repo development workflows.

### 1.1 Goals

- **One command to start**: `cco start <project>` launches an isolated, fully configured Claude Code session
- **Multi-repo projects**: Each project can mount multiple repositories with their own context
- **Decentralized context management**: Project config lives in each repo (`<repo>/.cco/`), global config in the personal `~/.cco` store, repo-native config in the repo itself — each at the scope it serves
- **Agent teams ready**: Every session supports agent teams with configurable display (tmux or iTerm2)
- **Safe autonomy**: `--dangerously-skip-permissions` inside Docker isolation eliminates repetitive prompts
- **Development workflow support**: Structured phases (analysis → design → implementation → docs) guided by CLAUDE.md instructions

### 1.2 Non-Goals

- This is NOT a CI/CD tool — sessions are interactive, human-in-the-loop
- This does NOT replace Claude Code's native features — it orchestrates them
- No automated phase transitions — the user controls workflow progression
- No multi-user support — single developer workstation tool

---

## 2. Functional Requirements

### FR-1: Docker-Based Sessions

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-1.1 | Sessions run in Docker containers with Claude Code installed | Must |
| FR-1.2 | Sessions launch in interactive mode (TTY attached, user sees Claude UI) | Must |
| FR-1.3 | `--dangerously-skip-permissions` is enabled by default | Must |
| FR-1.4 | Container image includes: git, tmux, jq, ripgrep, docker CLI, docker compose, node, python3 | Must |
| FR-1.5 | Docker socket from host is mounted in the container for Docker-from-Docker | Must |
| FR-1.6 | Container can run dev servers (e.g., `npm run dev`) with ports accessible from host | Must |
| FR-1.7 | Container can orchestrate other Docker services via docker-compose on the host daemon | Must |

### FR-2: Project Configuration

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-2.1 | A project is defined by a `<repo>/.cco/project.yml` config committed **inside the repo that hosts it**. `project.yml` carries logical names + machine-agnostic `url`/`ref` coordinates — no host paths. There is no central `projects/` directory | Must |
| FR-2.2 | Each project specifies which repositories to mount (by logical name + coordinate); the machine-local STATE index resolves names to absolute host paths | Must |
| FR-2.3 | `cco init` scaffolds a repo's `.cco/` from `templates/project/base/` and registers it in the index; `cco join` adds a co-located repo to an existing project; `cco init --migrate` lazily converts a legacy centralized project. Additional templates available via `cco template list` | Must |
| FR-2.4 | Projects can define extra volume mounts (docs, specs, etc.) | Should |
| FR-2.5 | Temporary sessions (`cco new`) work without a project config | Must |
| FR-2.6 | `docker-compose.yml` is auto-generated from `project.yml` (into machine-local STATE) by the CLI | Must |

### FR-3: Context Management

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-3.1 | Three-tier context: global → project → repo (matching Claude Code's user → project → nested hierarchy) | Must |
| FR-3.2 | `~/.cco/.claude/` is mounted to `~/.claude/` in the container | Must |
| FR-3.3 | The invoking repo's `<repo>/.cco/claude/` is mounted to `/workspace/.claude/`; generated overlays (packs.md, workspace.yml) are layered `:ro` from CACHE | Must |
| FR-3.4 | Repository `.claude/` directories are included automatically via repo volume mounts | Must |
| FR-3.5 | Global settings include agent teams enabled, always thinking, and bypass permissions | Must |
| FR-3.6 | Project settings can override global settings following Claude Code precedence | Must |
| FR-3.7 | Auto memory is isolated per project via separate mount | Must |

### FR-4: Authentication

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-4.1 | Default auth: mount `~/.claude.json` as read-only seed, copy at startup (OAuth session) | Must |
| FR-4.2 | Alternative auth: `ANTHROPIC_API_KEY` environment variable | Must |
| FR-4.3 | Auth method is configurable per project in `project.yml` | Should |

### FR-5: Agent Teams Display

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-5.1 | Support tmux display mode (split panes inside container) | Must |
| FR-5.2 | Support iTerm2 native display mode (requires it2 CLI + Python API) | Should |
| FR-5.3 | Default mode is configurable in global settings (`teammateMode`) | Must |
| FR-5.4 | User can override display mode per session via CLI flag | Should |
| FR-5.5 | Documentation explains setup for both modes | Must |

### FR-6: CLI Tool

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-6.1 | `cco start <project>` — start a session for a configured project (also discoverable from the cwd repo) | Must |
| FR-6.2 | `cco new [--repo <path>]...` — start a temporary session with specified repos | Must |
| FR-6.3 | `cco init` — scaffold a repo's `.cco/` config (with `cco join` to add a co-located repo, `cco init --migrate` to convert a legacy project) | Must |
| FR-6.4 | `cco list` — list available projects | Must |
| FR-6.5 | `cco build` — build/rebuild the Docker image | Must |
| FR-6.6 | `cco stop [project]` — stop running session(s) | Should |
| FR-6.7 | CLI is a single bash script at `bin/cco` | Must |

### FR-7: Custom Subagents

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-7.1 | Two default subagents: `analyst` (read-only, haiku) and `reviewer` (read-only, sonnet) | Must |
| FR-7.2 | Subagents defined as markdown files in `~/.cco/.claude/agents/` | Must |
| FR-7.3 | Projects can add project-specific subagents in `<repo>/.cco/claude/agents/` | Should |
| FR-7.4 | Documentation explains how to create new subagents | Must |

### FR-8: Development Workflow

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-8.1 | Global CLAUDE.md defines the standard workflow phases | Must |
| FR-8.2 | Workflow phases: analysis → review → design → review → implementation → review → docs → closure | Must |
| FR-8.3 | Phase transitions are manual (user-driven) | Must |
| FR-8.4 | Workflow applies recursively at: project, architecture, app, module, feature levels | Must |
| FR-8.5 | Git practices enforced via CLAUDE.md: feature branches, conventional commits | Must |

---

## 3. Non-Functional Requirements

### NFR-1: Performance

| ID | Requirement |
|----|-------------|
| NFR-1.1 | Session startup (from `cco start` to Claude UI) under 15 seconds (warm image) |
| NFR-1.2 | Docker image build under 5 minutes |

### NFR-2: Portability

| ID | Requirement |
|----|-------------|
| NFR-2.1 | Runs on macOS with Docker Desktop |
| NFR-2.2 | Should also work on Linux with Docker Engine |
| NFR-2.3 | Primary terminal: iTerm2 (macOS). Should work in any terminal for basic features |

### NFR-3: Maintainability

| ID | Requirement |
|----|-------------|
| NFR-3.1 | CLI is a single bash script with no external dependencies beyond docker/docker-compose. Requires bash 3.2+ (compatible with macOS default `/bin/bash`) |
| NFR-3.2 | All configuration is in YAML, JSON, or Markdown — no custom formats |
| NFR-3.3 | Adding a new project requires only running `cco init` in a repo (scaffolds `<repo>/.cco/` with project.yml and registers it in the index) |

### NFR-4: Input Validation

| ID | Requirement |
|----|-------------|
| NFR-4.1 | All `project.yml` fields MUST be validated before generating `docker-compose.yml` |
| NFR-4.2 | Invalid values MUST produce user-visible warnings, not silent acceptance |
| NFR-4.3 | Boolean fields MUST accept YAML standard variants (`true/false`, `yes/no`, `on/off`, `1/0`) case-insensitively |
| NFR-4.4 | All parsed values MUST have leading and trailing whitespace trimmed |
| NFR-4.5 | Incomplete compound entries (repos without name, mounts without target) MUST produce an error, not silent data loss |
| NFR-4.6 | Values injected into generated files (JSON, YAML, shell) MUST be properly escaped |

### NFR-5: Secure Defaults

| ID | Requirement |
|----|-------------|
| NFR-5.1 | When a security-relevant field is omitted, the default MUST be the most restrictive value |
| NFR-5.2 | When a value cannot be parsed or is malformed, the fallback MUST be the most restrictive/safe option |
| NFR-5.3 | Omission of a config field MUST NOT silently grant additional permissions or access |
| NFR-5.4 | `extra_mounts[].readonly` defaults to `true` (read-only) when the field is omitted |

---

## 4. Constraints

| # | Constraint |
|---|------------|
| C-1 | Claude Code is installed via npm inside the container, not on the host |
| C-2 | Docker Desktop for Mac uses a Linux VM; `network_mode: host` refers to the VM, not macOS. Port mapping is required for host access |
| C-3 | Claude Code's settings precedence is fixed: managed > CLI > local > project > user |
| C-4 | Auto memory path is derived from git repo root — `/workspace` in container means all projects share the same path unless isolated |
| C-5 | Docker socket mount gives container full control over host Docker daemon — acceptable for a single-developer workstation |

---

## 5. User Stories

### US-1: Start a project session
> As a developer, I want to run `cco start my-saas` and immediately get an interactive Claude Code session with all my repos mounted and context loaded, so I can start working without manual setup.

### US-2: Create a temporary session
> As a developer, I want to run `cco new --repo ~/projects/experiment` to quickly spin up a Claude session with a single repo, without creating a project template first.

### US-3: Add a new project
> As a developer, I want to run `cco init` inside a repo and get a pre-configured `<repo>/.cco/` (committed with the code) that I can customize with my repos and context — so my project config travels with the repo and is shared via its normal git remote.

### US-4: Run dev servers from Claude
> As a developer, I want Claude to be able to run `npm run dev` inside the container and have me access the running app at localhost:3000 on my Mac.

### US-5: Claude manages Docker infrastructure
> As a developer, I want Claude to be able to run `docker compose up` for a microservices stack (e.g., postgres, redis, nginx, app containers) and have all services accessible and communicating.

### US-6: Isolated auto memory
> As a developer working on multiple projects, I want each project's Claude auto memory to be separate so insights from project A don't leak into project B.

### US-7: Use agent teams with visual panes
> As a developer, I want to see agent team teammates in split panes (via tmux or iTerm2) so I can monitor their progress and interact with individual teammates.
