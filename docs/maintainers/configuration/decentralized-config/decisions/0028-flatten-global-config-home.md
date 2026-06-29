# ADR 0028 — Flatten the global config home: `~/.cco/global/.claude` → `~/.cco/.claude`

**Status**: Accepted (2026-06-27)
**Deciders**: maintainer (set the direction + the timing rationale), implementer (analysis + recommendations)
**Context docs**: `../design.md` §2.1/§2.3 (layout), `../flatten-global-claude-handoff.md` (the launcher),
`../../foundation/design/guiding-principles.md` (P2 destination taxonomy, P18 one config home)
**Related ADRs**: 0024 D4 (`.claude` scope placement / one config home per repo — **layout superseded
here**), 0026 (`cco init` global-ensure — **layout superseded here**), 0007/0008 (`~/.cco` personal
store), 0023 D4 (solo-adopter Case-C per-project centralization — its future home is realigned here),
0025 (eager-global migration via `cco update` — the carrier of migration 015)

---

## Context

`~/.cco` is the personal (global, user) config scope after decentralization: per-project config now
lives **in each repo** at `<repo>/.cco/`, so `~/.cco` holds *only* global resources. Yet within it,
the global Claude config tree was nested one level down under `global/`:

```
~/.cco/global/.claude/      # global Claude config (CLAUDE.md, rules, agents, skills, settings.json, mcp.json)
```

The `global/` wrapper is a **carry-over from the central-vault layout** (`user-config/global/` vs
`user-config/projects/`), where the level disambiguated global config from per-project config that
*also* lived in the central store. After decentralization that contrast moved into the filesystem
(`~/.cco` = global, `<repo>/.cco` = per-project), so the `global/` level inside `~/.cco` no longer
disambiguates anything.

Worse, it is applied **inconsistently**: only `.claude/` lives under `global/`. Every other global
resource is already top-level — `setup.sh`, `setup-build.sh`, `mcp-packages.txt`, `languages`, `packs/`,
`templates/` sit directly in `~/.cco/` (the `~/.cco/global/setup.sh` placement was already corrected to
`~/.cco/setup.sh`, commit `a92effc`). Update base/meta live in STATE. So `global/` wraps a single
member while its siblings are flat — redundant and misleading.

## Decision

**Flatten the global Claude config home to `~/.cco/.claude/`.** `~/.cco` *is* the global config scope;
`.claude/` is its global Claude config directly, with no intermediate `global/` namespace.

```
~/.cco/.claude/             # global Claude config — directly under the config home
```

The future **solo-adopter per-project centralization** (Case-C, ADR-0023 D4, P18) becomes
**`~/.cco/projects/<name>/`** — a clean sibling of `~/.cco/.claude/`. This preserves the global-vs-
per-project contrast (`~/.cco/.claude` = global, `~/.cco/projects/<name>/` = a centralized project)
**without** a redundant `global/` level for the global case.

### Scope — what changes vs what does not

| Thing | Path | Change? |
|---|---|---|
| **User-store destination** | `~/.cco/global/.claude/` → **`~/.cco/.claude/`** | **Yes — this ADR** |
| **Repo source (shipped default)** | `defaults/global/.claude/` | **No** (D1) — copied *into* the new dest |
| **Container mount target** | `→ ~/.claude` in container | unchanged target; only the host source path changes |
| setup/mcp/languages/packs/templates | `~/.cco/{setup.sh,…,packs/,templates/}` | already top-level — unchanged |
| Update base/meta | STATE (`<state>/cco/global/update/…`) | unchanged |

### Resolved sub-decisions

- **D1 — `defaults/global/` source dir: KEEP.** Destination naming ≠ source naming;
  `defaults/global/` is a fine name for "the global defaults source", and renaming it is a tracked
  tool-code move with churn and no user benefit. A cosmetic symmetry rename remains a separate,
  optional future decision.
- **D2 — retire `GLOBAL_DIR` and `CCO_GLOBAL_DIR`.** After the flatten the global Claude dir is exactly
  `$(_cco_config_dir)/.claude` — derived from `$HOME`, with no separate "global home" to parameterize.
  A new resolver `_cco_global_claude_dir()` in `lib/paths.sh` is the single source of truth; the
  `GLOBAL_DIR` bin/cco variable and the `CCO_GLOBAL_DIR` override/test seam are removed (keeping the
  seam would make it a confusing alias of the config home). Tests reference `$HOME/.cco/.claude`
  directly (`HOME` is already redirected in the test harness, so the resolver works unchanged).

## Alternatives considered

- **(a) Keep `global/` and move setup/mcp/languages under it for consistency.** Rejected: it keeps a
  level the design does not need — `~/.cco` is already the scope — and would be a *larger* breaking
  move (relocating already-correct top-level files) for negative value.
- **(b) Defer to the `~/.cco/projects/` Case-C design (post-v1).** Rejected for **timing**: v1 has not
  shipped, so there is exactly one migration window. Folding the flatten into the single
  decentralized-config v1 migration means every user gets the flat layout in **one** coherent
  migration. Deferring would ship `~/.cco/global/.claude` now and force a **second** `mv … →
  ~/.cco/.claude` on users later.
- **(c) Rename `defaults/global/` too (D1 alternative).** Rejected as default — see D1.

## Consequences

- **Breaking layout change**, absorbed by **one idempotent migration** (`migrations/global/015`) that
  rides the existing eager-global update path (ADR-0025). Entry points converge on `~/.cco/.claude`
  so no user ever needs a second move:
  - **Fresh** (`cco init`): writes straight to `~/.cco/.claude`.
  - **Legacy vault** (`cco init --migrate`): restores legacy `global/.claude` straight to `~/.cco/.claude`.
  - **Eager global** (`cco update`): migration 015 moves a pre-flatten dev build's `~/.cco/global/.claude`.
  - **Dispatch-time bootstrap** (any command): `_cco_first_run` self-heals a pre-flatten layout
    before `check_global` and any global-config reader runs.
- **Bootstrap self-heal (added after dogfooding; resolves a gate-ordering bug).** `check_global` now
  tests the *flat* `~/.cco/.claude`, but a pre-flatten user only has `~/.cco/global/.claude` — so the
  pre-condition check would die ("run `cco init`") **before** migration 015 (or any reader) could see
  the config, locking pre-flatten users out of the very command (`cco update`) meant to migrate them.
  The move is therefore a **single shared helper** (`_cco_flatten_global_claude`, `lib/migrate.sh`)
  invoked from **both** migration 015 (the schema-version record, 14 → 15) **and** the dispatch-time
  bootstrap `_cco_first_run` (host-side, idempotent, runs on every command after the four-root
  bootstrap). Migration 015 stays as the formal breaking-change record per the update-system rule.
- All readers and writers of the destination are repointed; `defaults/global/.claude` (the source) is
  left untouched.
- **No `changelog.yml` entry** — this is a structural move handled by a migration, not an additive
  feature (per `.claude/rules/update-system.md`).
- The personal-store `.gitignore` allowlist drops `global/.claude` in favour of `.claude`.

## Supersedes / forward-annotations

- **Supersedes** the `~/.cco/global/.claude` placement in **ADR-0024** (the `.claude` scope table /
  config-home rows) and **ADR-0026** (init global-ensure). Their decision bodies are **history** and
  are **not** rewritten — each gets a one-line forward pointer to this ADR (documentation-lifecycle).
- Foundation ADRs that mention the old layout in passing (`adr-0003`, `adr-0006`, `adr-0007`,
  `adr-0008`) get the layout line annotated only.
