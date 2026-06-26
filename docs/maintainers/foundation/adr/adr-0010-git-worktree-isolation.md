# ADR-0010: Git Worktree Isolation

> **Status**: accepted

## Context

Repos are bind-mounted directly from host to container. Host and container share
the same git state. Concurrent git operations (user on host + Claude in container)
can conflict. Users need the ability to work on a branch while Claude works on
another.

## Decision

Provide opt-in worktree isolation. When enabled (`--worktree` flag or
`worktree: true` in project.yml), repos are mounted at `/git-repos/` (hidden from
Claude) and the entrypoint creates worktrees at `/workspace/` on a dedicated branch
(`cco/<project>`).

## Rationale

- Worktrees created inside the container have consistent paths — the `.git` file
  references `/git-repos/<repo>/.git/worktrees/...` which is valid inside the
  container
- Commits are stored in the host repo's object store (via bind mount) and survive
  container stop
- Claude sees `/workspace/<repo>` as a normal repo — zero behavior change
- Branch `cco/<project>` persists on host, enabling session resume
- Default behavior (no `--worktree`) is unchanged — zero risk for existing users
- Post-session cleanup runs in `cmd_start()` after `docker compose run` returns,
  eliminating the need for `cco stop`

## Consequences

- Worktree directory is ephemeral (lost on container stop), but commits persist
- `session-context.sh` must check for `.git` as file or directory (`[ -e ]` not
  `[ -d ]`)
- Docker-compose generation has two volume modes: direct mount (default) or
  `/git-repos/` mount (worktree)
- Multiple projects cannot use `--worktree` on the same repo simultaneously with
  the same branch

## References

- **Design doc**: [design-worktree.md](../../integration/worktree/design/design-worktree.md)
- **Analysis**: [analysis-001-worktree.md](../../integration/worktree/analysis/analysis-001-worktree.md)
