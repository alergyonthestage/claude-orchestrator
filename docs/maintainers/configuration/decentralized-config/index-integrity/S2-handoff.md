# S2 handoff — Reconcile + residue (WS-2 + WS-3)

**Read this first, then `00-plan.md` §WS-2/§WS-3 for the full spec.** This handoff carries the
*starting context* + the *S1-derived guidance* that the original plan could not know. Retire it once
S2 lands.

## Where we are

- **Branch**: `feat/index/integrity-hardening` (from `develop`). **Decision**: [ADR-0052](../decisions/0052-index-integrity-version-gate-and-reconcile.md).
- **S1 (WS-1) is DONE + reviewed + hardened.** Commits on the branch:
  - `93b3354` — fail-loud version gate + `CCO_INDEX_VERSION` constant + `_cco_in_container==0`.
  - `58d1eb0` — WS-1 row flip + baseline correction.
  - `8811108` — **review fix**: the gate now fails *honestly* on unreadable/malformed state (see the lesson below).
  - `37e20f7` — docs/roadmap sync.
- **Suite baseline: `1481/7` in-container** (the 7 are pre-existing host-only FI-19 artifacts: 6 in
  `test_access_scope`, 1 `test_paths_symlink_safe_tool_root` — NOT ours; the earlier "1463/9" note was
  stale, same 1472 total). Keep it at `1481/7 + S2's new tests`.
- **Working-tree hygiene**: `.cco/project.yml` is modified by the MAINTAINER (FI-25) — **never stage it**.
  `tmp` and `to-verify-guides-docs.md` are untracked scratch — leave them out. Stage only S2's files.

## What S1 leaves for S2 to consume

- `CCO_INDEX_VERSION` (single source, `lib/index.sh`) + `_latest_index_version()`.
- `_index_read_state` (`lib/index.sh:118`) — the readability classifier `absent|ok|unreadable|truncated|stale`,
  and `_index_unreadable_sentence` for the honest message. **The reconcile MUST use these** (see lesson).
- The `_cco_first_run` ordering (`lib/migrate.sh`): `_cco_bootstrap_roots` → `_cco_version_gate` →
  *(reconcile goes HERE)* → `_cco_flatten_global_claude` → `_cco_backup_legacy_vault`.

## ⚠ The S1 lesson that MUST shape the WS-2 reconcile

> **Never TRUST a file you could not cleanly read.** S1's review found that wiring a reader into
> `first_run` makes it run on *every* host command, so a lenient reader that (a) crashes raw under
> `set -e` or (b) silently coerces an unreadable file to a benign default becomes a universal defect.

The reconcile reads TWO files — the **legacy** `$(_cco_state_dir)/index` (v1) and the **new**
`_index_file` = `$(_cco_state_shared_dir)/index` (v2). Apply the same discipline:

- Probe each by **opening** (never `test -r` — access(2) lies under elevation), classify with
  `_index_read_state` (new) and an equivalent probe for the legacy file.
- **A file that exists but is unreadable/truncated/stale → `die` honestly**, do NOT treat it as "absent"
  and silently `mv`/merge/skip. Losing an unreadable legacy index by mis-classifying it as empty would
  be N1 all over again in a new spelling.
- Only `absent` is benign.

## WS-2 — non-destructive reconcile (closes N1 + N2)

New host-only `_index_reconcile_legacy_location()` in `lib/index.sh`, guarded `! _cco_container_operator || return 0`
(under the ADR-0047 boundary the legacy path is not even mounted in a session).

```mermaid
flowchart TD
  S{legacy state}
  S -->|absent| Z[no-op]
  S -->|"present, new absent"| MV[mv legacy → new  ·  the benign case]
  S -->|both present| M{merge, per (project,name)}
  M -->|new lacks it| AD[adopt legacy binding]
  M -->|paths agree| SK[skip]
  M -->|"path conflict (same key, diff path)"| C{TTY?}
  C -->|yes| PR["prompt: keep-legacy / keep-new"]
  C -->|no| KB["keep BOTH files + warn · do NOT delete legacy"]
  AD --> R[remove legacy only after a FULLY-resolved merge]
  SK --> R
```

- The legacy is v1-schema **and** old-location, so the merge must **relocate + v1→v2 re-home + merge**
  atomically (ADR-0052 §2). Re-home each legacy entry through the SAME logic as `_index_migrate_v1_to_v2`'s
  consume loop — **factor that re-homing into a shared helper** (WS-3 wants it too).
- Reuse the atomic writers `_index_pp_set` / `_index_set_unscoped` so INV-IDX (every index write is
  mktemp+mv, status propagated) holds. Optional `.bak` of legacy before removal (a safety net, not the
  contract).
- **Wire it from two sites** so both upgrade orderings are safe:
  1. `_cco_first_run` — after `_cco_version_gate`, before `_cco_flatten_global_claude` (closes **N2**;
     idempotent → cheap `[[ -f legacy ]]` no-op once merged).
  2. `migrations/global/017_state_shared_subbucket.sh` **index arm (line ~46-51)** — replace the
     `rm -f "$state/index"` "new wins" branch (line 49) with a call to the reconcile (closes **N1**).
     Keep the pack/template sidecar arms of 017 unchanged.

## WS-3 — in-index residue absorption

Extend `_index_migrate_if_needed` (`lib/index.sh:229`): today it fires only when `version < 2`. Also fire
when the file is `version: 2` **but** carries a non-empty legacy `paths:` section (a residue an older
binary wrote by misreading the v2 file as empty). Fold the residue into `project_paths:`/`unscoped:` via
the **shared re-homing helper** (the one factored out in WS-2), then drop `paths:`. A clean v2 file is
left untouched (no spurious rewrite).

## Session ritual (same as every cluster session)

1. **Design micro-pass**: verify against the ADRs below + a correctness review of the current tree
   *before* touching code. Re-read the WS-2/WS-3 spec in `00-plan.md` and the code at the anchors (line
   numbers drift — anchor on function names).
2. Implement WS-2, then WS-3 (both touch `lib/index.sh`'s migration path — land WS-2 first to avoid churn).
3. Tests green: **`1481/7` + new** (`bin/test`; the 7 are the known host-only FI-19 — confirm the FAIL
   names are unchanged, never assume).
4. Atomic commit(s) + flip the WS-2/WS-3 rows in `00-plan.md`.
5. **Do NOT auto-advance to S3** — the maintainer launches each session explicitly.

**Verify S2 against**: ADR-0052 §2/§3; ADR-0051 D6 (v1→v2 losslessness); ADR-0017 D2 (non-destructive
scan / no-prune); ADR-0047 (host-only — legacy path never mounts).

## Tests to add (WS-2/WS-3)

- `tests/test_index_reconcile.sh` — both-exist disjoint → union; overlapping same path → deduped;
  overlapping different path, no-TTY → **both files kept + warn + legacy NOT deleted**; legacy-only → moved;
  idempotent second run → no-op; **legacy unreadable → die honestly, legacy NOT touched** (the S1 lesson).
- `tests/test_index.sh` — a hand-built v2 file with a stray `paths:` entry is absorbed on the next write;
  a clean v2 file is not spuriously rewritten.
- Confirm `test_migrate*.sh` no longer asserts any "new wins" destruction (update if it does).

## Self-dev caveats & host gates

- **`lib/` edits are invisible to store-touching verbs in-session** (they run the image-baked cco) until
  `cco build`. The hermetic suite exercises `lib/` directly, so unit/integration tests are the in-session
  signal; **live dogfood of the reconcile is a host / post-build gate.**
- Host gates after the WHOLE cluster (S4), from the Mac: `cco build` + dogfood the 0.5.2→develop reconcile
  (start-before-update ordering + the both-present merge), host suite clean 0-failure, push both branches +
  merge → develop (host-only per FI-20). Only then resume e2e-review v3.1.

## Launch pointer

> *"Esegui Sessione 2 del piano index-integrity (roadmap §Index-integrity; ADR-0052 §2/§3; 00-plan WS-2+3;
> S2-handoff.md): design+verifica-ADR/correttezza → implementa WS-2 reconcile poi WS-3 residue → test
> 1481/7+nuovi → commit atomico + flip WS rows."*
