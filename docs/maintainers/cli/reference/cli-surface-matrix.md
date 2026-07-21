# CLI surface matrix — command × environment × access scope

> **Status**: Approved reference (2026-07-07). The single-screen view of the whole `cco`
> verb surface: for each verb, its behaviour on the **host** vs **in-container**
> (container-operator mode), and how availability + output vary by **`cco_access`**.
>
> **Source of truth**: this table is **derived from and cross-checked against**
> `_cco_operator_shim` (`bin/cco`) — the central gate — plus the level→scope maps in
> `lib/access-scope.sh` and the scope taxonomy of
> [ADR-0043 §1](../decisions/0043-unified-cli-environment-access-scope.md). When the shim
> and this doc disagree, the shim is authoritative and this doc is the bug. `tests/test_operator_shim.sh`
> pins the classification.
>
> **Purpose**: the approved oracle for the e2e access re-validation (handoff v2) and a
> reference for any CLI change. The hardening-v2 workstream (ADR-0044 preset flip; the
> ADR-0046 `(G,Pc,Po)` model; the ADR-0047 boundary; pre-review fixes B1–B4) has **landed** —
> the former **⏳ target** flags are cleared; every row now states shipped behaviour (verify
> against the code after `cco build`, per the documentation-lifecycle rule).
>
> Related: [CLI environment-awareness](../design/design-cli-environment-awareness.md) (the
> principle + the central gate §4) · [ADR-0042](../../configuration/agent-cco-access/decisions/0042-agent-cco-interaction-model.md) · [ADR-0043](../decisions/0043-unified-cli-environment-access-scope.md) · [ADR-0044](../../configuration/agent-cco-access/decisions/0044-internal-builtin-presets-and-config-editor-scope.md) · [ADR-0046](../../configuration/agent-cco-access/decisions/0046-unified-cco-access-model.md) (`(G,Pc,Po)` model) · [ADR-0047](../../configuration/agent-cco-access/decisions/0047-config-access-enforcement.md) (enforcement) · [ADR-0048](../../configuration/agent-cco-access/decisions/0048-config-editor-min-privilege-refinement.md) (config-editor min-priv by mode)

---

## 1. Model recap (the axes)

**Two contexts** (`_cco_container_operator`, `lib/paths.sh`):
- **host** — full surface, never scoped (INV-A). No behaviour change from the human CLI.
- **in-container (operator)** — every verb passes the central gate `_cco_operator_shim`
  first (default-deny); permitted read verbs additionally have their **output** scoped.

**`cco_access` — the `(G, Pc, Po)` model** ([ADR-0046](../../configuration/agent-cco-access/decisions/0046-unified-cco-access-model.md),
supersedes the opaque level enum as the base model). Three resource axes, each on the lattice
`none < ro < rw`: **G** = global store `~/.cco` (non-referenced portion — the project's
referenced packs/llms always ride with `Pc`), **Pc** = current project config, **Po** = other
projects. Invariants: `rw⇒ro`; `Pc≥ro` while enabled; `Po≠none⇒Pc≠none`; `Po≤Pc`. Unspecified
axes auto-promote to the invariant floor. The triple is the single source consumed by
mount-gen, the shim, and output-scoping (ADR-0046 §7).

The six named levels survive as **sugar for the *symmetric* ladder** (asymmetry is
granular-only). `access.cco` accepts a scalar (preset) or a `{global,current,others}` map;
bare `read` = deprecated alias for `read-all`.

| Level (preset) | `(G, Pc, Po)` | read_scope | write_scope |
|---|---|---|---|
| none | — | — (cco refused wholesale) | — |
| read-project | `(none, ro, none)` | project | — |
| read-global | `(ro, ro, none)` | global | — |
| read-all | `(ro, ro, ro)` | all | — |
| edit-project | `(none, rw, none)` | project | project |
| edit-global | `(rw, rw, none)` | global | global **+ project** |
| edit-all | `(rw, rw, rw)` | all | all |

**Granular-only** (off the symmetric ladder — the two intents the presets cannot spell,
ADR-0046 §Intro): edit-all-projects-not-global `(none, rw, rw)`; edit-global-consult-all
`(rw, rw, ro)`. (Other valid non-preset triples exist — these are the two motivating cases.)

> **Shipped (ADR-0046).** The `(G,Pc,Po)` model + the granular syntax + `edit-global`
> redefined to `(rw, rw, none)` (global write **and** project write) are implemented
> (`_cco_preset_triple`/`_cco_resolve_access` in `lib/access-scope.sh`; requires `cco build`).
> The `read_scope`/`write_scope` columns are the derivation (`_cco_level_read_scope`/
> `_cco_level_write_scope`), symmetric on `{project, global, all}`.
>
> **Enforcement ([ADR-0047](../../configuration/agent-cco-access/decisions/0047-config-access-enforcement.md), shipped).**
> The `(G,Pc,Po)` gate is *physically* binding for the internal store (STATE index, DATA,
> CACHE internals) via a **privilege boundary** (a `cco-svc` mode-0700 real-FS parent the
> `claude` user cannot traverse + a setuid helper reading a trusted `:ro` session descriptor).
> The **output-scoping** column below is therefore **defense-in-depth**, not the confidentiality
> control (revises ADR-0043 INV-D). Config-content trees stay mounted and keep `:ro`/`:rw`
> write-gating.

**Availability is monotonic**: a verb available at level *L* is available at every level
that reads/writes at ≥ its required scope. So each verb is stated as **"available from
&lt;min level&gt;"** rather than repeating seven columns.

**Exit-code convention** (D8): `0` success or graceful degrade · `2` refused by policy
(host-only, or needs a wider scope) · `1` error (unknown verb, parse/resolve failure).

**`claude_access` — the `(Cr,Cp,Cg,Co)` model** ([ADR-0049](../../configuration/agent-cco-access/decisions/0049-claude-access-concordant-model.md))
is an **orthogonal** axis governing the `.claude` **authoring** trees (repo-native Cr,
project Cp, global Cg, other-projects Co) on the `ro<rw` lattice — **not** cco verbs. It
mirrors the cco `(G,Pc,Po)` triple; the `none|repo|all` enum is preset sugar. **Unset it
DERIVES from `cco_access`** (Cg=G, Cp=Pc, Co=Po, Cr always `ro`), so the default authoring
surface is never wider than config access — a normal session's `.claude` is **read-only by
default** (reverses ADR-0027 P17). `access.claude` (CLI / project.yml / access.yml) accepts a
scalar preset or a `{repo,current,global,others}` map, symmetric with `access.cco`. An
explicit `claude` wider than the cco-concordant default is honored with a note (never
refused). `settings.json` + a `settings.local.json` rw child overlay stay writable regardless
(functional-write floor). It does not appear in the verb rows below; see §5.

---

## 2. Verb classification (the core matrix)

Legend — **Class**: `host-only` (never in-container, exit 2) · `read:project|global`
(min read scope) · `write:project|global|all` (min write scope, gated by target tree) ·
`always` (any level once cco is enabled, i.e. ≥ read-project). **`none`**: cco is refused
wholesale in-container (exit 2, R6) — every row below is unavailable at `none`.

### 2.1 Session / lifecycle / host-tooling — host-only

| Verb | Host | In-container | Refuse |
|---|---|---|---|
| `start`, `stop`, `build`, `new` | ✅ | ❌ host-only (spawns/needs containers) | exit 2 + host hint |
| `resolve`, `sync`, `init`, `join`, `forget` | ✅ | ❌ host-only (resolves host paths) | exit 2 |
| `update`, `clean`, `chrome` | ✅ | ❌ host-only | exit 2 |
| `path set` | ✅ | ❌ host-only (index mutation) | exit 2 |
| `path list` | ✅ | ✅ **read-only listing OK** | output-scoped (current+referenced; host-path columns gated by `show_host_paths`) — a §2.2 read verb ([A1 §4.3](../../configuration/agent-cco-access/e2e-review/analysis/A1-command-scope-matrix.md)) |

### 2.2 Read / introspection — available from read-project (unless noted)

| Verb | Class | In-container | Output scoping |
|---|---|---|---|
| `list` (unified) | read:project | ✅ from read-project | scoped per kind (§3); count-only stderr notice when filtered |
| `list projects\|packs\|llms` | read:project | ✅ from read-project | project-class (§3) |
| `list templates\|remotes` | read:**global** | ✅ from **read-global** | global-class — empty+notice below read-global |
| `docs` | always | ✅ from read-project | — (refused at `none`, R6) |
| `help`, `--help`/`-h`, `--version`/`-v` | always | ✅ | help is scope-aware (§4) |
| `whoami` | always | ✅ from read-project | session-state introspection (F4); listed in in-container `help` (B1). **Identity-first layout (R1)**: a `Session` block (identity / editing target / code repos) precedes `Access`, so config-editor's synthetic envelope vs its editing targets and whether code repos are mounted are explicit. **Deduplicated access (R2)**: `level` names the PRESET (else `custom (global=…)` carrying the granular form once) and `triple` is the explicit `(G,Pc,Po)` + read/write scope — no byte-identical rows; privilege-boundary note retained ([A1 §4.5](../../configuration/agent-cco-access/e2e-review/analysis/A1-command-scope-matrix.md)) |
| `project show\|validate\|coords` | read:project | ✅ from read-project | bare `project show` at the `/workspace` WORKDIR root resolves the **session project** (`PROJECT_NAME` → flat `/workspace/project.yml`), so cwd-based introspection works from the root as inside a mounted repo dir (**R4**; child-wins: a repo-local `.cco` takes precedence) |
| `pack show\|validate`, `llms show\|validate` | read:project | ✅ from read-project | `_env_require_visible` — graceful "not in scope" for out-of-scope names |
| `template show\|validate` | read:**global** | ✅ from **read-global** | global-class |
| `remote list` | read:**global** | ✅ from **read-global** | global-class |
| `config` (bare), `tag` (bare), `pack\|template\|llms\|project` (bare) | always | ✅ prints sub-usage | — |

### 2.3 Write — available from the matching edit level (gated by target tree)

| Verb | Class (target tree) | Available from | Notes |
|---|---|---|---|
| `tag add\|remove` | write:global (DATA registry) | by target axis | gated by the **tagged resource's axis** (B5): project(current)→`Pc` (edit-project), pack/template→`G` (edit-global), project(other)→`Po` (edit-all). Ownership predicate is config-editor-aware (`_env_is_current_project`) ([A1 §4.1](../../configuration/agent-cco-access/e2e-review/analysis/A1-command-scope-matrix.md)) |
| `config save` | write:global (`~/.cco`) | edit-global | clear "needs edit-global" msg on ro mount at edit-project (CLI-surface F3) |
| `remote add` | write:global (DATA registry) | edit-global | DATA-only, so it stays in-container. `remote add --token` refuses the **token half** (secret stays host-side) |
| `pack create\|update\|remove\|install\|import\|internalize\|rename` | write:global | edit-global | network fetches (`install\|update\|import`) are writes, allowed at edit level (D4 carve-out) |
| `template create\|update\|remove\|install\|import\|internalize\|rename` | write:global | edit-global | same carve-out |
| `llms create\|update\|remove\|install\|import\|internalize\|rename` | write:global | edit-global | same carve-out |

> **No project-tree writes exist as wrapped verbs.** Editing a `<repo>/.cco/project.yml`
> in an edit-project session is done by writing the **mounted file directly** (rw mount),
> not via a `cco` write verb; the shim's `write:project` gate exists for completeness /
> future verbs. The managed rule `cco-config-interaction.md` governs the edit safety.

### 2.4 Host-only writes / network-credential / removed

| Verb | Host | In-container | Refuse |
|---|---|---|---|
| `config validate` | ✅ | ❌ host-only (sweeps machine-local STATE; leaks host paths in-container) | exit 2 |
| `config push`, `config pull` | ✅ | ❌ host-only (network + credentials) | exit 2 |
| `remote set-token`, `remote remove-token` | ✅ | ❌ host-only (secrets off the container) | exit 2 |
| `remote remove`, `remote rename` | ✅ | ❌ host-only (**D-V3-1**) | exit 2 |
| `pack\|template publish\|export`, `project export\|import\|add` | ✅ | ❌ host-only | exit 2 |
| `project rename` | ✅ | ❌ host-only (re-keys machine-local state) | exit 2 |
| `pack\|template\|project list` (old subcommand) | (redirect) | ❌ → "use `cco list <kind>`" (ADR-0029) | exit 2 |
| `share`, `manifest` | ❌ removed | ❌ removed | exit 2 |
| unknown top-level verb | error | error ("Run `cco help`") — **not** a host-only misfire | exit 1 |
| `<cmd> --help` / `-h` | ✅ | ✅ **always** (informational, even for host-only verbs) | — |

> **D-V3-1 (e2e v3 cycle-1.1, 2026-07-21)** — why `remote remove|rename` moved here from §2.3.
> They cascade into the **0600 token store**, which deliberately never crosses into a session (it
> is outside the `state/cco/shared/` allow-list). The decisive argument is not confidentiality but
> honesty: with the token file unmounted, `remote_get_token` cannot distinguish *"no token"* from
> *"token invisible"*, and both ops are written as conditional no-ops on exactly that test — so
> in-container they would have **succeeded silently** while `remote-rekey` orphaned the token and
> stripped the renamed remote's auth, with no diagnostic. `remote add` stays available: it writes
> only the url registry (DATA), never the token. Design:
> [`fix-design-v3/00-plan.md`](../../configuration/agent-cco-access/e2e-review/fix-design-v3/00-plan.md) §6.

---

## 3. Output scoping — what a *permitted* read verb shows (ADR-0043)

Verb gating (§2) decides *whether* a read verb runs; this decides *what it shows*. Engages
**only** in-container (INV-A). Hidden ≠ absent → one count-only stderr notice (INV-B/C).

| Kind | Scope class | read-project | read-global | read-all |
|---|---|---|---|---|
| project (other than current) | project | current only (`PROJECT_NAME`) | current only | **all** |
| pack | project | referenced by current project | all | all |
| llms | project | referenced by current project | all | all |
| template | global | **none** (needs read-global+) | all | all |
| remote | global | **none** (needs read-global+) | all | all |

The **only** global-vs-all difference is the `project` kind (other projects need
`read-all`). `edit-*` levels read at their matching scope (edit-project → project, etc.).

**B3 (shipped)**: the unified `cco list` shows **running status** for the `project` kind
in a dedicated STATUS column (with `--sort status`), not only `cco list project`. **B4
(shipped)**: in-container, running status for a project **not visible to the scoped docker
daemon** / absent from the registry is reported `unknown`, never a false `stopped`;
cross-project running awareness comes from the STATE running registry
([ADR-0045](../../environment/decisions/0045-session-running-registry.md), DI1), gated by
this same scope layer.

**R3 (shipped)**: the reserved internal built-ins (`config-editor`, `tutorial`) surface as
KIND `builtin` with the same STATUS column, probed by their fixed non-secret names via the
running registry (no dir enumeration → the ADR-0047 boundary holds). They are **running-only
by default** (clean list) and **all-with-status** under `--include-internal` / `cco list
builtin`; being framework sessions (not the user's config), they are never scope-hidden and
never tagged.

---

## 4. Help scope-awareness (D7)

| Invocation | Host | In-container |
|---|---|---|
| `cco help` / `cco --help` | full, unannotated | **filtered** to verbs runnable at the current scope; host-only + above-level omitted; one-line warn "N hidden — `cco --help --host`"; `whoami` listed (B1); a section header with zero runnable verbs is suppressed (B2) |
| `cco --help --host` (in-container) | — | full list, host-only verbs flagged `(host only — run on your host)` |
| `cco <cmd> --help` | full usage | **always** available (informational), even for host-only verbs |

---

## 5. Preset defaults (built-ins) & the orthogonal `claude_access`

**Preset defaults** (`_start_resolve_access`, `lib/cmd-start.sh`) — resolution precedence:
CLI flag > `project.yml access:` > `~/.cco/access.yml` > preset. Each `cco_access` value below
is a named ladder preset that resolves to a `(G,Pc,Po)` triple (§1); the same field also
accepts the granular `{global,current,others}` map (ADR-0046 §5) for asymmetric intents.

`claude_access` below is the resolved `(Cr,Cp,Cg,Co)` triple; when unset it **derives** from
the `cco_access` triple (ADR-0049 §2), so the built-ins' claude columns are a *consequence* of
their cco intent, not a bespoke rule.

| Preset | claude_access `(Cr,Cp,Cg,Co)` | cco_access | show_host_paths | Notes |
|---|---|---|---|---|
| standard project | derived **`(ro,ro,ro,ro)`** = `none` | **read-project** | on | uniform minimum-privilege; `.claude` **read-only by default** (reverses P17). `--claude-access repo` re-opens local authoring |
| **tutorial** | derived **`(ro,ro,ro,ro)`** = `none` | **read-all** | on | ADR-0044: read-only teacher → full context, no write risk. `--cco-access` discouraged |
| **config-editor** (cwd in a project / `--project`) | derived **`(ro,rw,ro,ro)`** | **`(ro,rw,none)`** | on | ADR-0048 (WS-A): min-priv by mode — edits the target project's `.cco` + its repos, **reads** the store (`~/.cco` ro). Cp=rw authors the target's `.claude`; global stays ro. Writing the store is the explicit `--cco-access edit-global`. *started ≠ cwd project* |
| **config-editor** (outside a project) | derived **`(ro,ro,rw,ro)`** | **`(rw,none,none)`** | on | edit `~/.cco` only; project-less (Pc honestly none, INV-2 conditional floor). Cg=rw authors the global `.claude` |
| **config-editor** `--all` / `--cco-access edit-all` | derived **`(ro,rw,rw,rw)`** | **edit-all** | on | every project's `.claude` (Cr still ro) |

> **config-editor floors (ADR-0048).** `G ≥ ro` (authoring tool always sees the store — an
> explicit narrower `--cco-access` is clamped up to `read-global`, with a notice). The former
> bespoke *"`claude_access` follows G"* is **subsumed by the general cco-derived Axis-B default**
> (ADR-0049 §8) — config-editor no longer special-cases claude. The `cco-config` (`~/.cco`)
> workspace mount readonly follows G from the same source as the operator bucket.

**`claude_access` — the `(Cr,Cp,Cg,Co)` axis** over the `.claude` authoring trees, orthogonal
to the cco verb surface above. Presets are sugar for fixed triples:

| Preset | `(Cr,Cp,Cg,Co)` | Meaning |
|---|---|---|
| none | `(ro,ro,ro,ro)` | lock all `.claude` authoring |
| repo | `(rw,rw,ro,ro)` | author the local trees (repo-native + current project) |
| all | `(rw,rw,rw,rw)` | author every `.claude` tree |

Unset it derives per-axis from `cco` (Cr always `ro`). It gates *file-tree write access to
`.claude`*, not `cco` verbs — a session can be `cco_access=read-project` yet an explicit
`claude_access=repo` (honored with a discordance note). `settings.json` + a `settings.local.json`
rw child overlay stay writable regardless (functional-write floor, ADR-0049 §5).

---

## 6. Maintenance

- **Derive, don't drift.** When a verb is added/reclassified in `_cco_operator_shim`, update
  the matching row here and extend `tests/test_operator_shim.sh`. The §5 checklist of
  [design-cli-environment-awareness.md](../design/design-cli-environment-awareness.md) is the
  authoring procedure; this table is its rendered result.
- **⏳ target rows** are cleared (flag removed) as approved behaviour lands, at the commit
  that makes each true. The hardening-v2 batch (ADR-0044 preset flip; ADR-0046 model;
  ADR-0047 boundary; B1–B4) has all landed, so **no ⏳ rows remain** — every row is shipped
  behaviour (the e2e v2 acceptance oracle). Reintroduce the flag only for a *new*
  approved-but-unshipped target.
