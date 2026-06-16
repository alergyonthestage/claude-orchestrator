# ADR 0002 — Machine-Agnostic Committed Config & Local-Path Index

**Status**: Accepted (2026-06-15)
**Deciders**: maintainer + design session
**Context docs**: `../requirements.md` (AD3, AD5, FR-Y-A), `../design.md` §2-3
**Evidence**: `../reviews/15-06-2026-simplification-analysis.md` (Part A)
**Related ADRs**: 0001 (decentralization), 0003 (sync-as-copy)

---

## Context

In the vault, committed `project.yml` was **not** machine-neutral: real filesystem
paths (`repos[].path`, `extra_mounts[].source`) were rewritten to `@local` on save and
back to real paths on read, plus a synthetic `url:`. Because the committed file
differed from its on-disk form, a plain `git diff` was untruthful, so the vault
carried a **custom diff/save layer** (sanitize-on-save, virtual-diff, extract/restore,
pre-save backup + ERR-trap, `_normalize_committed_paths`, ghost-tempfile gitignore
patterns) purely to hide that discrepancy. Archaeology confirmed the real↔committed
delta is confined to those two `project.yml` fields — every other committed file is
byte-identical — i.e. the entire custom-diff subsystem compensates for a tiny, fixable
abstraction leak.

## Decision

Make committed config **100% machine-agnostic**:

1. `project.yml` references repos and extra mounts by **logical name** only — no real
   paths — and is **byte-identical across a project's repos**. The host repo is not
   written in the file; it is the invoking repo at runtime.
2. Real absolute paths live in a **machine-local index** (a system-dir file), keyed
   `logical-name → absolute path`, **per-machine, never committed, never synced**. The
   index also records `project → [member repo names]` and tags (it subsumes the old
   per-machine registry).
3. The index is maintained by **dedicated CLI** (`cco resolve`, `cco path set/list`,
   `cco index refresh --scan`); manual edit is an allowed-but-discouraged escape
   hatch. It stores **absolute paths**; CLI accepts cwd-relative paths and resolves
   them. A logical name maps to exactly one path per machine (uniqueness invariant).
4. Because no real path is ever written into committed files, a plain `git diff` is
   always truthful, and the custom diff/save/sanitize/virtual-diff layer is **removed**.

## Alternatives Considered

| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Keep `@local` rewrite-on-save + custom diff** | No new index | Untruthful `git diff`; the entire fragile custom-diff layer remains (opaque failures) | Rejected |
| **Commit real paths (no abstraction)** | Simplest committed model | Config not portable across machines/users; every clone breaks; huge `git diff` churn | Rejected |
| **Per-repo gitignored `local-paths.yml`** (paths beside each repo) | Local to the repo | Duplicated per repo; same name resolved repeatedly; harder fresh-machine bootstrap | Rejected |
| **Global machine-local index (chosen)** | One resolution per machine; shared across projects; rebuildable by scan; truthful `git diff` | A logical name is globally unique per machine (accepted as a cleanliness invariant) | **Accepted** |

## Consequences

**Positive** — truthful `git diff` (G8); deletes `_sanitize_project_paths`, the
resolve-rewrite, extract/restore + backup + ERR-trap, `_normalize_committed_paths`,
virtual-diff, and ghost-tempfile gitignore patterns; one shared path map; fresh-machine
bootstrap via `cco index refresh --scan` + on-demand resolution.

**Negative** — a new machine-local index to maintain (mitigated by CLI + scan
rebuild); a global per-machine uniqueness constraint on logical names.

## Open
~~RD-paths (exact system-dir location of the index).~~ **Resolved 2026-06-16 by
ADR-0007**: the index lives in STATE at `<state>/cco/index`
(`$CCO_STATE_HOME` → `$XDG_STATE_HOME/cco` → `~/.local/state/cco`). It is STATE, not
CONFIG (machine-local, non-portable, scan-rebuildable).
