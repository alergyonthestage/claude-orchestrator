# ADR-0002: Workspace Layout — Flat Subdirectories

> **Status**: accepted

## Context

Claude Code has one working directory. Multi-repo projects need a strategy.

## Decision

WORKDIR = `/workspace`. Each repo is mounted as a direct subdirectory.

```
/workspace/              ← cwd, project-level .claude/ lives here
├── repo-alpha/          ← volume mount of real repo
│   └── .claude/         ← repo's own context (included in mount)
└── repo-beta/
    └── .claude/
```

## Rationale

- Claude Code discovers CLAUDE.md files recursively in subtrees — nested
  `.claude/` directories are loaded on-demand when Claude reads files there
- No `--add-dir` needed, no `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` needed
- Clean hierarchy: `/workspace/.claude/CLAUDE.md` is project-level, subdirectories
  are repo-level
- Matches Claude Code's natural resolution order

## Consequences

- All repos appear as subdirectories of `/workspace`
- The project CLAUDE.md at `/workspace/.claude/CLAUDE.md` is the primary
  instruction file
- Repo CLAUDE.md files activate only when Claude reads files in that repo's
  directory
