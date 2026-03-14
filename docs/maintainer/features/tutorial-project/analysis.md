# Tutorial Project — Analysis

**Date**: 2026-03-10
**Version**: 1.0
**Scope**: Sprint 5 — Interactive Tutorial Project
**Status**: Analysis complete — ready for design review

---

## 1. Problem Statement

claude-orchestrator requires a guided onboarding experience before open-source publication. New users face a steep learning curve: Docker isolation, four-tier context hierarchy, knowledge packs, agent teams, project configuration — all concepts that interact and need to be understood together.

Currently, the only onboarding path is reading static documentation (45 files, ~12k lines). There is no interactive, agent-guided experience.

### 1.1 Target Users

| User | Need | Expected Behavior |
|------|------|-------------------|
| **New user** | Quick onboarding, understand what cco does and how to configure it | Guided tour, progressive, hands-on |
| **Intermediate user** | Assisted setup of packs and projects for their org | Proactive consultation, intelligent scaffolding |
| **Advanced user / maintainer** | Deep-dive into concepts, validate ideas, explore features | Navigable knowledge base, FAQ mode |

### 1.2 Non-Goals

- **Not a cco development environment**: maintainers will have a separate `cco-maintainers` project in the future.
- **Not a code generation tool**: the tutorial agent teaches, explains, and assists with configuration — it does not write application code.

---

## 2. Technical Findings

### 2.1 `cco` CLI Cannot Run Inside the Container

**Finding**: `bin/cco` is a host-side CLI that cannot execute inside a Docker container.

**Evidence**:
- `bin/cco:5-10` — resolves `REPO_ROOT` from `SCRIPT_DIR`, loads 15+ modules from `$LIB_DIR`
- `bin/cco:16-28` — all paths (`GLOBAL_DIR`, `PROJECTS_DIR`, `PACKS_DIR`) resolve relative to `REPO_ROOT` or `USER_CONFIG_DIR`, which are host filesystem paths
- `lib/cmd-start.sh:306-400` — generates `docker-compose.yml` with host-side mount paths (e.g., `${GLOBAL_DIR}/.claude/settings.json:/home/claude/.claude/settings.json:ro`)
- The Dockerfile does not install `bin/cco` or `lib/` — only hooks (`config/hooks/`) and managed files (`defaults/managed/`)

**Implication**: The tutorial agent CANNOT execute `cco` commands. All `cco` operations (`cco project create`, `cco pack create`, `cco start`, etc.) must be performed by the user on their host terminal.

**Design consequence**: The agent explains, instructs, and prepares files — but the user executes `cco` commands. This aligns with the tutorial's educational purpose: the user learns by doing.

### 2.2 The claude-orchestrator Repo Is Always Available on the Host

**Finding**: `cco` is installed by cloning the repo (`git clone <url> ~/claude-orchestrator`). The user always has:
- `REPO_ROOT/docs/` — full documentation
- `REPO_ROOT/defaults/` — templates, managed files
- `REPO_ROOT/bin/cco` — the CLI
- `REPO_ROOT/user-config/` — user data (created by `cco init`)

**Implication**: We can mount `docs/` as an extra_mount in the tutorial project. When maintainers update docs, the tutorial project automatically has the latest version — zero staleness risk.

### 2.3 Mount Mechanics for extra_mounts

**Finding** (`lib/cmd-start.sh:377-387`): `extra_mounts` from `project.yml` are processed as `source:target:mode` strings. The `expand_path()` function (`lib/utils.sh:9-14`) handles tilde expansion.

**Current mount structure** (from `cmd-start.sh:306-400`):

```
Host                                    Container                          Mode
──────────────────────────────────      ──────────────────────────         ────
GLOBAL_DIR/.claude/settings.json   →    ~/.claude/settings.json            ro
GLOBAL_DIR/.claude/CLAUDE.md       →    ~/.claude/CLAUDE.md                ro
GLOBAL_DIR/.claude/rules/          →    ~/.claude/rules/                   ro
GLOBAL_DIR/.claude/agents/         →    ~/.claude/agents/                  ro
GLOBAL_DIR/.claude/skills/         →    ~/.claude/skills/                  ro
project_dir/.claude/               →    /workspace/.claude                 rw
project_dir/project.yml            →    /workspace/project.yml             ro
project_dir/claude-state/          →    ~/.claude/projects/-workspace      rw
repos[].path                       →    /workspace/<repo-name>             rw
extra_mounts[].source              →    extra_mounts[].target              per-config
```

**Implication**: We can add two extra_mounts to the tutorial project:

1. `docs/` → `/workspace/cco-docs` (ro) — documentation always fresh
2. `user-config/` → `/workspace/user-config` (configurable ro/rw)

### 2.4 Path Resolution for Tutorial project.yml

**Challenge**: The tutorial's `project.yml` needs absolute host paths for `extra_mounts`. But the template lives in `templates/project/tutorial/` and gets copied to `user-config/projects/tutorial/` by `cco init`. At template time, we don't know the host paths.

**Solution**: `cco init` already performs placeholder substitution (see `cmd-init.sh:73-79` for `{{COMM_LANG}}` replacement). We extend this pattern:

```yaml
# templates/project/tutorial/project.yml (template)
extra_mounts:
  - source: {{CCO_REPO_ROOT}}/docs
    target: /workspace/cco-docs
    readonly: true
  - source: {{CCO_USER_CONFIG_DIR}}
    target: /workspace/user-config
    readonly: true
```

At `cco init` time, `{{CCO_REPO_ROOT}}` and `{{CCO_USER_CONFIG_DIR}}` are replaced with the actual paths. This is a minimal, clean extension of the existing pattern.

### 2.5 user-config Mount: Read-Only vs Read-Write

**Default: read-only**. The agent can analyze the user's configuration (existing projects, packs, global settings) without risk of accidental modification.

**User opt-in: read-write**. When the user wants the agent to create or modify packs/projects, they change `readonly: true` → `readonly: false` in the tutorial's `project.yml`. The agent should explain this step.

**What the agent can do with user-config mounted rw**:
- Create pack directories and `pack.yml` files in `user-config/packs/`
- Create project scaffolds in `user-config/projects/`
- Modify `.claude/CLAUDE.md` in existing projects
- Add rules, agents, skills to existing projects

**What the agent CANNOT do** (even with rw):
- Run `cco start` (host-only command)
- Run `cco pack validate` (host-only)
- Build Docker images
- Manage Docker containers

The agent creates the files; the user runs `cco` commands to activate them.

---

## 3. Architecture Decisions

### 3.1 No Knowledge Pack — Self-Contained Project

**Decision**: The tutorial project does NOT use a knowledge pack. It is self-contained.

**Rationale**:
- The tutorial is a single-purpose project — no reuse scenario across multiple projects
- Packs add complexity (another concept to explain during onboarding)
- The tutorial's documentation needs come from `docs/` (mounted, always fresh), not from a static pack that could become stale
- Self-contained means the tutorial just works with zero extra setup

**What replaces the pack**: The `docs/` directory is mounted as an extra_mount. The agent reads documentation files on-demand. The tutorial project's `.claude/CLAUDE.md` provides the behavioral instructions and curriculum.

### 3.2 Mount docs/ Instead of Duplicating Content

**Decision**: Mount `REPO_ROOT/docs/` read-only at `/workspace/cco-docs` instead of copying documentation into a knowledge pack.

**Rationale**:
- **Zero staleness**: maintainers update `docs/`, tutorial automatically has the latest version
- **Zero maintenance overhead**: no second copy to keep in sync
- **Single source of truth**: docs are authoritative, the agent reads the real docs
- **No duplication**: saves ~12k lines of duplicated content

**How the agent uses docs**: The CLAUDE.md instructs the agent to consult `/workspace/cco-docs/` for accurate, up-to-date information. File descriptions in CLAUDE.md guide on-demand loading (same pattern as pack descriptions, but without the pack mechanism).

### 3.3 Mount user-config/ for Analysis and Modification

**Decision**: Mount `user-config/` at `/workspace/user-config` with configurable read-only/read-write access.

**Rationale**:
- **Analysis**: The agent can inspect existing projects, packs, and global config to give contextual advice
- **Scaffolding**: With rw access, the agent can create pack.yml files, project CLAUDE.md, etc.
- **Safety**: Default read-only prevents accidental modifications. User opts in explicitly.

**Constraint**: The agent MUST explain what it wants to do, get user approval, and instruct the user on how cco processes the files. The goal is teaching, not just doing.

### 3.4 Tutorial Created by Default with `cco init`

**Decision**: `cco init` creates the tutorial project automatically in `user-config/projects/tutorial/`.

**Rationale**:
- Maximum discoverability for new users
- Zero friction: `cco init` → `cco start tutorial` → guided onboarding
- Users who don't want it can remove the directory (`rm -rf user-config/projects/tutorial/`)
- Can also be created later via `cco project create --template tutorial` (for users who removed it)

**Implementation**: Add tutorial project creation to `cmd_init()` after the global config copy. Substitute `{{CCO_REPO_ROOT}}` and `{{CCO_USER_CONFIG_DIR}}` placeholders in `project.yml`.

### 3.5 Agent Behavior: Explain, Instruct, Get Approval

**Decision**: The tutorial agent operates as a teacher/consultant, not as an autonomous executor.

**Rules**:
1. **Always explain**: Before any action, explain what it does and why, referencing cco concepts
2. **Always instruct**: Show the user the equivalent `cco` command they would run on their host
3. **Always get approval**: Never modify files or execute commands without explicit user confirmation
4. **Proactive discovery**: Suggest features, workflows, and best practices relevant to the user's context
5. **Reference real docs**: Point to specific documentation files for deeper reading

**Exception**: Reading files (exploring docs, analyzing user-config) does not require approval — it's the agent's core function.

---

## 4. `cco` Commands: Agent vs User Responsibilities

| Action | Who Executes | How |
|--------|-------------|-----|
| Read docs, analyze config | Agent | Reads mounted `/workspace/cco-docs` and `/workspace/user-config` |
| Create pack.yml, knowledge files | Agent (with rw mount) | Writes to `/workspace/user-config/packs/<name>/` |
| Create project scaffolds | Agent (with rw mount) | Writes to `/workspace/user-config/projects/<name>/` |
| Write CLAUDE.md for a project | Agent (with rw mount) | Writes to `/workspace/user-config/projects/<name>/.claude/CLAUDE.md` |
| `cco pack validate` | User (host) | Agent instructs: "Run `cco pack validate my-pack` on your host terminal" |
| `cco start <project>` | User (host) | Agent instructs: "Run `cco start my-project` to launch a session" |
| `cco build` | User (host) | Agent instructs when needed |
| `cco pack install <url>` | User (host) | Agent instructs for remote pack installation |

**Key insight**: The agent prepares the filesystem; the user activates with `cco`. This mirrors real-world usage: configuration is file-based, activation is CLI-based.

---

## 5. Curriculum Design

### 5.1 Approach: Hybrid Completeness + Adaptability

The curriculum is NOT a rigid sequence of lessons. Instead, it's organized as **modules** that the agent can present in order (for linear onboarding) or navigate on-demand (for targeted questions).

The agent adapts based on:
- User's stated experience level (beginner / intermediate / advanced)
- What already exists in `user-config/` (if projects exist → skip basics, focus on optimization)
- User's specific questions (FAQ mode anytime)

### 5.2 Module Map

```
FOUNDATION
├── M1: What is claude-orchestrator? (concepts, architecture, why Docker)
├── M2: Your first project (project.yml, repos, cco start, cco stop)
└── M3: Writing effective CLAUDE.md (/init-workspace, context hierarchy)

CONFIGURATION
├── M4: Knowledge packs (create, structure, activate, best practices)
├── M5: Authentication & secrets (OAuth, API key, GitHub token, secrets.env)
└── M6: Environment customization (setup.sh, MCP servers, custom images)

COLLABORATION
├── M7: Agent teams (tmux, subagents, skills, delegation)
├── M8: Sharing & distribution (Config Repos, vault, team workflows)
└── M9: Browser automation (Chrome DevTools, CDP, testing workflows)

MASTERY
├── M10: Structured development workflow (phases, analysis→design→implementation)
├── M11: Pack design patterns (composability, rules vs knowledge, modularization)
└── M12: Advanced configuration (context hierarchy deep-dive, migrations, update system)
```

### 5.3 Each Module Contains

- **Concept explanation**: What it is, why it matters, how it fits in the bigger picture
- **Hands-on exercise**: A practical task the user performs (create a project, write a pack, etc.)
- **Validation**: The agent checks the result and gives feedback
- **Next steps**: What to explore next, related modules
- **Doc references**: Specific files in `/workspace/cco-docs/` for deeper reading

### 5.4 Adaptive Flow

```
Session start
  → Agent reads user-config/ to understand existing setup
  → Agent greets user, asks: "What would you like to do?"
  → Three paths:
    A) "I'm new" → Start from M1, guided tour
    B) "Help me set up my projects" → Skip to M4-M5, contextual to user's org
    C) "I have a specific question" → FAQ mode, navigate to relevant module
  → At any point user can ask free-form questions → agent consults docs
  → Agent proactively suggests relevant features based on context
```

---

## 6. Tutorial Project Structure

```
templates/project/tutorial/
├── project.yml                    # Pre-configured: no repos, extra_mounts for docs + user-config
├── .claude/
│   ├── CLAUDE.md                  # Agent instructions, curriculum, behavior rules
│   ├── settings.json              # Tutorial-specific settings (if needed)
│   ├── agents/
│   │   └── guide.md               # Tutorial guide agent (sonnet)
│   ├── skills/
│   │   ├── tutorial/
│   │   │   └── SKILL.md           # /tutorial — start guided onboarding
│   │   ├── setup-project/
│   │   │   └── SKILL.md           # /setup-project — assisted project creation
│   │   └── setup-pack/
│   │       └── SKILL.md           # /setup-pack — assisted pack creation
│   └── rules/
│       └── tutorial-behavior.md   # Behavior constraints (explain, instruct, approve)
├── claude-state/
│   └── memory/
│       └── .gitkeep
└── setup.sh                       # (empty or minimal)
```

### 6.1 project.yml Template

```yaml
name: tutorial
description: "Interactive tutorial and onboarding assistant for claude-orchestrator"

repos: []

extra_mounts:
  - source: {{CCO_REPO_ROOT}}/docs
    target: /workspace/cco-docs
    readonly: true
  - source: {{CCO_USER_CONFIG_DIR}}
    target: /workspace/user-config
    readonly: true    # Change to false to allow agent to create packs/projects

docker:
  mount_socket: false    # Tutorial doesn't need Docker socket by default
  ports: []
  env: {}

auth:
  method: oauth
```

### 6.2 Key Design Choices

- **No repos**: Tutorial is about cco itself, not about code
- **mount_socket: false**: Safer default. Can be enabled if user wants Docker demos.
- **No packs**: Self-contained, docs mounted directly
- **Sonnet for guide agent**: Good balance of capability and cost for interactive sessions
- **Three skills**: `/tutorial` (onboarding), `/setup-project` (creation), `/setup-pack` (creation)

---

## 7. Agent Specifications

### 7.1 Guide Agent (`guide.md`)

```
Model: sonnet
Tools: Read, Write, Edit, Bash, Grep, Glob
Memory: project (tracks progress and user preferences between sessions)
```

The guide is the primary agent. It:
- Leads the tutorial flow
- Reads docs on-demand from `/workspace/cco-docs/`
- Analyzes user-config from `/workspace/user-config/`
- Creates files in user-config (when rw and approved)
- Explains concepts, demonstrates workflows, answers questions

### 7.2 Skills

| Skill | Purpose | Trigger |
|-------|---------|---------|
| `/tutorial` | Start or resume guided onboarding | User types `/tutorial` |
| `/setup-project` | Assisted project creation wizard | User types `/setup-project` |
| `/setup-pack` | Assisted pack creation wizard | User types `/setup-pack` |

Skills are entry points. The lead agent can also handle these organically in conversation.

---

## 8. Documentation Knowledge Map

The agent needs to know which docs to consult for each topic. This mapping lives in the tutorial CLAUDE.md:

```
/workspace/cco-docs/getting-started/   → Overview, installation, first project, concepts
/workspace/cco-docs/user-guides/       → Project setup, packs, auth, sharing, agent teams, browser
/workspace/cco-docs/reference/         → CLI commands, context hierarchy, project.yml format
/workspace/cco-docs/user-guides/advanced/ → Subagents, custom environments
```

The agent reads these files on-demand based on the user's current question or module. File descriptions in CLAUDE.md guide loading (same pattern as pack descriptions).

---

## 9. Implementation Requirements

### 9.1 Changes to Existing Code

| Component | Change | Scope |
|-----------|--------|-------|
| `lib/cmd-init.sh` | Add tutorial project creation with path substitution | ~20 lines |
| `templates/project/tutorial/` | New directory with all tutorial project files | New |
| `bin/cco` | Add `cco tutorial` alias (optional, for discoverability) | ~5 lines |
| `docs/maintainer/roadmap.md` | Update Sprint 5 status | Docs |
| Tests | Test tutorial project creation by `cco init` | ~10-15 test cases |

### 9.2 No Changes Required

- Dockerfile (no new managed files)
- Entrypoint (standard project startup)
- Hooks (standard SessionStart/SubagentStart)
- Managed settings (no new hooks or deny rules)
- Global defaults (no new agents/skills at global level)

---

## 10. Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Agent gives outdated advice | Medium | Docs mounted live → always fresh. Agent instructed to reference docs, not rely on training data alone |
| user-config mount rw causes unintended changes | Medium | Default read-only. Agent rules require explicit user approval. Agent explains every change |
| Path substitution breaks on edge cases | Low | Test with spaces, special chars. `expand_path` already handles tilde |
| Tutorial project bloats cco init for users who don't want it | Low | Simple `rm -rf` to remove. Documented in output of `cco init` |
| Agent drift in long sessions | Medium | Modular curriculum, clear behavior rules, session boundaries suggested |

---

## 11. Future Enhancements (Not in v1)

- **Progress tracking via MEMORY.md**: Agent remembers completed modules across sessions. Deferred: memory feature needs testing first.
- **`cco tutorial` CLI shortcut**: Alias for `cco start tutorial`. Nice-to-have, not required.
- **Template mode**: `cco project create --template tutorial` for re-creation after removal.
- **Validation exercises**: Agent checks user's project/pack configurations against best practices.
- **Multi-language curriculum**: Tutorial content adapted to user's language preference.

---

## 12. Open Questions (Resolved)

| # | Question | Resolution |
|---|----------|------------|
| 1 | Distribution mechanism? | Created by `cco init` by default. Removable. Re-creatable via template |
| 2 | Progress tracking? | Deferred to future version. No MEMORY.md tracking in v1 |
| 3 | Curriculum depth? | 12 modules in 4 tiers. Hybrid: sequential for beginners, on-demand for others |
| 4 | How to access docs? | Mount `REPO_ROOT/docs/` as extra_mount. Always fresh, zero duplication |
| 5 | Dedicated skills? | Yes: `/tutorial`, `/setup-project`, `/setup-pack`. Reference real docs |
| 6 | Can cco run in container? | No. Agent explains, user runs on host. Agent can write files if user-config is rw |
| 7 | Knowledge packs? | Not used. Self-contained project. Docs mounted directly |

---

## 13. Dependencies

- **No blocking dependencies**: The tutorial project uses only existing features (extra_mounts, agents, skills, rules)
- **Soft dependency on docs quality**: The agent is only as good as the docs it reads. Current docs coverage is comprehensive (45 files, ~12k lines)
- **Template substitution in cco init**: Minor code addition, same pattern as language placeholders
