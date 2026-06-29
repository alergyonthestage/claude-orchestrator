# ADR 0029 — UX-UI review: unified `cco list`, uniform destructive-confirm, verb symmetry

**Status**: Accepted (2026-06-27) — pre-merge **UX-UI review** (review cycle step 4)
**Deciders**: maintainer + UX-UI review (step 4)
**Context docs**: `../reviews/27-06-2026-ux-ui-review.md` (findings UX-1…UX-9 + the help audit);
`../design.md` §7 (command table — centre of gravity); the launcher
[`../ux-ui-review-handoff.md`](../ux-ui-review-handoff.md)
**Related ADRs**: **0023 (command surface & UX — D1 refined here)**, 0018 (sharing 2×2),
0021 (lifecycle — `forget`, orphan `config validate`), 0016 (taxonomy — `project coords`),
0011/0015 (tags → DATA, `cco list`/`cco tag` surface)

---

## Context

ADRs 0018–0028 settled the *model* (4-bucket taxonomy, per-unit coordinates, the index, layered
reachability, sharing 2×2) and ADR-0023 settled the first cut of *how it is operated from the CLI*.
The pre-merge UX-UI review (step 4) evaluated the **shipped** surface (`bin/cco` + `lib/cmd-*.sh` +
`docs/users/reference/cli.md`) against the review-playbook §4 checklist (symmetry/learnability, no
duplicate paths, completeness/reachability, destructive-confirm, simple onboarding, inform-before-act)
and the principles (notably **P1/P6** — hide internal detail from the user).

A reachability sweep came back clean (no implemented-but-unreachable op, no broken wiring). The
defects are **coherence** defects: the listing surface means two different things, destructive
confirmation is applied inconsistently, the confirm-skip flag is spelled two ways, the help is
incomplete in places, and one verb family (`template`) is missing operations its siblings have. This
ADR records the decisions that fix them. It **refines ADR-0023 D1** (it does not reopen the model).

Two facts forced genuine decisions rather than doc-fills:

1. **`cco list` meant "tagged-resource dashboard", not "list things".** The top-level `cco list`
   iterated the tags registry (`tags.sh` `_tags_all`), so a user with projects but no tags saw
   *"no tagged resources yet"* — while the real listers were `cco <noun> list`. The word *list*
   therefore named two different operations in different places (review UX-1/UX-9) — the exact
   "same operation in different places" the maintainer wants removed.
2. **Destructive confirmation was ad-hoc.** `cco forget` previews the full cascade and always
   confirms (the gold standard); `pack remove`/`llms remove` confirmed **only** when the resource
   was still referenced (silent `rm` of an unused — possibly unrecoverable, e.g. `pack create`-
   authored — resource); `template remove` and `remote remove` confirmed **never** (review UX-3).
   The confirm-skip flag was `--force` in pack/llms but `-y/--yes` in forget/config/coords (UX-4).

## Decision

### D1 — One listing surface: `cco list [<kind>] [--tag]`; namespaces are operation-only (refines ADR-0023 D1)

**Rule the user learns:** *list things with `cco list [<kind>]`; act on a thing with
`cco <noun> <verb> [<name>]`.* Verb-first grammar is kept (git/docker convention; many ops have no
name yet — `create`, `install <url>`, `import <archive>` — so a `cco <noun> <name> <verb>` grammar
would break for them).

- **`cco list`** → cross-resource dashboard: every resource of every kind (projects, packs,
  templates, llms, remotes), grouped by kind, with a **TAGS** column and per-kind status (e.g. a
  project's running state, a pack's resource count). It **subsumes** the old tags-only `cco list`:
  tags become a column rather than the filter for inclusion.
- **`cco list <kind>`** → one kind only: `cco list projects|packs|templates|llms|remotes`
  (singular and plural accepted, forgiving).
- **`cco list [<kind>] --tag <t>`** → filter by tag, globally or within a kind. This gives tag
  filtering a single, predictable home (**resolves UX-9** — previously `cco list --tag` filtered
  while `cco <noun> list` listed, a split surface).
- **`cco <noun> list` is removed** from every family (`project`/`pack`/`template`/`llms`/`remote`)
  and replaced by a deprecation **stub** that redirects: `die "'cco pack list' was removed — use
  'cco list packs' (ADR-0029)."` — following the established precedent for removed verbs
  (`share`/`manifest`, `project publish`). The namespaces keep `show <name>` (single resource) and
  all mutating ops.

This **refines ADR-0023 D1**, which had listed `list`/`show` inside the `cco project` (and, by the
shipped symmetry, every other) namespace. `show` stays (single-resource op); only the **collection**
op `list` moves to the dedicated listing surface. Removing a namespaced `list` is a *refinement of
illustrative placement, not a reversal of the model* (same spirit as ADR-0023's own note on
relocating illustratively-named verbs).

**Why not keep `cco <noun> list` as a thin alias (the considered Option B):** it preserves muscle
memory at the cost of exactly the "same operation in two places" the review flagged; the maintainer
chose the clean single-surface (Option A) with redirecting stubs over the alias.

> **Addendum (2026-06-29, dogfooding follow-up C)** — host e2e surfaced three cosmetic/UX gaps in
> the listing surface; fixed as additive flags + a rendering fix that *refine* this D1 (no new ADR):
> - **`--sort tag`** added alongside `kind`/`name`. Tie-break: order by the resource's **first tag**,
>   **untagged resources sort last**, then by name. (llms/remote, which carry no tags, sort last.)
> - **Ascending/descending** spelled **`--reverse` / `-r`** (a boolean that flips the chosen order),
>   chosen over a `--sort <key>:desc` suffix for composability and convention.
> - **Column stability**: both the compact index and the rich `cco list packs` view now size the
>   NAME column dynamically and **ellipsize** overlong names (`…`), so a long name never shifts the
>   following columns (the reported "table wraps" symptom). The rich packs view also gained the
>   **TAGS** column its sibling kinds already showed (and a latent `grep -c` count-doubling bug that
>   split rows onto extra lines was fixed). Sorting/filtering packs by tag is served by the compact
>   index (`cco list packs --sort tag` / `--tag`).

### D2 — Uniform destructive-confirmation contract

Every **destructive or irreversible** action follows one contract, modelled on `cco forget`:

1. **Preview** what will be removed/changed (the resource and any id-keyed cascade: CONFIG copy +
   DATA provenance + STATE base/meta + tags binding) **before** acting.
2. **Confirm** interactively (`[y/N]`, default No).
3. **`-y` / `--yes`** is the canonical *skip-confirmation* flag, accepted **everywhere** a
   confirmation exists.
4. **`--force`** has a **distinct** meaning — *override a block* (remove a resource that is still
   referenced / in use, or overwrite an existing target on import) — and **implies `-y`**. It is not
   a second spelling of "assume yes".
5. **Non-interactive (no TTY) without `-y` → die** with a "re-run with `-y`" message (the `forget`
   rule), so a destructive action is never performed unattended by accident.

Applied: `pack remove` and `llms remove` confirm **unconditionally** (not only when referenced);
`template remove` and `remote remove` **gain** a confirm; `forget`, `config validate --fix`, and
`project coords --sync` already conform (they keep their behaviour). Non-destructive,
fully-regenerable cleanups (`cco clean` — `.bak`/`.tmp`/generated compose) keep their `--dry-run`
preview and need **no** confirm (audited OK). `cco config pull` keeps its fast-forward-only abort
(no auto-merge), audited OK.

### D3 — Verb symmetry across resource families

- **`cco tag remove`** is the canonical verb (aligns with `remote remove`, `pack remove`, …);
  **`rm`** is kept as a short alias.
- **`cco template` reaches parity with `cco pack`**: add **`cco template update <name>`** (update a
  template from its source, the pack-`update` analogue — supersedes the "future `cco template sync`"
  placeholder) and **`cco template validate [name]`** (structural validation, the pack-`validate`
  analogue). Template now mirrors pack: create · install · update · publish · export · import ·
  internalize · show · remove · validate (list → `cco list templates`, D1).
- The remaining family asymmetries are **intentional and documented**, not erased: a **project**
  has no `install`/`publish`/`remove` (it rides its code-repo remote and is deregistered with
  `cco forget` + git — P13/ADR-0018 D2); only **llms** has `rename` (its entries are auto-named from
  the URL, so renaming is a genuine llms need). Each family's help states its intentional gaps.

### D4 — `cco path` demoted (the index stays internal — P1/P6)

The machine-local index is **internal** (P6: hidden, CLI-only, never hand-edited). `cco path
set|list` is a deliberate manual-override escape-hatch, but surfacing it in the primary `cco` help
leaks an internal concept into the everyday surface. So: **`cco path` is removed from the top-level
`usage()`** and documented only under **`cco resolve --help`** as an advanced override. The command
itself is **kept** (no deprecation) — normal users meet only `cco resolve`; power users who need to
move directories / fix divergence / register an externally-installed repo still have it. (The
fuller "fold into `cco resolve --set/--list`" option was considered and deferred — more churn for
the same user-visible outcome at v1.)

### D5 — Help completeness, correctness & consistency

From the help audit (review §"Help audit"):

- **`cco join` is added to `usage()`** (it was dispatched but unlisted — a primary onboarding verb
  invisible in `cco help`).
- **Missing flags documented**: `cco update` (`--offline`, `--no-cache`, `--dry-run`),
  `cco resolve` (`--all`), `cco config` main help (`validate --dry-run`).
- **`cco llms` family help stops mixing subcommand options** into the dispatch-level help (it listed
  `install`-only options at the family level, unlike every other family) — options move to
  `cco llms install --help`.
- **`-h` is accepted as a `--help` alias** consistently across (sub)commands.
- **Help format is aligned** toward the richer "Usage + Arguments + Options + Examples" shape where
  a command has arguments/options; trivial commands keep a one-line form.
- **`usage()` regrouping**: `forget` reads as a lifecycle verb (the inverse of `init`/`join`), and
  `chrome` is a host-side tool — both are moved out of "Projects & Packs" into more fitting groups.

## Consequences

- **No file migration** (no tracked config file is renamed/moved; no `*_FILE_POLICIES` change). The
  CLI-verb removals are handled by `die` stubs, per existing precedent — not by `migrations/`.
- **`changelog.yml`**: additive entries for the new `cco list [<kind>] [--tag]` dashboard, the
  uniform `-y/--yes` + confirm contract, `cco tag remove`, and `cco template update`/`validate`.
- **Tests**: the suite is updated where it invoked `cco <noun> list` (now `cco list <kind>`), plus
  new tests for the dashboard, the added confirmations (interactive + non-TTY + `-y`), and the new
  template verbs. Green per step; baseline **921/0**.
- **Docs**: living re-sync of `docs/users/reference/cli.md` and the project `CLAUDE.md` command
  list to the new surface; **forward-annotate ADR-0023 D1** (its `list` placement is refined here).
- **Frozen-model intact**: P13 asymmetries (project ≠ pack), P5/P6 (config vs internal), and the
  sharing 2×2 are unchanged — this ADR only makes the *operation* of that model symmetric and safe.

## Alternatives considered

- **Listing — Option B (`cco <noun> list` kept as aliases to `cco list <kind>`):** zero breakage,
  but retains the duplicate listing path the review set out to remove. Rejected in favour of D1.
- **`cco path` — fold into `cco resolve --set/--list`** (remove `cco path` entirely): cleaner noun
  count, but more churn (stub + test rewrites) for the same user-visible result; deferred (D4).
- **`--force` as the single confirm-skip flag** (drop `-y/--yes`): rejected — `-y/--yes` is the
  conventional "assume yes" and `--force` is needed for the distinct override-a-block meaning (D2).
