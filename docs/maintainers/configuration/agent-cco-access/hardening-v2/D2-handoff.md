# D2 — Enforcement architecture — session handoff

> **Status**: ✅ **DONE + approved (2026-07-08)** — [ADR-0047](../decisions/0047-config-access-enforcement.md)
> (`4dc6922`). Outcome: **not** the broker this kickoff targeted — an empirical test of macOS
> Docker Desktop bind mounts (`fakeowner`) showed a lighter, coherent path: confine only the
> **internal store** behind a **privilege boundary** (dedicated `cco-svc` mode-0700 real-FS
> parent + setuid helper enforcing `(G,Pc,Po)`), no daemon/protocol. See ADR-0047 §Alternatives
> for why A (ro projection) and B (socket broker) were rejected/kept-as-fallback. **D3 is next.**
> The original kickoff brief is preserved below for context.
>
> **D1 is DONE and approved** — [ADR-0046](../decisions/0046-unified-cco-access-model.md)
> (`7706ed7`). D2 was the **second** of the three sequential design sub-phases.
>
> **Master plan**: [`handoff.md`](handoff.md) — this file is the focused kickoff for D2 and
> does not replace it. The full D2 spec is [`handoff.md`](handoff.md) **§3 D2** + the security
> findings + mount inventory in **§0**.

---

## What D2 decides

The one job: decide **how the `(G, Pc, Po)` model (D1) is *physically* enforced** so the
confidentiality bypass **S1/S1b is closed**. Deep-analyse two options and produce an ADR with a
recommendation + effort call + interim/migration path.

- **Option B — cco config broker (target).** Buckets live **outside** the container; in-container
  `cco` is a **thin client** to a scope-enforcing broker over a socket, **mirroring the already
  validated `cco-docker-proxy`**. Closes the leak, supports **granular writes** that persist
  host-side, and becomes the **single enforcement point** for the D1 model + the D3 per-command
  gating.
- **Option A — physical scoped mounts.** The lighter alternative; weigh effort vs its limits on
  shared single-file registries (index / `tags.yml` / remotes).

Revise **ADR-0043 INV-D** ("index stays complete; scoping is a presentation filter") — the
bypass is the evidence that a presentation-only filter is insufficient.

## The bug D2 must close (from §0 of the master handoff)

**Verdict: integrity is safe, confidentiality is bypassable.** Edit-gating is enforced
physically by ro/rw bind mounts (safe). But:

- **S1 — cross-scope info leak (CONFIRMED, by design).** The STATE **index** (whole, `:ro`,
  every level ≥ read — `cmd-start.sh:1090-1091`) and the whole **DATA** bucket (tags,
  de-tokenized remotes/URLs, per-resource `source` provenance — `:1087-1088`) mount **outside**
  the read-project narrowing branch. `access-scope.sh` filters only command **output**, not the
  raw files. At read-project an agent can `cat` the mounted index/DATA and enumerate **every
  other project's name, host path, membership, tags, remote URLs**.
- **S1b — `show_host_paths` bypass (CONFIRMED).** Host paths in the mounted index are readable
  even at `show_host_paths=off`. Same root.
- **Root cause**: the agent and the wrapped `cco` run as the **same UID (`claude`)** with **no
  FS confinement** — any file `cco` can read, the agent can `cat`. A "mount-outside / CLI-only"
  guarantee needs a **process/privilege boundary that does not exist today**. The
  `cco-docker-proxy` (entrypoint.sh:49 — "the claude user can never access the unfiltered
  socket") is the **precedent** for the broker.

The **mount inventory (per bucket × level)** is in [`handoff.md`](handoff.md) §0 — the baseline
for D2's analysis.

## What D2 inherits from D1 (must honour)

- **The triple `(G, Pc, Po)` is what the enforcement layer enforces.** D1 (ADR-0046 §7) fixed
  the **model**: read-visibility per kind + write-authority per tree derive from the axes. D2
  decides the **mechanism** that makes the triple bind the **raw filesystem**, not just the CLI
  output. ADR-0046 §Consequences explicitly leaves this open: *"the triple binds the CLI
  surface, not the raw filesystem — D2 makes it physically binding."*
- **Granular writes persist host-side.** The broker/mounts must support the per-tree write model
  (Pc / Po / G each independently rw) — e.g. case 6 `(ro,rw,rw)`: write all project configs but
  **not** the global store; case 7 `(rw,ro,ro)`: write the store, other projects read-only.
- **Referenced-subset invariant.** `~/.cco` is always in-scope for the project's referenced
  packs/llms even at `G=none`; whatever D2 chooses must still surface that subset while hiding
  the rest of the store (today done by the read-project mount narrowing,
  `cmd-start.sh:1054-1072`).
- **Multi-repo Pc** (ADR-0046 §6): `include_member_configs` may extend Pc across member repos —
  the enforcement must span multiple `<repo>/.cco` trees when set.

## Read first (D2)

- [ADR-0046](../decisions/0046-unified-cco-access-model.md) — the model D2 enforces (esp. §7
  resolver + §Consequences enforcement-gap).
- [`handoff.md`](handoff.md) §0 (security findings + mount inventory) + §3 D2 (the spec).
- [`security/design/design-socket-proxy.md`](../../../security/design/design-socket-proxy.md) +
  [`environment/design/design-docker.md`](../../../environment/design/design-docker.md) — **the
  broker precedent.**
- `proxy/` (Go proxy — the broker template), `config/entrypoint.sh` (gosu/user model — the
  same-UID root cause), `lib/cmd-start.sh` mount block (~1050-1095), `lib/access-scope.sh`.

## Decide / produce (D2)

- **B vs A** (recommendation in the master handoff: **B** — mirrors the proxy, single
  enforcement point, debt-free); the broker's protocol / scope-enforcement surface; **what stays
  mounted vs brokered**; whether a **cheap interim** ships first (e.g. a host-path-stripped index
  → closes S1b alone) before the full broker.
- **Output**: `../decisions/00NN-config-access-enforcement-broker.md` (next number after 0046 →
  **0047**; may instead live under `../../../security/decisions/`) + **revise ADR-0043 INV-D** +
  a note in `design-docker.md`.
- **Gate**: maintainer approval before D3/impl.

## Working conventions (unchanged from D1)

- **Living vs history** (`.claude/rules/documentation-lifecycle.md`): D2 writes an **ADR**
  (history — forward-annotate ADR-0043 INV-D) and updates **living** design docs to truth. Do
  **not** rewrite shipped-behaviour user docs / `CLAUDE.md` ahead of code.
- **Ground every claim in code** (`file:line`); the mount inventory (§0) is the baseline.
- **No implementation** in the design session — produce design-intent the implementer builds
  from.
- **Branch**: continue on `feat/config-access/e2e-review` (where the whole hardening-v2 lineage —
  ADR-0044/0045/0046, handoff, matrix — lives). Atomic `docs(...)` commits; **push from the
  Mac**.
- **Language**: respond in Italian; write docs/comments in English (user rules).

## After D2

**D3 — A1 per-command info×scope** ([`handoff.md`](handoff.md) §3 D3): classify every verb by
the resource area it touches, keyed off the ADR-0046 §7 per-tree write table; confirm the **tag**
gating fix (B5), the **hint invariant** (B6), the **path** decision, and **re-evaluate the
deferred in-container `cco sync` of divergent members** (ADR-0046 §6). Then doc reconciliation →
implementation → e2e v2.

## Tracking

Master item tracker: [`../e2e-review/pre-revalidation-backlog.md`](../e2e-review/pre-revalidation-backlog.md)
(M1 ✅ done; **M2 = D2**). Roadmap: `docs/maintainers/roadmap.md` → "Agent ↔ cco access —
hardening v2", D2 row.
