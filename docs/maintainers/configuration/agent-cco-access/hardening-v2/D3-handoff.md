# D3 — A1 per-command info×scope — session handoff

> **Status**: Ready to run (2026-07-08). **D1 and D2 are DONE and approved** —
> [ADR-0046](../decisions/0046-unified-cco-access-model.md) (`7706ed7`, the `(G,Pc,Po)` model)
> and [ADR-0047](../decisions/0047-config-access-enforcement.md) (`4dc6922`, the internal-store
> privilege boundary). D3 is the **third and last** design sub-phase; it runs in its own **clean
> session** and produces an **analysis + per-verb matrix the maintainer approves** before the
> implementation phase.
>
> **Master plan**: [`handoff.md`](handoff.md) — this file is the focused kickoff for D3 and does
> not replace it. The full D3 spec is [`handoff.md`](handoff.md) **§3 D3**.

---

## What D3 decides

The one job: review **every `cco` verb** against the now-fixed **model (D1)** + **enforcement
(D2)**, and replace hardcoded per-verb access levels with **gate-by-resource-area**. For each
verb, classify:

- **Info exposed** — what it reveals (and of which scope-class: current project / other projects
  / global store / internal registries).
- **Resource area(s) touched** — which of **G / Pc / Po** its *action* reads or writes
  (keyed off the ADR-0046 §7 read-visibility + write-authority tables).
- **Correct behaviour / degradation per scope** — run / scope-filtered output / refuse (exit 2)
  / host-only (exit 2) / error (exit 1).

The output is the **definitive verb classification** that feeds the shim, the **setuid helper
gate** (D2), the CLI-surface matrix, and the e2e v2 oracle.

## What D3 inherits from D1 + D2 (must honour)

- **Gate by resource area, not a fixed level** — the ADR-0046 §7 tables are the base:
  - *Read visibility*: current project ⇐ `Pc≥ro`; referenced pack/llms ⇐ `Pc≥ro`; unreferenced
    pack/llms + template/remote ⇐ `G≥ro`; other project ⇐ `Po≥ro`.
  - *Write authority*: current project `<repo>/.cco` ⇐ `Pc=rw`; other project ⇐ `Po=rw`; global
    store (packs/templates/llms, `config save`) ⇐ `G=rw`; DATA registry (`tag`, `remote add/remove`)
    ⇐ `G=rw`.
  D3 maps each verb onto these, per-invocation (not a hard-coded level list).
- **The gate lives in the setuid `cco-svc` helper (ADR-0047).** Any verb that touches the
  **internal store** (index / DATA / CACHE internals) is mediated by the privilege helper, which
  enforces `(G,Pc,Po)` from the trusted session descriptor. D3's per-verb resource-area table is
  exactly what that helper switches on. Verbs touching only **config-content** (mounted natively)
  are gated by the shim + mount flags as today. **D3 must state, per verb, which side it is on.**
- **The refusal taxonomy (R9) stands**: exit **0** success-or-degrade · exit **2** policy refusal
  (host-only *or* above-scope) · exit **1** unknown/error. Every exit-2 carries a reason.

## The exemplars D3 must nail (from §0 of the master handoff)

- **B5 — tag gating (the exemplar of "gate by resource area").** `cco tag add/remove` is gated
  today as a blanket `write:global` (`bin/cco:314` — `_op_write "tag $sub" global`). This is
  **both too strict** (can't tag the *current* project at `edit-project`) **and too loose** (can
  tag *other* projects at `edit-global`). Tags target **pack / project / template** (different
  scopes); their storage in the global DATA registry is *irrelevant* to the permission
  (`lib/tags.sh`). Fix: gate **per-invocation by the tagged resource's scope + ownership** —
  current project → `Pc`; global pack/template → `G`; other project → `Po`. Note the DATA *write*
  itself still rides the helper boundary (D2), but the *authorisation* is by the tagged resource.
- **B6 — hint invariant.** Every exit-2 refusal states its reason (host-only vs above-scope);
  exit-1 is reserved for unknown-verb/error. Assert it holds across the whole surface.
- **The `path` question.** `cco path list` exposes the STATE index (logical→host paths) — an
  internal-store read now behind the helper. Decide: keep the low-level `path` verb but **scope
  its `list` output** (current project + referenced only, host paths gated by `show_host_paths`)
  vs a dedicated agent-facing verb; `path set` stays host-only.
- **The deferred `cco sync` of divergent members (ADR-0046 §6, left open).** Re-evaluate whether
  an in-container **config-editor** session may run `cco sync` of divergent member repos (arguably
  legit for a config-focused session), now that the enforcement boundary exists. Decide univocally.
- **Coverage gaps / missing verbs** — e.g. a `cco state`? `cco whoami` completeness (does it
  report the resolved `(G,Pc,Po)` triple + which side of the boundary the session sits)?

## Read first (D3)

- [ADR-0046](../decisions/0046-unified-cco-access-model.md) **§7** (the per-tree read/write
  tables — the base D3 refines) + **§6** (multi-repo Pc + the deferred `cco sync`).
- [ADR-0047](../decisions/0047-config-access-enforcement.md) (the helper boundary the per-verb
  gate runs inside; config-content vs internal-store split).
- [`../design.md`](../design.md) §4/§5, the [CLI-surface matrix](../../../cli/reference/cli-surface-matrix.md)
  (§2 verb classification — the rows D3 updates) + [CLI environment-awareness](../../../cli/design/design-cli-environment-awareness.md).
- Code: `bin/cco` `_cco_operator_shim` (the current per-verb gating, ~248-393; the hardcoded
  level list D3 replaces), `lib/access-scope.sh` (`_env_in_scope` + scope classes), `lib/tags.sh`
  (the B5 exemplar), `lib/paths.sh` (index/`path` verbs), `lib/cmd-*.sh` (per-verb bodies).

## Decide / produce (D3)

- **The per-verb table**: every verb × {info exposed, resource area G/Pc/Po (read/write),
  internal-store vs config-content side, correct per-scope behaviour, refusal reason}. Replaces
  the shim's hardcoded per-verb levels with the resource-area derivation.
- **Confirm B5** (tag per-target gating), **B6** (hint invariant), the **`path`** decision, the
  **`cco sync`-of-divergent-members** decision, and any coverage gaps (`cco state`, `whoami`).
- **Output**: `../e2e-review/analysis/A1-command-scope-matrix.md` (the per-verb table) + the
  **pre-review fix list** (B5 tag, B6 hint, + B1–B4 from the backlog) + CLI-surface matrix row
  updates (kept ⏳ design-intent until implemented).
- **Gate**: maintainer approval; then the implementation phase.

## Working conventions (unchanged from D1/D2)

- **Living vs history** (`.claude/rules/documentation-lifecycle.md`): D3 produces an **analysis**
  (the A1 matrix) + updates **living** design/matrix docs to truth; forward-annotate superseded
  ADR text, never rewrite it. Do **not** rewrite shipped-behaviour user docs / `CLAUDE.md` ahead
  of code (see the DOC5 cutover checklist in the backlog).
- **Ground every claim in code** (`file:line`); the shim + `lib/tags.sh` + `lib/paths.sh` are the
  baseline.
- **No implementation** in the design session — produce the classification the implementer builds
  from.
- **Branch**: continue on `feat/config-access/e2e-review`. Atomic `docs(...)` commits; **push
  from the Mac**.
- **Language**: respond in Italian; write docs/comments in English (user rules).

## After D3

**Doc reconciliation sweep** (matrix, `design.md`, `design-cli-environment-awareness.md`) →
**Implementation** (per the approved ADRs, atomic commits): the `(G,Pc,Po)` resolver + mount-gen
+ shim + `project.yml` schema + granular flag (ADR-0046); the privilege boundary — `cco-svc`
uid + setuid helper + `/var/lib/cco-internal` + session descriptor (ADR-0047); the per-command
fixes from A1 (tag B5, hint B6, path, B1–B4); config-editor/tutorial preset flip (ADR-0044);
running registry (ADR-0045). Migrations + changelog; `cco build`. Then the **shipped-doc cutover**
(backlog DOC5). Finally **e2e v2** — the S1–S8 matrix as an acceptance pass, with S1/S1b as
acceptance criteria against the privilege boundary, `cco build` as launch rule 0.

## Tracking

Master item tracker: [`../e2e-review/pre-revalidation-backlog.md`](../e2e-review/pre-revalidation-backlog.md)
(M1 ✅ D1; M2 ✅ D2; **A1 = D3**). Roadmap: `docs/maintainers/roadmap.md` → "Agent ↔ cco access —
hardening v2", D3 row.
