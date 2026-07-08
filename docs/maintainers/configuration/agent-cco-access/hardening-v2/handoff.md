# Agent ↔ cco access — Hardening v2 design-phase handoff

> **Status**: Ready to run (2026-07-08). Drives the **definitive design pass** that must
> land (and be implemented) **before** the e2e access re-validation. The review of the
> shipped access model surfaced structural gaps (missing asymmetric permission cases; a
> confidentiality bypass) worth closing **now, before the feature is released** — to avoid
> future debt.
>
> **Nature**: analysis + design. Three **sequential** sub-phases, each in its own **clean
> session**, each producing an ADR / analysis that the **maintainer approves** before the
> next depends on it. No implementation in these sessions.
>
> **Order** (dependencies): **D1 model → D2 enforcement → D3 per-command (A1)** → doc
> reconciliation → implementation → e2e v2.
>
> **Progress**: **D1 ✅ DONE + approved (2026-07-08)** — [ADR-0046](../decisions/0046-unified-cco-access-model.md)
> (`7706ed7`; the `(G,Pc,Po)` model). **D2 is next** — focused kickoff in
> [`D2-handoff.md`](D2-handoff.md) (this file remains the full spec: §0 findings + §3 D2).

---

## 0. Ratified context (maintainer, 2026-07-07/08) — persist for every phase

These decisions are **settled**; the phases formalize them, they do not re-open them.

1. **Unified granular permission model (D1).** Replace the 6 opaque `cco_access` presets as
   the *base* model with **three explicit resource axes**, each `none | ro | rw`:
   - **G** = global store `~/.cco` (packs, templates, llms, remotes, `.claude`). Read `ro`
     at project scope = *referenced subset*; at global scope = *full*.
   - **Pc** = current project's config (`<repo>/.cco`).
   - **Po** = other projects' config.
   - **Invariants**: `rw ⇒ ro` per axis; cco enabled ⇒ `Pc ≥ ro`; `Po ≠ none ⇒ Pc ≠ none`.
   - The **6 current levels become presets (sugar)** over `(G,Pc,Po)` triples; a **granular
     form** is first-class in `project.yml` and `--cco-access` and covers the previously
     unreachable **cases 6 & 7** (edit-projects-not-global; edit-global-consult-all).
   - Coverage matrix (the 7 cases) is in the driving analysis — see §3 D1.
2. **Multi-repo `<repo>/.cco` behaviour (D1).** Default project scope = **cwd's**
   `<repo>/.cco` (authoritative = cwd/hosting repo; `--from` / starting from another repo
   switches it — Case-C already exists). **New**: a `project.yml` `access` flag (name TBD,
   e.g. `mount_all_divergent_config`) that, when enabled, makes the **project scope cover
   ALL member `<repo>/.cco`** (incl. divergent/non-synced) rw; **default = cwd only**.
   Also evaluate: may the agent run `cco sync` of divergent member repos via the wrapped
   CLI (legit under config-editor, or edit-project + the flag)? Define univocally.
3. **Enforcement architecture (D2).** The confidentiality bypass (below) **must** be
   closed. **Target = a cco config broker (option B)**: buckets live **outside the
   container**, in-container cco is a **thin client** to a scope-enforcing broker over a
   socket — **mirroring the already-validated `cco-docker-proxy`** pattern. It closes the
   leak, supports **granular writes** that persist host-side, and becomes the **single
   enforcement point** for the model (D1) and the per-command gating (D3). The lighter
   **physical scoped-mount (option A)** is the alternative to weigh (effort vs limits on
   shared single-file registries). D2 does the deep analysis + ADR + effort call.
4. **Per-command review A1 (D3).** After the model + enforcement are fixed, review **every
   verb**: info exposed, resource areas touched, behaviour per scope. The **tag bug** is
   the exemplar (blanket `write:global` is both too strict — can't tag current project at
   edit-project — and too loose — can tag *other* projects at edit-global; must gate by the
   **tagged resource's** scope/ownership per-invocation). Produces the definitive verb
   classification feeding shim + broker + the CLI-surface matrix + the e2e v2 oracle.
5. **Already-designed (implement in the fix phase, not re-decided here)**: tutorial →
   `read-all`, config-editor scope flip
   ([ADR-0044](../decisions/0044-internal-builtin-presets-and-config-editor-scope.md)); the
   running registry ([ADR-0045](../../../environment/decisions/0045-session-running-registry.md),
   DI1) + interim B4.

### Security findings (from the mount-model trace, 2026-07-08) — evidence for D2

Verdict: **integrity is safe, confidentiality is bypassable.**

- **Edit-gating — SAFE.** Enforced physically by ro/rw bind mounts, not just the shim
  (`_op_rw` `lib/cmd-start.sh:1051-1052`; `<repo>/.cco` overlay `:1166-1172`; STATE index
  hard-`ro` `:1091`). A read-* agent bypassing the shim hits a read-only FS. No write-bypass.
- **S1 — cross-scope info leak (CONFIRMED, by design).** The STATE **index** (whole,
  `:ro`, every level ≥ read — `cmd-start.sh:1090-1091`) and the whole **DATA** bucket
  (tags, **de-tokenized remotes/URLs**, per-resource `source` provenance — `:1087-1088`)
  are mounted **outside** the read-project narrowing branch. `access-scope.sh` filters only
  command **output**, not the raw files. At read-project an agent can `cat`
  `/home/claude/.local/state/cco/index` and enumerate **every other project's name, host
  path, membership, tags, remote URLs**. ADR-0043 **INV-D** ("index stays complete;
  scoping is a presentation filter") documents this as accepted — D2 must revise it.
- **S1b — `show_host_paths` bypass (CONFIRMED).** Host paths live in the mounted index and
  are readable even at `show_host_paths=off` (current project included). Same root as S1.
- **Root cause**: the agent and the wrapped `cco` run as the **same UID (`claude`)** with
  **no FS confinement** (`ln -sf … /usr/local/bin/cco` Dockerfile:150; "Docker IS the
  sandbox", `--dangerously-skip-permissions`; `WORKDIR /workspace` is only cwd). Any file
  `cco` can read, the agent can `cat`. → "mount outside /workspace / CLI-only" needs a
  **privilege/process boundary that does not exist today**. The `cco-docker-proxy`
  (entrypoint.sh:49 "the claude user can never access the unfiltered socket") is the
  **precedent** for the broker.

**Mount inventory (per bucket × level)** — reference for D2:

| Bucket (host source) | read-project | read-global | read-all | edit-project | edit-global | edit-all |
|---|---|---|---|---|---|---|
| CONFIG `~/.cco` | narrowed→ref packs, ro | whole, ro | whole, ro | narrowed→ref packs, ro | whole, **rw** | whole, **rw** |
| DATA `~/.local/share/cco` (tags, remotes, provenance) | whole, ro | whole, ro | whole, ro | whole, ro | whole, **rw** | whole, **rw** |
| STATE `index` (all projects→host paths + membership) | whole, **ro (all levels)** | ro | ro | ro | ro | ro |
| CACHE `llms` | whole, ro | ro | ro | ro | whole, rw | whole, rw |
| `<repo>/.cco` overlay | ro | ro | ro | **rw** | ro | **rw** |
| STATE `remotes-token` / transcripts / other-proj memory | **never mounted** | — | — | — | — | — |

Only CONFIG is narrowed by read scope; DATA/STATE-index/CACHE are mounted whole (the leak).
Secrets (`secrets.env`/`*.env`/`*.key`/`*.pem`) are physically masked on every config mount
(`_emit_secret_overlays` `cmd-start.sh:276-286`).

---

## 1. Reference reading (every phase reads these first)

- [`../design.md`](../design.md) — three-level model (A/B/C), INV-1..4, §8 two-regime + config-editor.
- [ADR-0036](../../decentralized-config/decisions/0036-session-config-capability-model.md) — capability knobs, D4 wrapped-cco, D8 caller-context.
- [ADR-0042](../decisions/0042-agent-cco-interaction-model.md) — three-level interaction model.
- [ADR-0043](../../../cli/decisions/0043-unified-cli-environment-access-scope.md) — output-scoping layer, scope taxonomy, **INV-A..E (INV-D is the one D2 revises)**.
- [ADR-0044](../decisions/0044-internal-builtin-presets-and-config-editor-scope.md) — internal-built-in presets + config-editor scope.
- [ADR-0045](../../../environment/decisions/0045-session-running-registry.md) — running registry (DI1).
- [CLI environment-awareness](../../../cli/design/design-cli-environment-awareness.md) + [CLI-surface matrix](../../../cli/reference/cli-surface-matrix.md) — central gate + verb surface.
- [socket-proxy design](../../../security/design/design-socket-proxy.md) + [docker design](../../../environment/design/design-docker.md) — **the broker precedent (D2)**.
- Code: `lib/access-scope.sh` (scope maps + `_env_*`), `lib/cmd-start.sh` (`_start_resolve_access`, `_start_generate_compose` mount block ~1050-1095), `bin/cco` (`_cco_operator_shim`), `lib/tags.sh`, `proxy/` (Go proxy as the broker template).

---

## 2. Cross-cutting conventions

- **Living vs history** (`.claude/rules/documentation-lifecycle.md`): each phase writes an
  **ADR** (history — new number, forward-annotate superseded ones) and updates the **living
  design** docs to truth. Do **not** rewrite shipped-behaviour user docs / `CLAUDE.md` ahead
  of code.
- **Single source** (INV-E): the `(G,Pc,Po)` resolver is the one place mount-gen, shim,
  output-scoping, and the broker read; no ad-hoc re-derivation.
- **Ground every claim** in code (`file:line`) — the mount inventory above is the baseline.
- No implementation in a design session; produce design-intent the implementer builds from.

---

## 3. Per-phase specs

### D1 — Unified permission model (foundation)

- **Goal**: an ADR for the `(G,Pc,Po)` model — axes, `none|ro|rw`, invariants, the
  preset→triple table, the granular `project.yml`/`--cco-access` syntax, the **7-case
  coverage matrix** (incl. 6 & 7), and the **multi-repo Pc** definition (§0.2: default cwd,
  the divergent-config flag, `cco sync` of divergent members). Show how
  `_cco_level_read_scope`/`_write_scope` generalize to `_cco_resolve_access → (G,Pc,Po) ×
  {read,write}` as the single source.
- **Read**: §0.1/§0.2 here + ADR-0036/0042/0043/0044, `access-scope.sh`,
  `cmd-start.sh:_start_resolve_access`.
- **Decide/produce**: preset↔granular precedence; the divergent-config flag name + exact
  semantics; whether 6/7 also get preset aliases or stay granular-only; migration/back-compat
  for the existing enum (`read`/`edit-*` aliases).
- **Output**: `../decisions/00NN-unified-cco-access-model.md` + update `design.md` §4 +
  the CLI-surface matrix §1/§5 (model recap) + forward-annotate ADR-0043 §1.
- **Gate**: maintainer approval before D2.

### D2 — Enforcement architecture (the security fix)

- **Goal**: an ADR deciding how the model is **physically enforced** so the confidentiality
  bypass (S1/S1b) is closed. Deep-analyse **option B (cco config broker)** vs **option A
  (physical scoped mounts)**: mechanism, the same-UID boundary, how each handles the shared
  single-file registries (index/`tags.yml`/remotes) and **granular writes** persisting
  host-side, effort, and the interim/migration path. Revise **ADR-0043 INV-D**.
- **Read**: §0 security findings + mount inventory, `design-socket-proxy.md`, `proxy/`,
  `cmd-start.sh` mount block, entrypoint.sh (gosu/user model).
- **Decide/produce**: B vs A (recommendation: **B**, mirrors the proxy, single enforcement
  point, debt-free); the broker's protocol/scope-enforcement surface; what stays mounted vs
  brokered; whether a cheap interim (host-path-stripped index → closes S1b) ships first.
- **Output**: `../decisions/00NN-config-access-enforcement-broker.md` (or in
  `../../../security/decisions/`) + revise ADR-0043 INV-D + note in `design-docker.md`.
- **Gate**: maintainer approval before D3/impl.

### D3 — A1: per-command info × scope analysis

- **Goal**: review **every `cco` verb** against the definitive model (D1) + enforcement
  (D2): what info it exposes, which resource areas (G/Pc/Po) its action touches, and its
  correct behaviour/degradation per scope — replacing hardcoded per-verb levels with
  **gate-by-resource-area**. Confirm the **tag** fix (per-target scope/ownership gating);
  decide the **path** question (keep low-level `path` but scope its `list` output vs a
  dedicated agent verb; `path set` host-only); flag coverage gaps / missing verbs (`cco
  state`?, `whoami` completeness); assert the **hint invariant** (every exit-2 refusal
  carries a reason: host-only *or* scope; exit-1 = unknown/error).
- **Read**: the CLI-surface matrix, `bin/cco:_cco_operator_shim`, `access-scope.sh`,
  `lib/tags.sh`, D1+D2 outputs.
- **Output**: `analysis/A1-command-scope-matrix.md` (per-verb table) + the pre-review fix
  list (tag gating **B5**, hint invariant **B6**, + B1–B4) + matrix row updates.
- **Gate**: maintainer approval; then implementation.

---

## 4. After the design phases (separate sessions)

1. **Doc reconciliation sweep** — matrix, `design.md`, ADR-0043 INV-D, `design-cli-environment-awareness.md`.
2. **Implementation** (per the approved ADRs, atomic commits): the `(G,Pc,Po)` resolver +
   mount-gen + shim + `project.yml` schema + granular flag; the broker (or scoped mounts);
   per-command fixes from A1 (tag, hint, B1–B4); config-editor/tutorial preset flip
   (ADR-0044); running registry (ADR-0045). Migrations + changelog; `cco build`.
3. **e2e re-validation v2** — the handoff (to be written after impl) runs the S1–S8 matrix
   as an **acceptance** pass against the definitive CLI-surface matrix as oracle; adds
   `cco build` as launch rule 0; turns seeds/roots + S1/S1b into acceptance criteria.

## 5. Tracking

Master item tracker: [`../e2e-review/pre-revalidation-backlog.md`](../e2e-review/pre-revalidation-backlog.md).
Roadmap entry: `docs/maintainers/roadmap.md` → "Agent ↔ cco access — hardening v2".
