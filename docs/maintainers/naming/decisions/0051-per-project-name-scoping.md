# ADR 0051 — Per-project name scoping: path is the resource, name is a per-project label

**Status**: Proposed (2026-07-14) — design phase, `feat/naming/resource-management`.
Supersedes the deferral in **ADR-0022 D2 (H7)** ("global-flat for v1; per-project namespacing
reserved post-v1"); revises **AD5** and the join/resolve collision semantics.
**Deciders**: maintainer + design session
**Context docs**: [`../analysis/resource-name-storage-map.md`](../analysis/resource-name-storage-map.md)
§12 (identity model) + §13 (scoping factor, blast-radius, migration), `../../roadmap.md`
§"Index per-project namespacing"
**Related ADRs**: **0022 D2 / H7 (global-flat ratification — now superseded)**, 0016 D4 (index
= 4-bucket machine-local name→path), 0017 (join/coordinate model — repo-name ≠ project-name),
0024 D1/D5 (project identity; repo→projects reverse lookup), 0014 D2 (project.yml carries
machine-agnostic names + `url` coordinates), **0050 (resource rename — consumes this model)**

---

## Context

The machine-local STATE index (`lib/index.sh`) is **global-flat**: `paths: <name> → abspath` is
one machine-global map, and **AD5** holds "one logical name → one absolute path per machine", so
a repo/extra_mount name is **globally unique**. ADR-0022 D2 ratified this for v1 and **deferred**
per-project namespacing (H7) until "real cross-project name collisions appear". The global-flat
model buys a genuine UX win **(V)**: a new project reusing an already-resolved name needs no path
re-specification.

Two collision cases have now appeared that global-flat **cannot represent** (analysis §13):

1. **Sharing / import**: an imported project references a repo/extra_mount name already bound on
   this machine to a **different** path (often a different repo `url`). Global-flat refuses or
   mis-binds.
2. **Generic mount names**: different projects legitimately use `assets` / `resources`
   extra_mounts pointing at **different** paths. There is **no meaningful global default** for
   such a name — the very concept of "the global `assets`" is wrong.

Case 2 is decisive against any *global-default* rescue: you cannot designate one path as the
canonical global binding for a generic label. The correct model is that these names are
**meaningful only within a project**.

Underneath the naming question is an **identity question** the v1 model got backwards.

## Decision

### D1 — Identity is the PATH; the name is a per-project label

For the index-keyed kinds (**repo, extra_mount**), the **resource identity is the host path**
(the working tree / mount on disk); the **name is only a per-project label** for that path.

- **Same path ⇒ same resource**, even under different names (aliases).
- **Same name + different path ⇒ different resources** (homonyms).

**Classification rule (normative, all present + future code): resource-sameness is decided by
PATH coincidence, never by NAME coincidence.** Name-based identity is valid only *within one
project's scope*, where the name→path map is 1:1. This reverses the v1 "bare name is a global
identity" assumption (AD5). (llms remains globally scoped — content cache keyed by name — and is
out of this ADR; project identity stays the global `name:`, ADR-0024 D1.)

### D2 — repo/extra_mount names are scoped to their project (no global default)

The index binds `(project, name) → path`. There is **no** global-default layer (rejected — see
Alternatives; a global default is meaningless for generic labels, case 2). Same-name-in-
different-projects is **not** a collision; only **same project + same name + different path** is.

Proposed on-disk schema (nested by project; readable, and the section-remove logic stays simple):

```yaml
version: 2
projects:
  app-a: "backend web"          # membership (names) — unchanged, globally-unique project keys
  app-b: "backend assets"
project_paths:                  # NEW: per-project name → path (replaces global `paths:`)
  app-a: { backend: /abs/backend, web: /abs/web }
  app-b: { backend: /abs/backend, assets: /b/assets }
llms: { <name>: <path> }        # llms stay global (or a dedicated global section)
```

Resolution of a member: `project_paths[project][name]` → else unresolved (run `cco resolve`).
No cross-project fallback (that would resurrect the global default). The **(V)** convenience is
preserved by D4's add-time suggestion, not by a shared binding.

### D3 — `_index_path_conflicts` is the single project-aware chokepoint

All AD5-style enforcement lives in one place. `_index_path_conflicts` gains project context —
`(project, name, path)` — and reports a conflict only when the **same project** already binds
`name` to a **different path**. Every caller (init, join, `resolve --scan`, migrate) threads its
project context through this one function (blast-radius: analysis §13.1). New invariant **AD5′**:

> **AD5′** — within a project scope, one name → one path; the same name may bind different paths
> in different projects; the same path may carry different names in different projects.

### D4 — Add-time disambiguation (preserves the (V) convenience, explicitly)

When `init`/`join`/`resolve`/`import` binds `(project, name, path)` and `name` already exists in
**other** projects, cco surfaces the existing binding(s) as **suggestions** and prompts:

- **reuse an existing path** (the user is pointing at the *same resource* — path filled for
  free, which is exactly the (V) win, now explicit and confirmed rather than silent), or
- **specify a different path** (a *homonym* — a different resource; `resolve` a new path).

**URL divergence signal** (maintainer-approved): before offering reuse, derive the existing
binding's actual url via the on-disk `git -C <existing-path> remote get-url origin` and compare
it to the incoming `project.yml` coordinate `url`. If they diverge → an extra warning
("probably a different resource; consider a different path"). No url is stored in the index; it
is derived on demand. For extra_mounts (no git remote) the prompt runs without the url signal.

Init/join stop **refusing** on a cross-project name match (D2 makes it a non-collision); they
refuse only on a **same-project** same-name-different-path clash (a genuine AD5′ violation).

### D5 — Path-based reverse lookup replaces name-based reverse lookup

`_index_repos_get_projects(name)` ("which projects use name X") is **semantically broken** under
scoping (same name across projects = different resources). Replace it with a **path-based**
primitive `_index_paths_get_bindings(path)` → the `(project, name)` bindings that resolve to
`path` (the §12 path-identity operationalized). Rewire its 3 callers:

- `cmd-forget.sh:44` (shared-resource guard: "is this path still used by another project?") →
  path-based (correct: sharing is a path property, not a name property).
- `cmd-project-query.sh:206` (referenced-by view) → path-based ("other projects mounting this
  path"), optionally showing the per-project alias each uses.
- `cmd-resolve.sh:700` (cross-project member check) → path-based.

### D6 — Migration (breaking, deterministic, one-pass)

Because names are globally unique **today**, the re-home is lossless: for each project in
`projects:`, for each member name, read the current global `paths: <name>` and write it under
`project_paths[project][name]`. Orphan global paths (a `cco path set` name in no project's
membership) → an `unscoped:` bucket (kept resolvable) — **decide keep-vs-drop in impl**; default
**keep** (non-destructive). Bump index `version` 1 → 2; the migration is idempotent
(`migrations/` — scope: this is STATE index, migrated by a dedicated index-migration path, not
the project/pack/template scopes). `cco resolve --scan` remains the self-heal.

## Consequences

- **Breaking schema** (index `version` 2) with a deterministic migration (D6); a `changelog.yml`
  breaking entry + migration note. Unlike the rename verbs (additive), this is the one breaking
  piece of the naming workstream — which is **why it is sequenced first** (the rename design,
  ADR-0050, is revised to build on this model rather than the reverse).
- **`lib/index.sh` API reshaped**: `_index_{get,set,remove}_path` and `_index_path_conflicts`
  gain project context; `_index_repos_get_projects` → `_index_paths_get_bindings`;
  `_index_list_paths` gains a scope argument. ~32 call sites rethreaded (analysis §13.1).
- **UX**: cross-project name collisions become supported (import + generic mounts); the
  add-time prompt makes the (V) reuse explicit + confirmed; the url signal flags likely-different
  resources on import. init/join lose the cross-project refusal.
- **Enables downstream correctness**: repo/extra_mount `rename` (ADR-0050, revised) becomes
  **project-scoped and path-anchored** — it renames the label for a *path* within one project,
  never fanning out to other projects' same-named-but-different-path bindings. The future
  shared-repo lock (roadmap FI-15) also keys on path, per D1.
- **Frozen model touched deliberately**: AD5 → AD5′ (D3); ADR-0022 D2's global-flat ratification
  is superseded (forward-annotate it). Project identity (0024 D1), join coordinate model (0017),
  and llms global scope are unchanged.
- **Tests**: index unit tests for the nested schema + AD5′; migration idempotency +
  losslessness; the two collision cases (import homonym with divergent url; two projects with a
  generic `assets` mount); forget shared-guard now path-based.

## Alternatives considered

- **Global-default + per-project override** (keep global `paths:` as a default layer, add
  overrides only on divergence; additive migration): **rejected by the maintainer** — for generic
  labels (case 2) there is **no meaningful global default**, so "which is the global and which is
  the override?" has no principled answer. A model where the name is *only* ever per-project is
  cleaner and matches the true identity (path, D1). The additive-migration advantage does not
  justify a conceptually wrong default layer.
- **Keep global-flat, refuse harder** (better error messages on collision): rejected — does not
  solve import or generic mounts; the resource model is simply wrong.
- **Composite flat key `project:name → path`** (instead of nested `project_paths[project][name]`):
  viable; chosen the nested form for readability + simpler section semantics, but this is an
  impl-detail the design doc may revisit.
- **Name-based reverse lookup with scope filter** (keep `_index_repos_get_projects`, filter by
  scope): rejected — sharing/GC/rename are **path** properties (D1); a name-based reverse lookup
  is the wrong primitive regardless of filtering.
