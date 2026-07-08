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
> reference for any CLI change. Rows marked **⏳ target** reflect approved-but-not-yet-shipped
> behaviour (ADR-0044 preset flip; pre-review fixes B1–B4) — flagged so the doc never claims
> behaviour the code does not yet expose (documentation-lifecycle rule).
>
> Related: [CLI environment-awareness](../design/design-cli-environment-awareness.md) (the
> principle + the central gate §4) · [ADR-0042](../../configuration/agent-cco-access/decisions/0042-agent-cco-interaction-model.md) · [ADR-0043](../decisions/0043-unified-cli-environment-access-scope.md) · [ADR-0044](../../configuration/agent-cco-access/decisions/0044-internal-builtin-presets-and-config-editor-scope.md)

---

## 1. Model recap (the axes)

**Two contexts** (`_cco_container_operator`, `lib/paths.sh`):
- **host** — full surface, never scoped (INV-A). No behaviour change from the human CLI.
- **in-container (operator)** — every verb passes the central gate `_cco_operator_shim`
  first (default-deny); permitted read verbs additionally have their **output** scoped.

**`cco_access` levels** (symmetric read/write on `{project, global, all}`):
`none · read-project · read-global · read-all · edit-project · edit-global · edit-all`
(bare `read` = deprecated alias for `read-all`). Derived scopes are the single source
(`_cco_level_read_scope` / `_cco_level_write_scope`):

| Level | read_scope | write_scope |
|---|---|---|
| none | — (cco refused wholesale) | — |
| read-project | project | — |
| read-global | global | — |
| read-all | all | — |
| edit-project | project | project |
| edit-global | global | global |
| edit-all | all | all |

**Availability is monotonic**: a verb available at level *L* is available at every level
that reads/writes at ≥ its required scope. So each verb is stated as **"available from
&lt;min level&gt;"** rather than repeating seven columns.

**Exit-code convention** (D8): `0` success or graceful degrade · `2` refused by policy
(host-only, or needs a wider scope) · `1` error (unknown verb, parse/resolve failure).

**`claude_access` (`none|repo|all`)** is an **orthogonal** axis: it governs the `.claude`
authoring trees, **not** cco verbs. It does not appear in the verb rows below; see §5.

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
| `path list` | ✅ | ✅ **read-only listing OK** | — |

### 2.2 Read / introspection — available from read-project (unless noted)

| Verb | Class | In-container | Output scoping |
|---|---|---|---|
| `list` (unified) | read:project | ✅ from read-project | scoped per kind (§3); count-only stderr notice when filtered |
| `list projects\|packs\|llms` | read:project | ✅ from read-project | project-class (§3) |
| `list templates\|remotes` | read:**global** | ✅ from **read-global** | global-class — empty+notice below read-global |
| `docs` | always | ✅ from read-project | — (refused at `none`, R6) |
| `help`, `--help`/`-h`, `--version`/`-v` | always | ✅ | help is scope-aware (§4) |
| `whoami` | always | ✅ from read-project | session-state introspection (F4). **⏳ target B1**: also listed in in-container `help` |
| `project show\|validate\|coords` | read:project | ✅ from read-project | current project resolvable from `/workspace` root (R2/F3) |
| `pack show\|validate`, `llms show\|validate` | read:project | ✅ from read-project | `_env_require_visible` — graceful "not in scope" for out-of-scope names |
| `template show\|validate` | read:**global** | ✅ from **read-global** | global-class |
| `remote list` | read:**global** | ✅ from **read-global** | global-class |
| `config` (bare), `tag` (bare), `pack\|template\|llms\|project` (bare) | always | ✅ prints sub-usage | — |

### 2.3 Write — available from the matching edit level (gated by target tree)

| Verb | Class (target tree) | Available from | Notes |
|---|---|---|---|
| `tag add\|remove` | write:global (DATA registry) | edit-global | global regardless of the named project (C1) |
| `config save` | write:global (`~/.cco`) | edit-global | clear "needs edit-global" msg on ro mount at edit-project (CLI-surface F3) |
| `remote add\|remove` | write:global (DATA registry) | edit-global | `remote add --token` refuses the **token half** in-container (secret stays host-side) |
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
| `pack\|template publish\|export`, `project export\|import\|add` | ✅ | ❌ host-only | exit 2 |
| `project rename` | ✅ | ❌ host-only (re-keys machine-local state) | exit 2 |
| `pack\|template\|project list` (old subcommand) | (redirect) | ❌ → "use `cco list <kind>`" (ADR-0029) | exit 2 |
| `share`, `manifest` | ❌ removed | ❌ removed | exit 2 |
| unknown top-level verb | error | error ("Run `cco help`") — **not** a host-only misfire | exit 1 |
| `<cmd> --help` / `-h` | ✅ | ✅ **always** (informational, even for host-only verbs) | — |

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

**⏳ target B3**: the unified `cco list` shows **running status** for the `project` kind
(today only `cco list project` does). **⏳ target B4**: in-container, running status for a
project **not visible to the scoped docker daemon** is reported `unknown`, never a false
`stopped`; full cross-project running awareness comes from the STATE running registry
([ADR-0045](../../environment/decisions/0045-session-running-registry.md), DI1), gated by
this same scope layer.

---

## 4. Help scope-awareness (D7)

| Invocation | Host | In-container |
|---|---|---|
| `cco help` / `cco --help` | full, unannotated | **filtered** to verbs runnable at the current scope; host-only + above-level omitted; one-line warn "N hidden — `cco --help --host`". **⏳ target B1/B2**: `whoami` listed; a section header with zero runnable verbs is suppressed |
| `cco --help --host` (in-container) | — | full list, host-only verbs flagged `(host only — run on your host)` |
| `cco <cmd> --help` | full usage | **always** available (informational), even for host-only verbs |

---

## 5. Preset defaults (built-ins) & the orthogonal `claude_access`

**Preset defaults** (`_start_resolve_access`, `lib/cmd-start.sh`) — resolution precedence:
CLI flag > `project.yml access:` > `~/.cco/access.yml` > preset.

| Preset | claude_access | cco_access | show_host_paths | Notes |
|---|---|---|---|---|
| standard project | repo | **read-project** | on | uniform minimum-privilege; flags widen/narrow |
| **tutorial** | none | **read-all** ⏳ | on | ADR-0044: read-only teacher → full context, no write risk (was read-project). `--cco-access` discouraged |
| **config-editor** (cwd in a project) | all | **edit-project** ⏳ | on | ADR-0044: edits cwd project's `.cco` + `~/.cco`. *started ≠ cwd project* |
| **config-editor** (outside a project) | all | **edit-global** ⏳ | on | ADR-0044: `~/.cco` only; no project in scope |
| **config-editor** `--all` / `--cco-access edit-all` | all | **edit-all** | on | explicit broad every-project surface (the old default) |

**`claude_access` (`none|repo|all`)** — orthogonal axis over the `.claude` authoring trees,
independent of the cco verb surface above:

| Level | Meaning |
|---|---|
| none | no `.claude` authoring |
| repo | the invoking repo's `.claude` trees (standard-project default) |
| all | all mounted `.claude` trees (config-editor default) |

It gates *file-tree write access to `.claude`*, not `cco` verbs — a session can be
`cco_access=read-project` yet `claude_access=repo`. Kept separate here to avoid implying a
cross-product that does not exist.

---

## 6. Maintenance

- **Derive, don't drift.** When a verb is added/reclassified in `_cco_operator_shim`, update
  the matching row here and extend `tests/test_operator_shim.sh`. The §5 checklist of
  [design-cli-environment-awareness.md](../design/design-cli-environment-awareness.md) is the
  authoring procedure; this table is its rendered result.
- **⏳ target rows** are cleared (flag removed) as ADR-0044 + B1–B4 land, at the commit that
  makes each true. Until then they document the *approved target*, used as the e2e v2
  acceptance oracle — not current shipped behaviour.
