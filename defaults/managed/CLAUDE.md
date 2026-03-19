# claude-orchestrator Framework

## Context Hierarchy
- Managed rules (this file, memory-policy.md) define framework behavior
- User rules in `.claude/rules/` define workflow, git, documentation,
  and other conventions — always check and follow them
- Project-level rules (in `/workspace/.claude/rules/`) take precedence
  over global rules for that project
- Knowledge packs provide domain-specific context on demand

## Docker Environment
- This session runs inside a Docker container managed by claude-orchestrator
- Repos are mounted at /workspace/<repo-name>/
- Docker socket is available — you can run docker and docker compose
- When starting infrastructure (postgres, redis, etc.), use the project network (cc-<project>)
- Dev servers run inside this container with ports mapped to the host

## Workspace Layout
- /workspace/ is the main working directory
- Each repo is a direct subdirectory of /workspace/
- Files at /workspace/ root are temporary (container-only, lost on exit)
- Persistent work should go in repos and be versioned with git
- /workspace/ root is NOT a mounted repository — do not write project
  files here (they are lost when the container exits)
- Write only in mounted repositories (/workspace/<repo-name>/) or
  extra mounts configured with :rw access

## Memory Policy
- A managed rule (`memory-policy.md`) defines when to use MEMORY.md vs project docs
- Memory is personal and transient — use docs for persistent project knowledge
- See `.claude/rules/memory-policy.md` for the complete policy

## Agent Teams
- The lead coordinates and delegates work to teammates
- Each teammate focuses on their specialized domain
- Use the shared task list for coordination
- Communicate relevant findings between teammates
- The lead synthesizes teammate outputs into coherent results
