# ADR 0050 — Resource rename: identity re-key generalized across kinds

**Status**: Accepted — **implemented 2026-07-14** (Unit B, `feat/naming/resource-management`).
**Depends on [ADR-0051](0051-per-project-name-scoping.md)** (per-project name scoping) and is
**sequenced after it**: repo/extra_mount rename is defined on the *scoped* index model (D2/D3),
not the global-flat one. Pack/template/remote rename are independent of ADR-0051.
**Deciders**: maintainer + design session
**Context docs**: [`../analysis/resource-name-storage-map.md`](../analysis/resource-name-storage-map.md)
(re-key surface §3 + identity model §12 + scoping §13), [`../design/design-resource-rename.md`](../design/design-resource-rename.md)
(CLI signatures, shared module, steps, tests), `../../roadmap.md` §"Resource naming & init
consistency"
**Related ADRs**: **0031 (project rename — the identity re-key pattern this generalizes)**,
**0051 (per-project scoping — the identity model repo/extra_mount rename builds on)**,
0017 (join/coordinate model — repo-name ≠ project-name), 0024 D1/D2/D5 (identity = `name:`;
sync clobber-guard), 0029 D2 (uniform destructive-confirm), 0046 (`(G,Pc,Po)` cco-access model —
write-scope gating), 0045 (running registry)

---

## Context

`cco project rename` (ADR-0031) established that a resource's **logical name is its identity**
and that renaming it is a **multi-store re-key**, not a single-file edit. But that pattern was
implemented only for `project`; `cco llms rename` implements a lighter directory-keyed variant.
**Five kinds still have no rename verb at all — repo, extra_mount, pack, template, remote** — so
a user who renames any of them must hand-edit the internal stores (forbidden by the managed
rule) or accept permanent staleness.

This surfaced concretely: a user renamed a **repo directory** on disk and ran `cco resolve`.
`resolve` correctly updated the index **path** (the value), but the repo's **logical name**
(the index `paths:` **key** and every `project.yml` `repos[].name`) stayed the old string —
because the name is a separate axis with no rename verb, and `resolve`/`path` operate only on
the path axis. See [`../analysis/resource-name-storage-map.md`](../analysis/resource-name-storage-map.md) §9.1.

Three facts force real decisions rather than five mechanical copies of `project rename`:

1. **Name, path, and directory-basename are three independent axes.** `cco init`/`cco join`
   derive the repo name from `--repo-name` › prompt › dir basename, independently of the
   project name (ADR-0017). In the mono-repo case they *coincide* incidentally — the rename
   design must never let a rename of one axis silently rename another.
2. **Two structural families need different mechanics.** *Index-keyed* kinds (repo,
   extra_mount) store the name as a **per-project** index binding (ADR-0051: `project_paths[project][name]
   → path`) whose **identity is the path**, referenced from that project's committed
   `project.yml`. *Directory-keyed* kinds (pack, template, llms) store the name as a store-
   directory **basename** under `~/.cco`/CACHE, with provenance + tags sidecars, and remain
   **globally scoped** (unaffected by ADR-0051). `remote` is a registry key. Each family re-keys
   a different store set (analysis §3–§4, §12–§13).
3. **The CLI is dual-context (host + in-container agent, ADR-0046).** A `rename` is a *write*
   verb; it must be classified by the **config tree it writes** so the operator shim gates it
   correctly — or an agent session will either be wrongly refused or wrongly allowed to mutate
   the global store.

## Decision

### D1 — Per-kind `rename` verbs (no top-level `cco rename`)

Add, symmetric with the existing `cco project rename` / `cco llms rename`:

| Verb | Home | Family |
|---|---|---|
| `cco repo rename [<old>] <new>` | new `lib/cmd-repo.sh` (`cmd_repo`, room for `list`/`show` later) | index-keyed |
| `cco extra-mount rename <old> <new>` | `lib/cmd-repo.sh` sibling or new group (name locked to `extra-mount` to match `project.yml extra_mounts`) | index-keyed |
| `cco pack rename <old> <new>` | `lib/cmd-pack.sh` | directory-keyed |
| `cco template rename <old> <new>` | `lib/cmd-template.sh` | directory-keyed |
| `cco remote rename <old> <new>` | `lib/cmd-remote.sh` | registry |

A **top-level auto-detecting `cco rename <old> <new>`** is **rejected** (same reasoning as
ADR-0031 alt): cross-kind name collisions are the norm in the mono-repo case (project == repo
== same string), so a single verb would force `--kind` disambiguation in exactly the confusing
case this work fixes, and it hides which stores are touched. The verb naming the kind is the
disambiguation.

### D2 — Kind-scoped re-key (the load-bearing correctness rule)

A `rename` operates **only** on the stores of its own kind. `cco repo rename api …` must **not**
rename the project named `api`, and `cco project rename` must not touch a repo named `api`, even
when the strings coincide. The re-key surface per kind is the analysis §3 table, frozen here as
the spec:

- **repo** (project-scoped, path-anchored — ADR-0051 D1): re-key the **current project's**
  binding `_index_rename_path(project, old, new)` (re-key `project_paths[project]`, membership
  token in `projects:`); rewrite `repos[].name` in **this project's** `project.yml`. The member
  is identified by its **path** within the project (not merely its name). **No cross-project
  fan-out** — another project's same-named-but-different-path binding is a *different resource*
  (untouched), and another project labeling the *same path* keeps its own independent label
  (per-project naming). url/ref coordinate and the on-disk directory untouched by default (D4).
- **extra_mount**: as repo, project-scoped; rewrite `extra_mounts[].name`; if `target:` was
  implicit (`/workspace/<name>`) the **container mount path changes** — surfaced in the preview.
- **pack**: `mv ~/.cco/packs/<old>/` → `<new>`; rewrite internal `pack.yml name:`; move DATA
  provenance `packs/<old>/source`; move STATE `packs/<old>/update/`; `_tags_rename packs`;
  rewrite `packs[].name` fan-out across projects.
- **template**: `mv` store dir; move DATA `templates/<old>/source` + STATE `templates/<old>/update/`;
  `_tags_rename templates`. No committed reference to rewrite.
- **remote**: re-key the `DATA/remotes` entry + migrate the `STATE/remotes-token` entry if present.

### D3 — Rename scope per family (project-local for index-keyed; ref fan-out for pack)

**repo / extra_mount — project-local (ADR-0051 D1/D2).** Under per-project scoping the name is a
label local to one project, so rename touches **only the current project**: its
`project_paths[project]` binding + its `project.yml` (`repos[]`/`extra_mounts[]`). The member is
matched by **path**. There is **no cross-project fan-out** — a same-named binding in another
project is a *different resource*; a same-path binding in another project is that project's own
label. Strict-resolution reduces to "the current project's member is resolved" (trivially true
from within the repo). A multi-repo project whose `project.yml` is replicated still edits only
that one project's copies across its member repos (the ADR-0031 D3 within-project git delegation:
commit + push + `cco sync`, P17); other projects are never touched. *(A future `--all-projects`
could offer to rename same-path labels elsewhere too — deferred; default is project-local.)*

**pack — cross-project ref fan-out (unchanged by ADR-0051).** Pack names are globally scoped, so
`pack rename` still rewrites `packs[].name` in **every** project referencing the pack, with the
owned+resolved strict guard and commit/push/sync warning (`_rename_fanout_projectyml`). template/
remote have no committed `project.yml` reference to fan out. The preview lists the blast radius
before `_confirm_destructive`.

### D4 — Directory handling by family

- **Directory-keyed (pack, template)**: the store directory basename **is** the identity, so the
  `mv` is **mandatory** and internal (under `~/.cco`/CACHE — framework territory). No prompt.
- **Index-keyed (repo, extra_mount)**: the on-disk directory is a **real working tree / user
  mount** (its own git identity, possibly shared by other projects and native Claude, possibly
  referenced by the user's shell and external tools). Default: **re-key the logical name only**,
  directory untouched. **Optionally** `mv` the directory in the same command, but only:
  - offered via a **y/N prompt defaulting to No**, and only when the directory **basename equals
    the old name** (so the move is unambiguous and keeps name↔basename aligned);
  - with an explicit warning that external references to the old path won't be updated;
  - when accepted, the `mv` is followed by `_index_set_path <new> <newpath>` so the index path
    axis stays correct.
  - a `-y`/`--yes` run **does not** auto-move the directory (No is the non-interactive default);
    an explicit opt-in flag (e.g. `--move-dir`) may drive the move non-interactively.

  This honors the "unified, convenient rename" ask while keeping the filesystem move opt-in and
  prudent on non-store territory. The default (name-only) keeps `cco path` (path axis) and
  `cco <kind> rename` (name axis) strictly orthogonal — the orthogonality whose absence caused
  the original confusion.

### D5 — Validation, confirm, atomicity boundary, ordering (inherit ADR-0031 D4)

- **Validate `<new>` before any write**: per-kind charset predicate (repo/pack/template/remote
  already carry `[a-z0-9][a-z0-9-]*`-family regexes; reuse them), reserved-name check, and
  **uniqueness within the kind** (the new name must not already name a resource of that kind).
- **Kind-scoped uniqueness only**: a repo may take a name that a *project* already uses (D2) —
  the uniqueness check is per-store, not cross-kind.
- **Confirm** (ADR-0029 D2): preview the re-key plan (stores touched, projects/member repos in
  the blast radius, whether the dir will move) and confirm; `-y` skips; non-TTY without `-y` → die.
- **Atomicity boundary**: machine-local re-keys (index, tags, provenance/store moves) applied
  together after full pre-validation, each individually atomic (`mktemp`+`mv`); cross-repo
  `project.yml` edits are git-delegated (D3). No cross-store transaction is attempted (not
  achievable in bash), mirroring ADR-0031 D4.

### D6 — One shared rename module (`lib/rename.sh`), DRY over five copies

Extract the common machinery so the five verbs are thin wrappers:

- **`_yaml_rename_list_ref <file> <section> <old> <new>`** — generalizes `_llms_rename_in_yaml`
  to any list section (`repos`, `extra_mounts`, `packs`, `llms`), handling **both** the scalar
  form (`  - old`) and the mapping form (`  - name: old`), section-scoped (exit on the next
  top-level key so it never bleeds into an adjacent section). Returns changed/not-changed so
  callers can count.
- **`_index_rename_path <project> <old> <new>`** (in `index.sh`, the repo/extra_mount analogue
  of `_index_rename_project`, **project-scoped** per ADR-0051) — re-key `project_paths[project]`
  (`get`→`set new`→`remove old`) **and** rewrite the `projects: <project>` membership token.
  Never touches other projects.
- **`_rename_fanout_projectyml <section> <old> <new>`** — the owned+resolved member loop
  (strict guard, `changed[]`/`unresolved[]` collection, commit/push/sync warning). Used by
  **pack** (cross-project `packs[]` fan-out). repo/extra_mount use a single-project variant
  scoped to the current project (D3).
- **Migrate `_llms_rename` onto `_yaml_rename_list_ref`** and add the missing **`_tags_rename
  llms`** call (no-op-safe today since llms is not yet a tag kind — closes a latent gap for
  symmetry).

### D7 — Operator-shim write-scope classification (ADR-0046)

Each new verb is registered in the container-operator write-verb whitelist keyed by the config
tree it writes, so `_op_write` gates it:

| Verb | Writes | Runnable in-container at |
|---|---|---|
| `repo rename`, `extra-mount rename` | the **current project** tree (its `project.yml` + index membership) | `edit-project` (Pc=rw) for the current project; other projects need Po=rw |
| `pack rename`, `template rename`, `remote rename` | the **global store** (`~/.cco`, DATA/STATE registries) | `edit-global` (G=rw) only — refused at plain `edit-project` |

A test asserts an `edit-project` session is **refused** `pack rename` but **allowed** `repo
rename` for its own project.

### D8 — Bundled secondary fix: quote hygiene in path input

`cco resolve` / `cco path set` reject a path pasted with surrounding shell quotes
(`'/my/repo/path'`) because `read -r` + `_resolve_to_abs`/`expand_path` never strip them
(analysis §9.2). Fix: strip **one** pair of surrounding matching quotes (`'…'` or `"…"`) before
absolutizing — matches what the shell would have done to that token, unambiguous, preserves
internal characters literally. Explicitly **not** full shell dequoting (ambiguous, over-built).
Additionally, `cco path set`/`resolve` emit a **hint** when the index key no longer matches the
directory basename, pointing to `cco repo rename` (teaches the name-vs-path distinction).

## Consequences

- **Additive, no migration**: no schema change, no tracked-file rename, no `*_FILE_POLICIES`
  change. One **`changelog.yml`** entry (grouped, "resource rename verbs") since this ships
  post-release (unlike ADR-0031, which was pre-merge internal).
- **New module + command files**: `lib/rename.sh`, `lib/cmd-repo.sh`; additions to
  `cmd-pack.sh`/`cmd-template.sh`/`cmd-remote.sh`/`cmd-llms.sh`; `bin/cco` dispatch + operator
  whitelist; `_index_rename_path` in `index.sh`.
- **Docs**: `docs/users/reference/cli.md`, the root `CLAUDE.md` Build & Run list, and
  `cco path`/`resolve` help gain the new verbs + the quote-strip note; this ADR + the living
  `../design/design-resource-rename.md` are the maintainer references.
- **Tests**: one per verb — assert every store updated, **no stale references** (grep the index
  + all member `project.yml`s), strict-refusal on an unresolved owned member, kind-scoped
  isolation (`repo rename` leaves a same-named project untouched and vice versa), and the
  operator-gating matrix (D7).
- **Frozen model intact**: identity-as-name (0024 D1), repo-name≠project-name (0017),
  projects-ride-code-repo (0018) unchanged — this ADR adds the missing identity-mutation verbs
  for the non-project kinds and pins how each stays consistent across its stores.

## Alternatives considered

- **Top-level `cco rename <old> <new>`** (auto-detect kind): rejected — see D1.
- **Always `mv` the repo directory as part of rename** (or never offer it): rejected both ways.
  Never-move loses the "unified convenient rename" the user asked for; always-move acts on
  non-store user territory (a working tree possibly shared / externally referenced) without
  consent. The **opt-in, basename-gated, default-No prompt** (D4) is the middle ground.
- **Fold rename into `cco path` / `cco resolve`**: rejected — conflates the path axis with the
  name axis, the exact conflation that caused the reported confusion (analysis §9.1).
- **Per-kind duplicated logic (no shared module)**: rejected — five near-identical re-key flows
  drift; `lib/rename.sh` (D6) keeps the fan-out/strict-guard/YAML-rewrite single-sourced.
- **Full shell dequoting of path input**: rejected — ambiguous and over-engineered; one-pair
  balanced-quote strip (D8) covers the real paste case.
