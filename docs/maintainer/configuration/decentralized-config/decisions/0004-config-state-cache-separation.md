# ADR 0004 — Config / State / Cache Separation by Location

**Status**: Accepted (2026-06-15)
**Deciders**: maintainer + design session
**Context docs**: `../requirements.md` (AD9, FR-S), `../design.md` §2
**Related ADRs**: 0001 (decentralization), 0002 (machine-agnostic config)

---

## Context

In the vault and the initial decentralized draft, a project's `.cco/` mixed three kinds
of data: committed user config, machine/runtime **state** (generated compose,
claude-state, temp, the local-path map), and **cache** (llms, installed resources).
The draft protected this with a blanket-gitignore of `state/` + `secrets/` inside the
repo. That works but keeps un-committable, regenerable, and secret data physically
inside the repo, where it can be accidentally staged, edited, or deleted, and where it
clutters the committed tree and the `git diff` signal.

## Decision

Separate the three concerns **by location**:

1. **Committed `<repo>/.cco/`** holds **only** machine-agnostic user config
   (`project.yml`, `secrets.env.example`, `claude/**`).
2. **Machine/runtime state** (generated `docker-compose.yml`, claude-state, `.tmp/`,
   meta, and the local-path index of ADR-0002) lives in **system directories outside
   the repo**, per-machine, hidden from the user.
3. **Cache** (llms, installed Config-Repo resources) lives in a system cache dir.
4. **`secrets.env` is the one in-repo exception**: it is a project config file the
   user edits by hand, so it stays in `<repo>/.cco/` but is **gitignored**. The
   committed `secrets.env.example` documents required vars; the secret-scan exempts
   `*.example` from the content check and keeps the example stageable.

## Alternatives Considered

| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Everything under `.cco/` with blanket-gitignore `state/`+`secrets/`** | Co-located; one dir to find | Un-committable + regenerable + secret data sit inside the repo (accidental stage/edit/delete; cluttered tree); structural secret risk relies on a gitignore line | Rejected |
| **State in repo, cache in system dir** | Partial cleanup | Still keeps machine state in the repo; inconsistent split | Rejected |
| **State + cache in system dirs; only config + `secrets.env` in repo (chosen)** | Repo holds only clean, committable config; state is structurally un-committable; protected from accidental edits; truthful, small `git diff` | State not co-located with the repo (acceptable — it is machine data the user should not touch); needs a per-OS location decision | **Accepted** |

## Consequences

**Positive** — the committed `.cco/` is small and clean; runtime state cannot be
committed by construction (no secret can land in a committed state dir); state is
protected from accidental edits/deletion; the `git diff` signal reflects only real
config changes.

**Negative** — machine state is not co-located with the repo (a per-OS system path
must be chosen and documented); `secrets.env` remains the single in-repo gitignored
exception (justified: it is user-edited project config, not runtime state).

## Open
~~RD-paths (exact system-dir locations for state/cache/index on macOS & Linux).~~
**Resolved 2026-06-16 by ADR-0007**: XDG layout on both OSes — STATE
`$CCO_STATE_HOME` → `$XDG_STATE_HOME/cco` → `~/.local/state/cco`; CACHE
`$CCO_CACHE_HOME` → `$XDG_CACHE_HOME/cco` → `~/.cache/cco`. Config personal store
keeps the `~/.cco` dotdir.
