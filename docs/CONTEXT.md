# Context & Settings Hierarchy

> Version: 1.0.0
> Status: Draft — Pending Review
> Related: [ARCHITECTURE.md](./ARCHITECTURE.md) | [SPEC.md](./SPEC.md)

---

## 1. Overview

Claude Code loads configuration from multiple locations with a fixed precedence. The orchestrator maps its three-tier config (global → project → repo) onto Claude Code's native hierarchy so that everything "just works" without hacks.

---

## 2. Settings Precedence

Claude Code resolves settings from highest to lowest precedence:

```
1. Managed settings       ← NOT USED (enterprise only)
2. Command-line args      ← --dangerously-skip-permissions
3. Local project settings ← /workspace/.claude/settings.local.json (optional)
4. Shared project         ← /workspace/.claude/settings.json       ← OUR PROJECT
5. User settings          ← ~/.claude/settings.json                ← OUR GLOBAL
```

**Implication**: Project settings override global settings. This is correct behavior — a project can tighten or loosen rules defined globally.

---

## 3. Memory (CLAUDE.md) Resolution

### 3.1 Loaded at Launch

These files are loaded into Claude's context when the session starts:

| File | Container Path | Source |
|------|---------------|--------|
| User CLAUDE.md | `~/.claude/CLAUDE.md` | `global/.claude/CLAUDE.md` |
| User rules | `~/.claude/rules/*.md` | `global/.claude/rules/*.md` |
| Project CLAUDE.md | `/workspace/.claude/CLAUDE.md` | `projects/<n>/.claude/CLAUDE.md` |
| Project rules | `/workspace/.claude/rules/*.md` | `projects/<n>/.claude/rules/*.md` |

### 3.2 Loaded On-Demand

These files are loaded when Claude reads files in the corresponding directories:

| File | Container Path | Source |
|------|---------------|--------|
| Repo CLAUDE.md | `/workspace/<repo>/.claude/CLAUDE.md` | Lives in the repo itself |
| Repo rules | `/workspace/<repo>/.claude/rules/*.md` | Lives in the repo itself |
| Nested CLAUDE.md | `/workspace/<repo>/subdir/CLAUDE.md` | Lives in the repo itself |

### 3.3 Imports (@path syntax)

CLAUDE.md files support `@path/to/file` imports. Paths resolve relative to the file containing the import.

**Example** — project CLAUDE.md importing repo-specific docs:
```markdown
# Project: My SaaS Platform

See @backend-api/README.md for API overview.
See @frontend-app/docs/architecture.md for frontend architecture.
```

This works because the repos are subdirectories of `/workspace/`.

---

## 4. File Specifications

### 4.1 Global Settings (`global/.claude/settings.json`)

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",

  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },

  "permissions": {
    "allow": [
      "Bash(git *)",
      "Bash(npm *)",
      "Bash(npx *)",
      "Bash(node *)",
      "Bash(python3 *)",
      "Bash(pip *)",
      "Bash(docker *)",
      "Bash(docker compose *)",
      "Bash(tmux *)",
      "Bash(cat *)",
      "Bash(ls *)",
      "Bash(find *)",
      "Bash(grep *)",
      "Bash(rg *)",
      "Bash(head *)",
      "Bash(tail *)",
      "Bash(wc *)",
      "Bash(sort *)",
      "Bash(mkdir *)",
      "Bash(cp *)",
      "Bash(mv *)",
      "Bash(rm *)",
      "Bash(chmod *)",
      "Bash(curl *)",
      "Bash(wget *)",
      "Bash(jq *)",
      "Read",
      "Edit",
      "Write",
      "WebFetch",
      "WebSearch",
      "Task"
    ],
    "deny": [
      "Read(~/.claude.json)",
      "Read(~/.ssh/*)"
    ],
    "defaultMode": "bypassPermissions"
  },

  "alwaysThinkingEnabled": true,
  "teammateMode": "tmux",
  "cleanupPeriodDays": 30
}
```

**Notes**:
- `defaultMode: "bypassPermissions"` is redundant with `--dangerously-skip-permissions` but documents intent
- The `allow` list is comprehensive to avoid any prompt even if bypass mode is not active
- `deny` protects auth token and SSH keys from accidental reads
- `teammateMode` defaults to `"tmux"` — user can override to `"auto"` for iTerm2

### 4.2 Global CLAUDE.md (`global/.claude/CLAUDE.md`)

```markdown
# Global Instructions

## Development Workflow

Every task follows this structured workflow. Phase transitions are MANUAL — 
never skip ahead or auto-advance without explicit user approval.

### Phases
1. **Analysis** → Understand requirements, explore codebase, identify constraints
2. **Review & Approval** → Present findings, wait for user feedback
3. **Design** → Propose architecture, interfaces, data models
4. **Review & Approval** → Present design, wait for user feedback  
5. **Implementation & Testing** → Write code, tests, verify
6. **Review & Approval** → Present implementation, wait for user feedback
7. **Documentation** → Update docs, README, API docs, changelog
8. **Closure** → Final review, merge readiness check

### Scope Levels
The workflow applies recursively at multiple levels:
- **Project**: Overall project planning and architecture
- **Architecture**: System-wide design decisions
- **App/Service**: Individual application or microservice
- **Module**: Component or module within an app
- **Feature**: Specific feature or user story

Always clarify the current scope level before starting work.

### Phase Behavior
- During **Analysis**: Read code, ask questions, produce summaries. NO code changes.
- During **Design**: Produce design docs, diagrams, interface definitions. NO implementation.
- During **Implementation**: Write code and tests. Follow the approved design.
- During **Documentation**: Update all relevant docs. NO new features.

## Git Practices
- Always work on feature branches, never directly on main/master
- Use conventional commits: feat:, fix:, docs:, refactor:, test:, chore:
- Commit frequently with meaningful, descriptive messages
- Create a new branch at the start of any implementation phase
- Branch naming: `<type>/<scope>/<description>` (e.g., `feat/auth/add-oauth-flow`)

## Communication Style
- Be concise and direct
- Present findings in structured format
- When presenting options, include trade-offs
- Ask clarifying questions before making assumptions
- At the end of each phase, summarize what was done and what's next

## Agent Teams
- The lead coordinates and delegates work to teammates
- Each teammate focuses on their specialized domain
- Use the shared task list for coordination
- Communicate relevant findings between teammates
- The lead synthesizes teammate outputs into coherent results

## Docker Environment
- This session runs inside a Docker container
- Repos are mounted at /workspace/<repo-name>/
- Docker socket is available — you can run docker and docker compose
- When starting infrastructure (postgres, redis, etc.), use the project network
- Dev servers run inside this container with ports mapped to the host
```

### 4.3 Global Rules

Modular rule files in `global/.claude/rules/`:

**`workflow.md`** — Detailed workflow phase behaviors:
```markdown
# Workflow Phase Rules

## Analysis Phase
- Read and understand all relevant code before proposing changes
- Identify dependencies, constraints, and potential risks
- Document findings in a structured analysis summary
- List questions that need answers before proceeding
- DO NOT modify any files during analysis

## Design Phase  
- Reference the analysis findings
- Propose clear interfaces and data models
- Consider error handling and edge cases
- Evaluate alternatives and document trade-offs
- Produce diagrams where helpful (ASCII, mermaid)
- DO NOT write implementation code during design

## Implementation Phase
- Follow the approved design
- Write tests alongside implementation
- Commit after each logical unit of work
- Run existing tests to verify no regressions
- If the design needs changes, pause and discuss

## Documentation Phase
- Update README if public API changed
- Update inline code comments
- Update changelog
- Document new configuration options
- DO NOT add new features during documentation
```

**`git-practices.md`** — Git conventions:
```markdown
# Git Practices

## Branch Strategy
- Main branch: `main` (never commit directly)
- Feature branches: `feat/<scope>/<description>`
- Fix branches: `fix/<scope>/<description>`
- Always branch from the latest main

## Commit Messages
Follow conventional commits:
- `feat: add user authentication`
- `fix: resolve race condition in queue processor`
- `docs: update API endpoint documentation`
- `refactor: extract validation logic to shared module`
- `test: add integration tests for payment flow`
- `chore: update dependencies`

## Commit Frequency
- Commit after each logical, working unit of change
- Each commit should leave the codebase in a working state
- Prefer many small commits over few large ones
```

### 4.4 Project CLAUDE.md Template (`projects/_template/.claude/CLAUDE.md`)

```markdown
# Project: {{PROJECT_NAME}}

## Overview
{{DESCRIPTION}}

## Repositories

{{#each repos}}
### {{name}}
- Path: /workspace/{{name}}/
- Description: {{description}}
{{/each}}

## Project-Specific Instructions

<!-- Add project-specific instructions, conventions, and context here -->

## Architecture

<!-- Describe the overall architecture, how repos relate to each other -->

## Infrastructure

<!-- If this project uses docker compose for infrastructure:
- Network name: cc-{{PROJECT_NAME}}
- Set `networks.default.external = true` and `networks.default.name = cc-{{PROJECT_NAME}}`
  in infrastructure docker-compose files so containers join the project network.
-->

## Key Commands

<!-- Common commands for this project:
- Build: ...
- Test: ...
- Run dev: ...
- Deploy: ...
-->
```

### 4.5 Project Settings Template (`projects/_template/.claude/settings.json`)

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json"
}
```

Empty by default — inherits everything from global. Projects add overrides as needed:

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "deny": [
      "Read(./.env)",
      "Read(./.env.*)",
      "Read(./secrets/**)"
    ]
  }
}
```

---

## 5. Auto Memory

### 5.1 How Auto Memory Works

Claude Code stores auto memory at:
```
~/.claude/projects/<project-identifier>/memory/
├── MEMORY.md          # Index, first 200 lines loaded at startup
├── debugging.md       # Topic files, loaded on demand
└── patterns.md
```

The `<project-identifier>` is derived from the git root directory. Since `/workspace` is not a git repo, Claude Code falls back to using the working directory name: `workspace`.

### 5.2 Isolation Strategy

Each project gets its own `memory/` directory inside the orchestrator:

```
projects/
├── my-saas/
│   ├── memory/            ← mounted to ~/.claude/projects/workspace/memory/
│   │   ├── MEMORY.md
│   │   └── ...
│   └── .claude/
└── other-project/
    ├── memory/            ← mounted (only active project's memory is mounted)
    └── .claude/
```

**Mount in docker-compose**:
```yaml
volumes:
  - ./memory:/home/claude/.claude/projects/workspace/memory
```

Since only one project's container runs at a time (or they use different container names), there's no conflict.

### 5.3 Important: Path Validation

The exact auto memory path depends on Claude Code's internal logic. The path `~/.claude/projects/workspace/memory/` assumes Claude Code uses the WORKDIR basename `workspace`.

**Action required during implementation**: Run a test session, let Claude create auto memory, then check the actual path:
```bash
docker exec -it <container> find /home/claude/.claude/projects -type d
```

Adjust the mount path in the docker-compose template if the actual path differs.

---

## 6. Subagents

### 6.1 Resolution

Claude Code loads subagents from:
1. `~/.claude/agents/` — User-level (our `global/.claude/agents/`)
2. `/workspace/.claude/agents/` — Project-level (our `projects/<n>/.claude/agents/`)

Project agents take precedence over global agents with the same name.

### 6.2 Default Agents

See [SUBAGENTS.md](./SUBAGENTS.md) for full specifications.

---

## 7. Skills

### 7.1 Resolution

Claude Code discovers skills from:
1. `~/.claude/skills/` — User-level (our `global/.claude/skills/`)
2. `/workspace/.claude/skills/` — Project-level
3. `/workspace/<repo>/.claude/skills/` — Repo-level (on-demand)

### 7.2 Planned Skills

No default skills in v1. Skills can be added as patterns emerge from usage. Candidates:
- `/analyze` — Enter analysis mode with structured output
- `/design` — Enter design mode with templates
- `/review` — Code review checklist
- `/commit` — Conventional commit with context

---

## 8. MCP Servers

### 8.1 Configuration Locations

- User-level: `~/.claude.json` (already mounted for auth)
- Project-level: `/workspace/.mcp.json`

### 8.2 Strategy

No default MCP servers in v1. Projects can add their own by creating `.mcp.json` in their `.claude/` directory or at `/workspace/` level.

Common MCP servers to document:
- GitHub (for PR management)
- PostgreSQL (for database queries)
- Filesystem (for additional directory access)

---

## 9. Configuration Checklist

When creating a new project, these files should be configured:

| File | Required | Purpose |
|------|----------|---------|
| `project.yml` | ✅ | Defines repos, ports, auth |
| `.claude/CLAUDE.md` | ✅ | Project instructions |
| `.claude/settings.json` | ❌ | Override global settings |
| `.claude/rules/*.md` | ❌ | Project-specific rules |
| `.claude/agents/*.md` | ❌ | Project-specific subagents |
| `.claude/skills/` | ❌ | Project-specific skills |
| `memory/` | auto | Created automatically on first run |
| `docker-compose.yml` | auto | Generated by CLI from project.yml |
