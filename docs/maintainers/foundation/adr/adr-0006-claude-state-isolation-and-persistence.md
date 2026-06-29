# ADR-0006: Claude State Isolation and Persistence

> **Status**: accepted

> **Forward note (decentralized-config ADR-0028, 2026-06-27):** the global config home is now
> **`~/.cco/.claude/`** — read the `~/.cco/global/.claude/` mount source below as `~/.cco/.claude/`.

> Updated by the decentralized-config model (decentralized-config ADR-0009). See
> the decentralized-config decisions tree for the cross-machine state-sync design.

## Context

Claude Code stores auto memory and session transcripts at
`~/.claude/projects/<project>/`. Since we mount `~/.cco/global/.claude/` to
`~/.claude/`, all projects would share the same state location. Additionally, the
ephemeral container (`--rm`) loses all in-container data on exit, including session
transcripts needed for `/resume`.

## Decision

Auto memory and session transcripts are **machine-local STATE**
(decentralized-config ADR-0009), not config. They are **never** committed to a repo
and **not synced across machines in v1**. Both live in the per-machine STATE
bucket, keyed by the project identity `<id>` (the `project.yml` `name`), and are
mounted to the appropriate paths inside the container.

```yaml
volumes:
  # Session transcripts (STATE — large, transient)
  - <state>/cco/projects/<id>/claude-state:/home/claude/.claude/projects/-workspace
  # Auto memory (STATE — small, valuable, machine-local)
  - <state>/cco/projects/<id>/session/memory:/home/claude/.claude/projects/-workspace/memory
```

Host sources are **host-absolute**, resolved by `cco start` from the STATE bucket
(`$CCO_STATE_HOME` → `$XDG_STATE_HOME/cco` → `~/.local/state/cco`). The identifier
`-workspace` comes from Claude Code encoding the absolute working directory path by
replacing each `/` with `-`. Since WORKDIR is `/workspace`, the encoded identifier
is `-workspace`.

The child bind mount (`memory`) shadows the `memory/` subdirectory within the
parent mount (`claude-state`). Docker's mount precedence guarantees the child mount
takes priority at runtime.

## Rationale

- Auto memory is useful and should not be disabled
- Project-specific insights should not leak across projects (separate STATE per `<id>`)
- Session transcripts (needed for `/resume`) must survive container restarts and
  image rebuilds
- Memory and transcripts are session/runtime **state**, not authored config — so
  they live in machine-local STATE, never in the committed `<repo>/.cco/` or
  `~/.cco/` trees (decentralized-config ADR-0008/0009)
- They are **not versioned and not synced cross-PC in v1**: the old vault
  auto-commit of `memory/` is removed. Cross-PC / cross-team state sync is a
  deferred opt-in feature (R-state-sync)

## Consequences

- Each project's state lives under `<state>/cco/projects/<id>/`: `claude-state/`
  (transcripts) and `session/memory/` (auto memory)
- Two Docker mounts per project, both with host-absolute STATE sources
- The mount target path depends on how Claude Code derives the project identifier
- The `/session` (opt-in future sync) vs `/update` (never-sync base/meta) split
  inside STATE is the allowlist boundary protecting any future state-sync from
  sweeping base/hashes/tokens
