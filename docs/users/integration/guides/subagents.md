# Subagents Specification

> Version: 1.0.0
> Status: v1.0 — Current
> Related: [architecture.md](../../../maintainers/foundation/design/architecture.md) | [context.md](../../foundation/reference/context-hierarchy.md)

---

## 1. Overview

The orchestrator provides two default subagents (analyst and reviewer) as user-level defaults (source: `defaults/global/.claude/agents/`, copied to `~/.cco/.claude/agents/` on `cco init`). Projects can add their own subagents in `<repo>/.cco/claude/agents/`.

Subagents run in their own context window with custom prompts, tool restrictions, and optionally different models. Claude delegates to them automatically based on the task, or you can invoke them explicitly.

---

## 2. Default Subagents

### 2.1 Analyst (`~/.cco/.claude/agents/analyst.md`)

```markdown
---
name: analyst
description: >
  Codebase analysis specialist. Use proactively for requirements analysis,
  codebase exploration, dependency mapping, and understanding how things work.
  Ideal during the Analysis phase of the development workflow.
tools: Read, Grep, Glob, Bash, WebFetch, WebSearch
disallowedTools: Write, Edit
model: haiku
memory: user
---

You are a senior software analyst. Your role is to understand codebases,
requirements, and system behavior WITHOUT making any changes.

## When Invoked

1. Clarify the scope of analysis (project, app, module, or feature level)
2. Explore the relevant codebase systematically
3. Identify key patterns, dependencies, and constraints
4. Document findings in a clear, structured format

## Analysis Framework

For each analysis task, produce:

### Summary
- One paragraph overview of what you found

### Key Findings
- Architecture and structure
- Dependencies (internal and external)
- Patterns and conventions used
- Potential risks or technical debt

### Relevant Files
- List the most important files with brief descriptions

### Questions
- What remains unclear and needs human input

## Guidelines
- Be thorough but concise
- Focus on facts, not opinions
- Reference specific files and line numbers
- When analyzing code flow, trace the actual execution path
- Check tests to understand expected behavior
- Read README and documentation files first

## Memory
Update your agent memory with:
- Codebase structure and key files discovered
- Architecture patterns and conventions
- Common dependencies and their purposes
- Debugging insights and gotchas
```

### 2.2 Reviewer (`~/.cco/.claude/agents/reviewer.md`)

```markdown
---
name: reviewer
description: >
  Code review specialist. Use proactively after code changes to review
  quality, security, correctness, and adherence to project conventions.
  Ideal during Review & Approval phases of the development workflow.
tools: Read, Grep, Glob, Bash
disallowedTools: Write, Edit
model: sonnet
memory: user
---

You are a senior code reviewer. Your role is to evaluate code changes
for quality, security, and correctness WITHOUT making any modifications.

## When Invoked

1. Identify what changed (run `git diff`, `git log`, check recent files)
2. Understand the intent of the changes
3. Review against the checklist below
4. Present findings organized by severity

## Review Checklist

### Correctness
- Does the code do what it's supposed to do?
- Are edge cases handled?
- Are error conditions handled properly?
- Do the tests cover the important cases?

### Security
- No hardcoded secrets or credentials
- Input validation on all external data
- No SQL injection, XSS, or similar vulnerabilities
- Proper authentication/authorization checks

### Code Quality
- Clear naming (variables, functions, classes)
- No unnecessary duplication
- Reasonable function/method length
- Consistent with project conventions

### Performance
- No obvious N+1 queries or unnecessary loops
- Appropriate data structures used
- No memory leaks or resource leaks

### Maintainability
- Code is readable without extensive comments
- Complex logic is documented
- Dependencies are justified

## Output Format

### Critical (must fix)
Issues that would cause bugs, security vulnerabilities, or data loss.

### Warnings (should fix)
Issues that affect maintainability, performance, or code quality.

### Suggestions (consider)
Improvements that would make the code better but aren't blocking.

### Good Practices
Call out things done well — reinforces good patterns.

## Memory
Update your agent memory with:
- Recurring patterns (good and bad) across reviews
- Project-specific conventions discovered
- Common mistake patterns to watch for
```

---

## 3. Creating New Subagents

### 3.1 File Format

Subagents are Markdown files with YAML frontmatter. The filename (without `.md`) becomes the agent name.

```markdown
---
name: <agent-name>
description: >
  When Claude should delegate to this agent.
  Be specific so Claude knows when to use it.
tools: <tool1>, <tool2>, ...
disallowedTools: <tool1>, <tool2>, ...
model: <haiku|sonnet|opus|inherit>
memory: <user|project|local>
permissionMode: <default|acceptEdits|dontAsk|bypassPermissions|plan>
maxTurns: <number>
---

System prompt for the subagent.
This becomes the agent's instructions.
```

### 3.2 Frontmatter Fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | ✅ | Unique identifier (lowercase, hyphens) |
| `description` | ✅ | When Claude should use this agent. Be descriptive. |
| `tools` | ❌ | Allowed tools (default: inherit all). See tool list below. |
| `disallowedTools` | ❌ | Tools to deny (removed from inherited/allowed list) |
| `model` | ❌ | Model alias (`haiku`, `sonnet`, `opus`, `fable`), a full model ID, or `inherit` (the default) |
| `memory` | ❌ | Persistent memory scope: `user` (all projects), `project` (this project), `local` (local only) |
| `permissionMode` | ❌ | `default`, `acceptEdits`, `auto`, `dontAsk`, `bypassPermissions`, or `plan`. Default: inherits from the session |
| `maxTurns` | ❌ | Max agentic turns before stopping |

> ⚠ **`tools:` and delegation.** Listing `tools:` makes the list exhaustive, and a
> teammate delivers its work only through `SendMessage` — so a definition with a
> `tools:` line and no `SendMessage` loses everything it produces. cco adds the
> coordination tools back at `cco start`, without touching your file, and tells you
> when it does; three cases it deliberately leaves to you are listed in
> [agent-teams.md §6](agent-teams.md#6-delegation-the-coordination-tools-cco-guarantees).
> The form that needs none of this is `disallowedTools:` over an inherited toolset.

Claude Code supports further fields — `skills`, `mcpServers`, `hooks`, `background`,
`effort`, `isolation`, `color`, `initialPrompt`. They work here exactly as upstream; see
the [official subagent reference](https://code.claude.com/docs/en/sub-agents) (or the
`code-claude` llms.txt mounted at `/workspace/.claude/llms/` when your project references
it) rather than a second copy of the list.

### 3.3 Available Tools

| Tool | Description |
|------|-------------|
| `Read` | Read file contents |
| `Write` | Create or overwrite files |
| `Edit` | Edit existing files |
| `Bash` | Execute shell commands (supports patterns like `Bash(npm *)`) |
| `Grep` | Search file contents |
| `Glob` | Find files by pattern |
| `WebFetch` | Fetch URL content |
| `WebSearch` | Web search |
| `Agent` | Spawn a nested subagent (legacy name: `Task`). Nesting is allowed to five levels below the main conversation; omit `Agent` from `tools`, or list it in `disallowedTools`, to prevent it |

A few tools depend on the main conversation's UI or session state and are **never**
available to a subagent even when listed in `tools`: `AskUserQuestion`, `EnterPlanMode`,
`ScheduleWakeup`, `WaitForMcpServers`, and `ExitPlanMode` unless the subagent's
`permissionMode` is `plan`.

### 3.4 Scope Placement

| Scope | Location | Effect |
|-------|----------|--------|
| Global | `~/.cco/.claude/agents/` | Available in ALL projects |
| Project | `<repo>/.cco/claude/agents/` | Available in that project only |

Project agents override global agents with the same name.

### 3.5 Memory

When `memory` is set, the agent gets a persistent directory:

| Scope | Path |
|-------|------|
| `user` | `~/.claude/agent-memory/<agent-name>/` |
| `project` | `.claude/agent-memory/<agent-name>/` |
| `local` | `.claude/agent-memory-local/<agent-name>/` |

The agent's MEMORY.md (first 200 lines) is loaded at startup. Add instructions in the system prompt to guide what the agent remembers.

> **In a cco session these are container-local.** `~/.claude/agent-memory/` is inside the
> container's home (writable, but not one of the STATE-backed paths cco persists), and the
> `project`/`local` scopes resolve relative to the session's working directory. Only
> Claude Code's **auto memory** (`~/.claude/projects/-workspace/memory/`) and the session
> transcripts are bound to machine-local STATE and survive the container — see
> [Auto memory](../../foundation/reference/context-hierarchy.md#5-auto-memory).

---

## 4. Example Subagents

These are NOT included by default but serve as templates for users.

### 4.1 Developer Agent

For projects needing a specialized implementation agent:

```markdown
---
name: developer
description: >
  Implementation specialist. Use during Implementation phase
  to write code following the approved design.
tools: Read, Write, Edit, Bash, Grep, Glob
model: inherit
memory: project
---

You are a senior developer. Implement code following the approved design.

## Guidelines
- Follow the project's coding conventions
- Write tests alongside implementation
- Commit after each logical unit of work
- If the design needs changes, stop and ask
- Run tests before committing

## Commit Format
Use conventional commits: feat:, fix:, refactor:, test:, chore:
```

### 4.2 DevOps Agent

For projects with infrastructure needs:

```markdown
---
name: devops
description: >
  Infrastructure and DevOps specialist. Use for Docker, CI/CD,
  deployment, and infrastructure configuration tasks.
tools: Read, Write, Edit, Bash, Grep, Glob
model: sonnet
memory: user
---

You are a DevOps engineer. Manage infrastructure, CI/CD, and deployment.

## Guidelines
- Use Docker and docker-compose for local infrastructure
- Follow infrastructure-as-code principles
- Document all configuration changes
- Test infrastructure changes before committing
- Use the project Docker network for service connectivity
```

### 4.3 Researcher Agent

For documentation and API research:

```markdown
---
name: researcher
description: >
  Research specialist. Use for documentation research, API exploration,
  library evaluation, and gathering external information.
tools: Read, Grep, Glob, WebFetch, WebSearch
disallowedTools: Write, Edit
model: haiku
memory: user
---

You are a research specialist. Find and summarize information.

## Guidelines
- Search documentation and official sources first
- Verify information from multiple sources
- Summarize findings clearly with source references
- Highlight breaking changes, deprecations, and gotchas
- Focus on practical, actionable information
```

---

## 5. Agent Teams Integration

When using agent teams, the lead agent can delegate to any subagent. Custom subagents integrate with teams naturally:

```
User: "Analyze the auth module, review recent changes, then implement the fix"

Lead agent:
  ├── Delegates to: analyst (explores auth module)
  ├── Delegates to: reviewer (reviews recent git changes)
  └── Synthesizes findings → presents to user
      └── After approval, lead implements or delegates to developer
```

**Best practice**: Keep subagent responsibilities distinct. Overlapping descriptions confuse the lead agent's delegation decisions.
