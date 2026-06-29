# ADR 0034 — `cco join`: Journey E (add the current repo as a project member)

**Status**: Accepted (2026-06-29) — pre-merge **Round 3 dogfooding** (Scope 3); decisions land pre-merge
**Deciders**: maintainer + dogfooding session
**Context docs**: the handoff
[`../s3-join-forget-handoff.md`](../s3-join-forget-handoff.md) (code map, test plan); `../../roadmap.md`
§"Round 3 … Scope 3"
**Related ADRs**: **0024 D1/D2 (project identity = `project.yml` `name:`; the `cco sync` clobber-guard
keys on it)**, **0031 (`cco project rename` — the multi-repo same-id edit pattern)**, **0021 (resource
lifecycle: the entry trio + `cco forget`)**, **0017 D1/D2 (coordinate `url` derived from `origin`;
optional repo `url`)**, **0029 D1/D2 (one job per verb; uniform destructive-confirm)**, **0022 D3
(`cco resolve --scan` upsert)**, and **P12/P13/P17/P18** (per-unit coordinate · propagate via the
project's own git remote · cco composes, git enforces · one repo, one config home).

---

## Context

The decentralized model has three mutually-exclusive **entry verbs** for a repo (ADR-0021 §1): `cco
init` (scaffold a clean `.cco/`), `cco init --migrate` (hydrate from a legacy backup), and `cco join`
(become a **member** of a project defined in another repo). The design (`design.md` §7) and the user CLI
reference both describe `cco join <project>` as **Journey E** — *"add the current repo to `<project>` as a
member: register it in the index and add it to `repos[]`"*.

The **shipped code did the opposite.** `cco join` (in `lib/migrate.sh`) implemented **Journey C**: run
inside an already-cloned repo that carries its **own** committed `.cco/project.yml`, it registered *that*
project's membership in the machine-local index. It took **no `<project>` argument**, and a code comment
flagged Journey E as *"NOT implemented here … needs a maintainer design decision (it changes join's
signature + edits a holder repo's project.yml)."* This ADR makes that decision.

Two facts shape it:

1. **Journey C is redundant.** Registering an already-committed `.cco/` on this machine is already done
   by `cco start` (cwd-first resolution, no index needed) and by `cco resolve --scan` (which upserts the
   same membership + path, ADR-0022 D3). Journey C added a third path to the same outcome.
2. **`repos[]` is replicated but is NOT the sync discriminator.** `cco sync` copies the whole
   `<repo>/.cco/` (including `project.yml`) across a project's config-bearing members; its D2 clobber-
   guard keys on `name:` (ADR-0024 D2). Adding a member to `repos[]` therefore edits a **non-discriminator**
   field — a partial edit (some members updated, others not) is **not** permanent divergence: it converges
   to the others on the next `cco sync`. This is the crucial difference from `cco project rename`, which
   rewrites `name:` **itself** and so must be strict (ADR-0031 D3).

## Decision

### D1 — Repurpose `cco join` entirely to Journey E; drop Journey C

`cco join <project> [--sync] [--name <name>]` adds the **current** repo as a new **member** of an existing
project `<project>` (defined and hosted in another repo, registered on this machine). The verb lives in a
new `lib/cmd-join.sh` (`cmd_join`), dispatched from `bin/cco`'s `join)` arm; the old Journey-C body is
removed from `lib/migrate.sh`. One verb, one job (ADR-0029 D1).

Rejected: keeping both behaviours behind argument-presence (two jobs in one verb), and a new verb name
(the design already names the Journey-E form `cco join`).

### D2 — What a join writes

- **Coordinate into `repos[]`.** The joining repo's machine-agnostic coordinate (`name` + `url`) is
  appended to the project's `repos[]` (reusing `_yml_append_coord`). The `url` is **derived from `git
  remote get-url origin`** (ADR-0017 D2); with **no `origin`** the repo joins **without** a `url` (repo
  `url` is optional, ADR-0017 D1) and a warning is emitted (set it later in `project.yml`).
- **Member name** (`name:` in `repos[]`, the index key): resolved as **`--name` > interactive prompt
  (default = the repo dir basename) > basename** (non-interactively). Validated by the shared
  `_cco_valid_project_name` (lowercase-hyphen-digit; ADR-0031 D5 / Design Invariant 10). Refused if the
  name already exists in the project's membership.
- **Machine-local index.** The new member is appended to the STATE index `projects:` membership and its
  `name → absolute path` binding is written (`_index_set_path`). These two index writes apply **together**.

### D3 — Which member `project.yml` gets the `repos[]` edit (Case B vs Case C)

The set of members to edit is selected from the shared **member sync-state classifier**
(`_project_member_status`, ADR-0024 D5): only **owned** members (`name == <project>`) with a committed,
resolved `.cco/` are candidates — `foreign` / `code-only` / `unresolved` members are never edited (no owned
or reachable `.cco/` to write; they converge later via `cco sync`).

- **Case B (no divergent member).** Every in-sync (`synced`) member's `project.yml` is edited
  automatically. A partial edit self-heals via `cco sync` (Context #2), so join is **not strict**.
- **Case C (≥1 `divergent` member).** The members' `project.yml` files have drifted (hand-edited since the
  last sync), so cco **prompts** which member to update — a numbered pick, or **all**. This is the
  maintainer ruling (over rename-style strict refusal), and is safe precisely because `repos[]` is a
  non-discriminator field. **Non-interactively with a divergent project → `die`** (ADR-0029 D2): Case C
  needs an explicit choice; the user is told to re-run interactively or converge first with `cco sync`.

The maintainer ruling here **differs from ADR-0031 D3** (rename is strict) on purpose: rename mutates the
identity discriminator and a partial rewrite is unrecoverable under the sync guard, whereas a partial
`repos[]` edit is not.

### D4 — `--sync` and the D2 clobber-guard

Without `--sync` the joining repo stays a **code-only member** (Case A) — it carries no `.cco/`. With
`--sync` it **receives** the project's `<repo>/.cco/` via `cco sync` (source = the chosen/first owned
member). The copy goes through the existing **ADR-0024 D2 clobber-guard**: if the joining repo already
**hosts a different project** (`name != <project>`), the sync is **skipped + warned**, never clobbered.
(Running join from a repo that already **hosts `<project>` itself** is refused up front — it is the
project, not a new member.)

### D5 — Atomicity boundary (mirrors ADR-0031 D4)

The machine-local index writes apply together after validation. The cross-repo `project.yml` edits live in
**separate git working trees** and cannot be transactional, so they are applied to the selected members and
the command **warns to commit + push the changed `project.yml`, then run `cco sync`** in each (P17
delegate-to-git, mirroring `cmd_project_rename` and `cmd_sync`'s closing warnings).

### D6 — Shared member-iteration helper (build-once)

D3's classification is the **single source of truth** `_project_member_status` (+ the iterator
`_project_iter_members`) added to `lib/index.sh`, joining the index (resolved here?), the committed
`name:` (whom does it host?), and the sync fingerprint (edited since last sync?, sync-meta F39) into one
5-way taxonomy — `unresolved | code-only | foreign | divergent | synced`. It is reused by `cco join`,
`cco forget --purge` (ADR-0021 D2 forward-annotation), and `cco project show` (the `_project_member_role`
retrofit), which also **closes two latent ADR-0024 D5 bugs**: a same-name *divergent* member used to
report `host` (the `name==` check preceded the divergence check), and a *foreign* repo was mislabeled
`synced`/`divergent`.

## Consequences

- **No file migration** (no tracked config file renamed/moved; no `*_FILE_POLICIES` change). The verb's
  behaviour changes but its `project.yml` schema does not — the coordinate model is unchanged.
- **`changelog.yml`** gains an **additive** entry (#22, user-visible verb change): `cco join <project>`
  now adds the current repo as a member. Pre-merge, but user-visible, so it is announced.
- **Docs**: `docs/users/reference/cli.md` (`cco join`) was already written to the Journey-E form (design-
  intent doc) — verified + extended with `--name`; the `--help` text (formerly Journey-C) is rewritten;
  living `design.md` §7 reflects the verb. ADR-0024 D5 is forward-annotated for the `_project_member_role`
  fix.
- **Tests**: new `tests/test_join.sh` (Journey E: member added to every synced member's `repos[]`, url
  derived, index updated, `--sync` copy, Case-C non-TTY refusal, uniqueness/host/unknown negatives). The
  old Journey-C `test_join_registers_index` is removed (the behaviour is gone; covered by start/scan).
- **Frozen-model intact**: identity-as-`name:` (0024 D1), projects-ride-code-repo (0018 D2), the per-unit
  coordinate (P12), and the entry-verb trio (0021) are unchanged — this ADR only gives `join` its
  by-design Journey-E meaning and pins how the cross-repo `repos[]` edit stays consistent.

## Alternatives considered

- **Strict member resolution (mirror rename D3).** Rejected by the maintainer for join: `repos[]` is not
  the sync discriminator, so a partial edit converges rather than diverging permanently; strictness would
  add friction (refuse the whole join when one member is offline) for no safety gain. Case C is handled by
  a prompt, not a refusal.
- **Keep Journey C (arg-present = Journey E, arg-absent = Journey C).** Rejected — two jobs in one verb
  (ADR-0029 D1), and Journey C is fully covered by `cco start` cwd-first + `cco resolve --scan`.
- **A new verb for Journey E** (e.g. `cco project add-member`). Rejected — the design already names this
  `cco join`; adding the current repo to a project is exactly "joining" it.
- **`--sync` reimplements the copy.** Rejected — reuse `cco sync` so the D2 clobber-guard and the sync-set
  definition (ADR-0024 D6) are not duplicated.
