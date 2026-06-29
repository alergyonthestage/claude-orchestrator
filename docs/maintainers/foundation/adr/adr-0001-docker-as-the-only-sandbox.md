# ADR-0001: Docker as the Only Sandbox

> **Status**: accepted

## Context

Claude Code offers native sandboxing (Seatbelt on macOS, bubblewrap on Linux).
We need to decide whether to layer it with Docker.

## Decision

Use Docker as the sole isolation mechanism. Disable native sandboxing.

## Rationale

- Docker provides filesystem and network isolation by design
- `--dangerously-skip-permissions` is safe within a container — the blast radius
  is the container
- Native sandboxing inside Docker requires `enableWeakerNestedSandbox`, which the
  docs explicitly state "considerably weakens security"
- No advantage in combining both; Docker alone is more secure than a weakened
  native sandbox
- Git feature branches provide an additional safety net — any damage is reversible

## Consequences

- Container must NOT be run with `--privileged`
- Docker socket mount is the only intentional privilege escalation
  (see [ADR-0004](./adr-0004-docker-from-docker-via-socket-mount.md))
