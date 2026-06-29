# P1 Adherence Audit — P1→P2 Boundary (2026-06-22)

**Type**: Recurring adherence/coherence audit (light cycle), per
`../implementation-review-handoff.md`. **Read-only** — no production code, no
re-opened design. Run as the first step of the Phase-2 session (a fresh session
is more independent than the one that wrote P1).

**Scope**: the 6 Phase-1 commits `56ca45c`→`e48abdd` (cco resolve, sync-meta
fingerprint, reminder aggregator, cco sync, start reminder hook, cco project add)
and their tests. Spec side: `guiding-principles.md` P1–P17, ADR-0008/0017 D2/
0022 D2-D3/0023 D3, `design.md` §3/§4/§9 P1/§11 row 1.

```mermaid
flowchart LR
  P0["✅ P0 substrate"]
  P1["✅ P1 core local — AUDITED, conformant"]
  P2["▶ P2 migration & bootstrap"]
  P0 --> P1 --> P2
```

## Verdict

**P1 is fully conformant — 0 🔴, 0 HITL flags. Ready to launch Phase 2.**

The 6 commits advance the suite **982 → 1043 passed (+61 new tests)** while holding
the **16-failure baseline exactly unchanged** (textbook delta-green). All five 🟡
hybrid states match their Transitional Registry entries (§4 of the playbook) with
retiring phases (P3/P4/P5) still ahead — the registry needs **no update** at this
boundary.

## Findings (✅ conformant · 🟡 sanctioned hybrid)

| # | Area | Location | Class |
|---|------|----------|-------|
| F1 | `cco resolve` consolidation (cwd-first / by-name / `--scan` / `--all`) + `cco path set/list` | `cmd-resolve.sh:258–320` | ✅ |
| F2 | `--scan` non-destructive upsert (AD5 keep-existing, no `--prune`) | `cmd-resolve.sh:193–235` | ✅ |
| F3 | `--scan` binds by `git remote get-url origin` first, basename fallback | `cmd-resolve.sh:155–186` | ✅ |
| F4 | Reminder aggregator — 3 facets, always `return 0`, zero `git commit` | `reminders.sh:64–88` | ✅ |
| F5 | `cco project add` embed-at-add; `--path`→index only, never into `project.yml` (AD3/G8) | `cmd-project-add.sh:172–211` | ✅ |
| F6 | H1 — reminders after `_start_resolve_paths` | `cmd-start.sh:925–930` | ✅ |
| F7 | H1 — `_start_emit_reminders` receives already-resolved roots | `cmd-start.sh:415–425` | ✅ |
| F8 | `cco sync` never-sync exclusions (no `secrets.env`, no repo-root `.claude/`, no system dirs) | `sync-meta.sh:60–71` + `cmd-sync.sh:59–67` | ✅ |
| F9 | Index in STATE, `mktemp`+`mv` atomic, global-flat (H7) | `index.sh:32–34,82–106` | ✅ |
| F10 | Sync-meta in STATE, atomic | `sync-meta.sh:35–37,104–112` | ✅ |
| F11 | Fingerprint machine-agnostic (relative paths, sorted, content-hash) | `sync-meta.sh:76–89` | ✅ |
| F12 | `_sync_record` on each target + source-after-loop (partial failure → source unrecorded = safe) | `cmd-sync.sh:202,223` | ✅ |
| F13 | **Transitional**: Commit-A `@local`/sanitize/schema-bridge intact (dies P3/P4) | `local-paths.sh:1–251`, `cmd-start.sh:422,582,587` | 🟡 |
| F14 | **Transitional**: Commit-B dual-seed + kept `CCO_*_DIR` + vault-git mirror (dies P3/P4) | `tests/helpers.sh:75–84`, `bin/cco:36–43,100–106` | 🟡 |
| F15 | **Transitional**: legacy `cco project resolve`/`validate <name>`/`add-pack` (dies P3) | `bin/cco:200–205`, `cmd-project-query.sh:149–396` | 🟡 |
| F16–F18 | The 3 maintainer scope-forks land in design-sanctioned phases (legacy verbs→P3; D-start→P2; validate→P5/coords→P4-P5) | design §9 P3/P2/P5 | 🟡 |
| F19–F20 | Suite 1043/16; the 16 FAIL match the §4 registry exactly (8 P2 + 5 P3 + 3 P4-5); no 17th | live run | ✅ |

## Masked-assertion audit (playbook lens 6)

All 6 P1 test files (`test_resolve`, `test_sync`, `test_sync_meta`, `test_reminders`,
`test_start_reminders`, `test_project_add`) guard **every** assertion with
`… || return 1` (or the `ASSERTION FAILED` sentinel). **No masked-assertion risk** —
the HITL-1 lesson was internalized from the start.

## Nits (optional, no action required)

- **S1** — `_sync_record` source-side timing is correct (recorded post-loop so a
  partial-loop failure leaves the source unrecorded = pristine-safe) but not
  self-evident; a one-line comment above `cmd-sync.sh:223` would help the next reader.
- **S2** — `_start_emit_reminders` reads through the Commit-A schema-bridge emitter
  `_effective_repo_mounts` rather than the index directly. Intentional (the aggregator
  is built final-form and only consumes already-resolved roots, H1; the bridge dies in
  P3). Already called out at `cmd-start.sh:408–413` — awareness only.

## Loop-closure (playbook §7)

- Transitional Registry (§4): **no changes** — all hybrids current, retiring phases ahead.
- Roadmap/memory: P1→P2 boundary noted; **next = Phase 2**.
- No 🔴 to schedule; no HITL to resolve.
