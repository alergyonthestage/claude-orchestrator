# ADR 0023 — Command Surface & UX: `cco config`/`cco project` namespace, validate contract, coordinate-add verbs

**Status**: Accepted (2026-06-19) — Cluster 5 **complete** (Groups A–E, D1–D6)
**Deciders**: maintainer + impl-readiness review (V), Cluster 5
**Context docs**: `../design.md` §7 (command table — centre of gravity), §2.4/§3/§4.4/§6.2; `../requirements.md`; `../reviews/18-06-2026-impl-readiness-review.md` (F46/F26/F19 + the Cluster-4 carry-ins F48/F45/F29-D4)
**Related ADRs**: 0008 (`~/.cco` versioning — `config save/push/pull`), 0016 (taxonomy — D3 coords tooling, D9 validity contract), 0017 (CLI lifecycle — D1 coordinate fields, D2 `cco resolve`/`--from`), 0019 (reachability — D2 layered embed/heal/validate), 0020 (permissions — D4 `cco config protect`), 0021 (lifecycle — §5 orphan sanitization), 0022 (D4 pack-collision ERROR row carried by validate)

---

## Context

The impl-readiness review (V), Cluster 5, owns the **command surface & UX**: the exact subcommand
taxonomy, the `cco … validate` contract, and the coordinate-add verbs. The model underneath (4-bucket
taxonomy, per-unit coordinates, the index, the layered reachability) is **settled** by ADRs 0008–0022
and is **not** re-opened here; what Cluster 5 fixes is how that model is **operated** from the CLI.

Two cross-cutting facts forced a genuine decision rather than a doc-fill:

1. **`cco config` spanned three scopes under one noun** — `~/.cco` (`save`/`push`/`pull`, ADR-0008),
   the cwd project's `<repo>/.cco` (`coords`, share-readiness `validate`, `protect`), and the global
   internal buckets (orphan `validate`, ADR-0021 §5). The noun did not tell the user which bucket a
   verb touched (review F46).
2. **`validate` carried two unrelated jobs on one verb** — *orphan-sanitization* of id-keyed internal
   state (ADR-0021 §5, **global** scope) and *share-readiness* of a project's referenced coordinates
   (ADR-0016 D9 / ADR-0019 D2 / ADR-0022 D4, **per-project** scope). The Cluster-4 carry-in asked for
   "one validate contract"; on inspection the two jobs have **incompatible scopes** (one scans all
   internal buckets, the other validates a single `project.yml`), which is the very grab-bag overload
   F46 names.

This ADR records the three Group-A decisions (D1–D3). The remaining Cluster-5 findings (F49/F50 UX
copy, F34/F47/F13 sharing-surface accuracy, F18 `cco new`, F25 `extra_mounts`, F27 `protect`) land as
D4+ here or as `design.md` §7 refinements as each Group is resolved.

## Decision

### D1 — Namespace taxonomy: `cco config` = personal/global store; `cco project` = the cwd project; split `validate` by job (review F46 — Option A, refined)

Encode the bucket in the **noun** for the dominant case, and split the dual-job `validate` **by job**,
not merely relocate it:

- **`cco config` = the personal/global store** (`~/.cco`) **and** global internal-state hygiene:
  - `cco config save` / `push` / `pull` — `~/.cco` versioning + remote sync (ADR-0008, names kept
    byte-for-byte).
  - `cco config validate [--dry-run | --fix]` — **orphan-sanitization only** (ADR-0021 §5): detect/
    report (and, with `--fix`, preview-first prune) orphaned id-keyed internal entries
    (tags/source/index/cache/token with no resolvable resource). Global scope; STATE/CACHE freely
    rebuilt, DATA pruned only on confirm. **It no longer carries the share-readiness predicates** — those
    move to `cco project validate` (D2).
  - `cco config protect` — the **one documented exception**: a `<repo>/.cco` governance scaffold
    (ADR-0020 D4, name kept verbatim). Annotated in §7 as the single `config` verb that operates on the
    cwd repo rather than `~/.cco`, justified because it intrinsically "protects the config." Its full
    contract is **Group E / F27**.
- **`cco project` = the cwd project's `<repo>/.cco`** (cwd-first; explicit `<project>` accepted):
  - `cco project validate [project] [--all] [--reachable]` — **share-readiness only** (D2).
  - `cco project coords --diff [--sync --from <unit>]` — cross-unit coordinate consistency
    (relocated from `cco config coords`; ADR-0016 D3; `--sync` is explicit-`--from`, never auto-elect,
    ADR-0022/F48).
  - `cco project add <repo|mount|llms|pack>` — embed-at-add (D3).
  - plus the existing `resolve`/`list`/`show`/`export`/`import`/`internalize`/`delete` family.

**Rule the user learns:** *`cco config` = my personal/global store · `cco project` = the project I am
standing in · `protect` is the single annotated exception.* This **resolves F46** (noun→bucket
predictable), **scopes F26** (share-readiness is a `cco project` verb), and **resolves F53** (each
predicate set has exactly one home). It **reconciles the Cluster-4 carry-in**: the "one validate
contract" is the *share-readiness predicate set* (reachability + uniqueness + machine-agnostic +
ADR-0022 D4 pack-ERROR), now unified under **`cco project validate`**; orphan-sanitization was always a
separate job on a separate scope and keeps its ADR-0021 home. The ADRs that wrote `cco config
coords`/`cco config validate` named them **illustratively** with mechanism deferred to S/E (ADR-0016
D3/D9) — relocating them is a **refinement of illustrative naming, not a reversal**.

### D2 — `cco project validate`: the share-readiness contract (review F26 — Option A)

Pin the full I/O contract so E can write it as a contract test. **Detect-only** — no `--fix`; the
backfill path is `cco resolve` heal-at-resolve (ADR-0019 D2 layer-b).

- **Invocation**: `cco project validate [project] [--all] [--reachable]`, **cwd-first** (cwd/ancestor
  `.cco/project.yml` → validate that unit; else resolve `[project]` via the index; `--all` = every
  indexed project). Validates the unit's `project.yml` and any `~/.cco/packs/*/pack.yml` it references.
  No network by default.
- **Exit codes** (composable, highest-severity-wins, like `grep`): `0` clean · `1` reachability/
  coordinate gap (referenced id without a coordinate; under `--reachable`, an unreachable one) · `2`
  non-machine-agnostic content (absolute/real path) or duplicate id within a section. All failing
  classes are listed in the body; the exit code is the numeric max.
- **Output**: one line per failing id — `<section>.<id>: <reason>` — plus a one-line summary
  `validate: N error(s) across M id(s) [reachability=X agnostic=Y uniqueness=Z]`. Quiet on success
  unless `-v`. Greppable, not a table.
- **Machine-agnostic detection** (mechanical): flag a scalar leaf value of `project.yml`/`pack.yml` as a
  real/absolute path when it matches the anchored ERE `^(/|~|[A-Za-z]:\\)` after trimming quotes/
  whitespace — never applied to `url:` http(s)/git scheme values, never to the gitignored `secrets.env`.
  Heuristic, conservative (false-negatives over false-positives; P14 forbids hard-blocking), same
  philosophy as the `lib/secrets.sh` content scan. **This is the safety-net for D3's `--path` flow**: a
  hand-edited absolute path in `project.yml` is *reported* (exit 2), never silently stripped.
- **Reachable = presence-only by default** (offline/CI-safe, deterministic): "reachable" means the
  coordinate is present, well-formed, and unique — no network fetch. `--reachable` opts into a network
  probe (`git ls-remote --exit-code <url>` / HTTP HEAD for llms), offline-tolerant (timeout → "unknown",
  never a hard fail).
- **Pre-commit hook** (ADR-0016 D9 layer-d / ADR-0019 D2 layer-d): a **documented manual snippet** in
  the guides (`cco project validate || true >> .git/hooks/pre-commit`, non-blocking by `|| true`).
  **No installer command in v1** — mirrors the inline secret scan (no git-hook installer exists today).
- **Non-TTY heal**: heal-at-resolve is **TTY-interactive only**; in non-TTY/CI it is a no-op that emits a
  one-line notice (`note: <id> missing coordinate; run 'cco resolve' on a terminal to backfill`) and
  **never blocks** — mirrors `_prompt_for_path` (`lib/local-paths.sh:159`, already `return 2` on
  `! -t 0`). Gap detection moves to `cco project validate`, which is non-TTY-safe and exit-code-only.
- **Carries** ADR-0022 D4's single **ERROR** row (a no-coordinate authored-in-repo pack also present as
  `~/.cco/packs/X`); every other reachability/cache-degrades case is **WARN**. Exit-code only, never the
  git push path (P17).

### D3 — `cco project add <res>`: embed-at-add with one-shot `--path` (review F19 — Shape A + maintainer's note)

Fold all coordinate-embed verbs under `cco project add`, the namespace D1 establishes for the cwd
project's `<repo>/.cco`. This is the P14 **layer-a** ("embed-at-add", ADR-0019 D2) discoverable surface.

- **Verbs**: `cco project add repo|mount|llms|pack <name> [coordinate flags] [--path <path>]`, **cwd-first**
  (operate on the cwd project; explicit `<project>` / `--project` accepted). Coordinate flags per
  resource: repo `--url --ref`; mount `--readonly` (+ optional `--target`, see F25/Group D); llms `--url
  --variant`; pack `--url --ref`. The existing `cco project add-pack` is folded in as `cco project add
  pack` (the hyphenated form kept as an alias for one release).
- **Coordinate → manifest (CONFIG)**: `add` embeds `name` + coordinate into the cwd unit's `project.yml`
  (`pack.yml` for a pack authoring context). No real path ever enters the manifest (AD3/G8 preserved).
- **One-shot `--path` (machine-local STATE)**: when supplied, `add` *also* writes `name → expand(path)`
  into the STATE index (§3) in the same call — the one-step counterpart of the existing two steps
  (`add` coordinate, then `cco resolve --repo <name> <path>`, which already exists at
  `cmd-project-query.sh:259`). `--path` does **not** touch the manifest.
- **`url` auto-derivation from `origin`**: when `--path` points to an existing git clone and `--url` is
  omitted, derive the coordinate from `git remote get-url origin` (the ADR-0017 D1 origin rule, §2.4:293;
  reuse the origin-derivation already in `_sanitize_project_paths`, `lib/local-paths.sh:281`). No origin
  / ambiguous → leave the coordinate unset (a later `cco project validate` surfaces the gap).
- **`cco llms install` stays the CACHE-download primitive**; embedding a reference is `cco project add
  llms`. **No new top-level `cco repo` namespace** (F19's literal sketch) — repo-add lives under
  `cco project add repo`, so the add verbs share one home instead of three.
- **Rejected (the maintainer's own caution, review note Option 2)**: a "write the path inline in
  `project.yml`, then `verify` sanitizes it into the index" flow. It re-introduces the
  `_sanitize_project_paths`-on-commit step the new design deliberately removed (§3:381-382) and opens a
  **leak window** (committing `project.yml` before sanitizing leaks a local path into the shared
  `<repo>/.cco`), contradicting AD3/G8. `cco project validate` *detects* a hand-edited absolute path
  (D2, exit 2) but never strips it.

### D4 — Sharing-surface accuracy: verdict-faithful §6.2/§7, templates on the full 2×2, and `internalize` as the unified "sever-coupling" family (review F34/F47/F13, refined)

Three coupled sharing-surface corrections, plus a maintainer-refined model for `internalize`.

**(a) Verdict-faithful §6.2/§7 (F34).** `design.md` §6.2/§7 mislabel removed/refactored work as "revised"/
"transform". Reword by the per-element ADR verdicts: **REMOVED** = `cmd-project-publish.sh` +
`cmd-project-install.sh` + their `bin/cco` dispatch arms (project publish/install are deleted — ADR-0018
D2); **REFACTORED** = `cmd-pack.sh` (sync-before-publish, ADR-0022 D5), `cmd-remote.sh`/`remote.sh`
(sharing-repo endpoints, structure-based discovery); **DROPPED** = `lib/manifest.sh` (ADR-0012/0018 D3);
**BUILD-NEW** = pack `import`, project `export`/`import`, template `publish`/`install`/`export`/`import`
(b), `cco update --check`, sync-before-publish, structure-based discovery. Split the single §7 Sharing
"transform" row into Refactor / Build-new / Removed. §11 asserts both **presence** of the new verbs and
**absence** (clear rejection) of the removed ones (`project publish/install`).
> *Impl annotation (P4-4e, 2026-06-24): the REMOVED set also includes `cmd-project-update.sh`
> (`cco project update` — meaningless without the install model) and the current `cco project internalize`
> (retired per D4c, name reserved post-v1). `cco init --template` is the BUILD-NEW instantiation path
> replacing the removed project-install `--pick` template flow. See design §6.2.*

**(b) Templates keep the full 2×2 (F47 — Option A).** Templates retain `publish`/`install` +
`export`/`import` (ADR-0018 D2/D3 **as written**). The apparent contradiction with ADR-0019 D7
(templates "scaffold-only, no live reference") is resolved by **disambiguation, not reversal**: D2/D3
govern the template **artifact's distribution** (a reusable library living in `~/.cco/templates`,
distributed via a sharing repo exactly like a pack); D7 governs the **scaffolded output** (the
project/pack created via `--template` carries no coordinate back to the template and never auto-updates).
The "no live reference" D7 denies is the **scaffold→template link in a consuming manifest**, not the
template's own publish/install channel. Templates get **no referenced-resource coordinate** (P14 stays
packs/repos/llms only). E wires the four template verbs reusing the pack sharing path (`templates/*/` is
already in structure-discovery, D3). Add the missing §7 **Templates sharing** row.

**(c) `internalize` = sever the resource's external coupling — one family, two axes (F13, refined).**
The review's "net-new"/"Reuse" verdicts for `internalize` are factually wrong (**both verbs exist** —
`cmd_project_internalize`, `cmd_pack_internalize`) → **Refactor**. The deeper model (maintainer analysis,
validated): a referenced resource has **two orthogonal axes** —

- **Coupling** (the resource's *one* external tie): `internalize` **severs** it. The tie is realized
  differently per resource because their distribution models differ (P13), but the **intent is uniform**
  ("make it self-contained/personal"):
  - **pack / template (v1)** — the tie is the **upstream `url`** (update/publish). `internalize` **cuts
    the coordinate** from the manifest → the local copy becomes the authored source (P15 deliberate
    cord-cut); **drop the legacy `knowledge.source` copy step** (`cmd-pack.sh`, pre-coordinate model).
  - **project (post-v1, name reserved)** — a project has **no upstream** (it rides the code remote, P13);
    its external tie is **Axis-2 team-sharing**. `cco project internalize` = the **Case-C disconnect**
    (relocate `<repo>/.cco` → `~/.cco/projects`, ADR-0018 D6) — a coherent member of the same family, not
    a separate verb. This *strengthens* ADR-0018 D6's additive-by-construction framing by giving Case-C a
    name. The existing project-disconnect-from-central-source semantic is **retired** with the
    project-install model (ADR-0018 D2).
  - **fork variant**: `cco <res> internalize --as <newname>` creates an internalized copy while leaving
    the original **tracked/synced** (duplicate-then-cut).
- **Locality** (offline cache copy): a **separate** axis, **not** `internalize`. Copying a referenced
  pack into `<repo>/.cco/packs` as a **cache** (coordinate **kept** → still tracked) is the ADR-0019 D6
  internalize-as-**cache**, reached via the **opt-in resolve-time prompt** + the tar `export
  --bundle-packs`. **No standalone `vendor` verb in v1.** (Renaming away from "internalize-as-cache" is a
  D6 nomenclature refinement — the cache and the cord-cut are *orthogonal*, not opposite.)

**Inverses (no `un-internalize` verb).** Re-track a cut pack = `cco project add pack --url <x>` (**adopt**
an upstream; local becomes a cache) *or* `cco pack publish` (**publish your** copy as the new upstream) —
the two intents are disambiguated by the verb chosen; `cco project validate`/`show` surfaces the current
tracked-vs-authored state. Un-cache = delete the `<repo>/.cco/packs/X` dir (coordinate stays → resolves
upstream again). Un-disconnect a project (post-v1) = move `~/.cco/projects/<id>` back to `<repo>/.cco`.

**Presentation.** Move `internalize` **out of the 2×2** into a §7 **Lifecycle** line, documented
**per-resource** (because the mechanism differs even though the intent is uniform). `internalize` and
`add --url` redefinitions are **breaking** for existing users → migration + changelog + behavior-change
note (update-system.md).

### D5 — Entry points & schema: `cco new` index-less ephemeral; `extra_mounts` join the coordinate model (review F18/F25 + maintainer `url` extension)

**(a) `cco new` survives as an explicit index-less ephemeral escape hatch (F18 — Option A).** `cco new`
is a shipped top-level entry (spec FR-2.5/US-2; `bin/cco:141`/`lib/cmd-new.sh`) that takes literal
`--repo <path>` mounts and generates its own compose — the decentralized-config corpus never mentioned
it. Decided: it **survives unchanged in behavior**, as the deliberate "no config, no project, scratch
session" path. Contract for E:

- `cco new [--repo <path>]… [--name|--port|--teammate-mode]`: **literal** paths, **no** `project.yml`,
  **no** index read/write, **no** coordinates, no divergence/reminder logic.
- It shares the **Phase-0 compose/mount primitives** being rewritten with `cco start` — host-absolute
  mount sources (BL3), the host-side XDG resolver guard (H4), `GLOBAL_DIR`→`~/.cco/global/.claude` — but
  deliberately **stops short of H1 resolution** (no index lookup, no member resolution).
- **J0** (ADR-0017 D3) still bootstraps the four roots first on `cco new` like any command, but `cco new`
  writes **nothing** into the index. Ephemeral state (`claude-state`, `memory/`) lives in a trap-cleaned
  `mktemp` dir — STATE-class, never synced (ADR-0009).
- Edits: a §7 **Run** row for `cco new`; a §8/J0 note that J0 runs but the index is untouched; a Phase-0
  note pinning the shared-primitive-vs-skip-H1 boundary. (Formalizes the prior review M10 disposition.)

**(b) `extra_mounts` join the unified coordinate model (F25 — Option A + the maintainer's `url`
extension).** The new schema deferred to E (ADR-0016 §Open M5) is decided here. `§2.4` gave extra_mounts
only `name`+`readonly`, dropping the container target; the code uses `source:`/`target:` and
`yml_get_extra_mounts` (`yaml.sh:350`) requires both. New schema (uniform with `repos:`):

```yaml
extra_mounts:
  - name: shared-assets        # index key for the machine-local host path
    url:  git@github.com:org/assets.git   # OPTIONAL machine-agnostic coordinate (git-backed mount)
    ref:  main                            # OPTIONAL
    target: /workspace/assets             # OPTIONAL container path, default /workspace/<name>
    readonly: true                        # default true
```

- **Axis split** (AD3/G8): `url`/`ref`/`target`/`readonly` are machine-agnostic **config** (`project.yml`);
  the absolute **host path** is **STATE index**, keyed by `name` (exactly like `repos:`). The index keys on
  `name`, not on `target` as today.
- **Resolution**: `url` present → `cco resolve` offers *clone-from-`url`* (the repo mechanism); `url`
  absent → *specify-path* or **skip** (extra_mounts are non-essential by nature — skip is legitimate). An
  unreachable `url` on a shared project → `cco project validate` **WARN** (like repos).
- **No vendoring / no local cache** (maintainer-confirmed). extra_mounts follow the **repo no-cache rule**
  (`design.md` §2.4: *"`repos:` carry no local cache … never vendored; packs are the sole cache
  exception"*): an extra_mount's content is arbitrary **DATA**, not machine-agnostic config (P1/P6), and
  may be large — the `url` coordinate is the sole sharing mechanism, never a `<repo>/.cco` cache.
- **Migration** (P2): for each legacy `- source:/target:`, derive `name` (slugify the `target` basename,
  or prompt), write `name`+`target`+`readonly` (`url` absent — local-only), seed the index
  `name → expand(source)`. Rewrite `yml_get_extra_mounts` to parse `name`+`url?`+`ref?`+`target`(+default)+
  `readonly`; the resolver keys on `name`. `§3` notes the index supplies only the host path for an
  extra_mount `name`.

### D6 — `cco config protect`: documentation-only in v1; helper deferred with a pinned contract (review F27 — Option 1)

ADR-0020 D4 scaffolds a **`<repo>/.cco/CODEOWNERS`** — which **GitHub does not honor** (CODEOWNERS is
recognized only at repo root, `.github/`, or `docs/`), so the literal scaffold is a **no-op**; and the
ship-in-v1 decision was open. Decided (confirming the ADR-0020 §Open recorded preference):

- **v1 = documentation only.** Ship a governance guide (the sharing-repo read/write split, and the
  project-repo CODEOWNERS + host-ruleset setup, per host). The `cco config protect` **helper is a
  near-term opt-in addition, NOT scheduled in v1 E** — so an "optional" §7 row never silently becomes an
  "unscheduled" phase item. `cco config protect` stays under `cco config` (the D1 documented exception).
- **Pinned contract for the deferred helper** (so it is not re-litigated):
  1. **Location fix** — the scaffolded CODEOWNERS goes to a **host-recognized** path: repo-root
     `CODEOWNERS` (or `.github/CODEOWNERS` when a `.github/` dir exists), **never** `<repo>/.cco/CODEOWNERS`,
     with the rule line `/.cco/** @org/cco-maintainers`.
  2. **Host detection** from the code repo's `origin` URL (reuse the `*github.com*`-style parsing in
     `lib/remote.sh:35`; `--host` flag / prompt when `origin` is absent or unrecognized).
  3. **Per-host instruction strings** — GitHub: a branch **Ruleset** with fnmatch path `/.cco/**` +
     "require review from Code Owners"; Gitea: protected-branch file-pattern glob on `.cco/**`; GitLab:
     push rules are filename-regex only → a path-scoped block needs a **pre-receive** hook (advisory Code
     Owners noted as bypassable); generic git: a server-side **pre-receive** hook.
- **Presentation**: the §7 row is re-marked **"DOCS (v1) / helper deferred (post-v1)"**; §9/§12 state the
  helper is not a v1 E item. The footgun-surfacing check ADR-0020 D4 cites is the **`cco project
  validate`** share-readiness verb (renamed by D1), not `cco config validate`.

This honors P17 (cco assists, never gatekeeps — guidance is the purest assistance), removes the GitHub
no-op for v1, and keeps E's v1 scope to the S8 token-leak checklist + the governance guide.

## Alternatives Considered

| Decision | Chosen | Rejected alternative(s) | Why |
|----------|--------|-------------------------|-----|
| D1 namespace | split `validate` by job; `cco config`=store, `cco project`=cwd unit | A-unified (one `cco config validate` does both jobs, only `coords` moves); B (umbrella, enumerate+annotate, no relocation); C (also move `protect` out) | A-unified keeps the cross-bucket verb the finding flags; B documents the overload without curing it; C renames the ADR-0020-settled `cco config protect` for marginal gain. The job-split alone gives each `validate` predicate-set the correct scope. |
| D2 validate contract | exit 0/1/2, one-line, presence-only + `--reachable`, docs-only hook, non-TTY no-op | binary 0/1 exit (B); table output (B); no `--reachable` in v1 (B); first-class hook installer `cco config protect --hook` (C) | B drops the per-class CI signal the finding asks for and resolves the presence-vs-network fork by omission; C adds git-hook-generation surface the codebase has no precedent for and leans hardest on P17. A reuses shipped patterns (`_prompt_for_path`, inline secret scan). |
| D3 add verbs | `cco project add <res>` + one-shot `--path`, url-from-origin | per-resource namespaces `cco repo add`/`cco llms add` (Shape B); path-inline + `verify`-sanitize (note Option 2) | Shape B scatters add across three homes and adds a top-level `cco repo` only for `add`; the sanitize flow re-adds removed complexity + a path-leak window (AD3/G8). Folding under `cco project` matches D1 and the user's own `cco project add repo` instinct. |
| D4 templates | full 2×2 (F47-A, disambiguate D2/D3 vs D7) | export/import-only (F34-A) | export/import-only **reverses** the settled ADR-0018 D2/D3 (publish/install for templates) and loses the publish-template-to-a-team use case; disambiguation honors both ADRs verbatim. |
| D4 internalize | unified "sever-coupling" family, 2 axes (Coupling/Locality); project = Case-C, post-v1 | review F13-A (redefine project internalize = vendor referenced packs); 3-axis split (update/sharing/locality) | F13-A conflated the cord-cut with the cache (orthogonal axes, opposite coordinate effect — the UX confusion the maintainer flagged); the 3-axis split was refuted (no resource carries both update- and sharing-coupling, so update∪sharing is one axis realized per-resource). |
| D5 `cco new` | survives index-less (F18-A) | route through the index (B); drop (C) | B over-engineers a throwaway literal-path session (nothing to resolve, AD5-collision risk); C removes a Must capability outside the refactor's charter. |
| D5 `extra_mounts` | `target` config + optional `url` coordinate, no cache (F25-A + extension) | drop `target`, always `/workspace/<name>` (F25-B); add an opt-in vendor like packs | F25-B loses the existing arbitrary-target capability; vendoring extra_mount content violates the "packs are the sole cache exception" rule (repo-like content, possibly large DATA, not config). |
| D6 `protect` | doc-only v1, helper deferred + pinned contract (F27-1) | ship the helper in v1 (F27-2); print-only command (F27-3) | F27-2 overrides the ADR-0020 recorded preference + writes outside `.cco/` + adds low-frequency work to the v1 path; F27-3 is largely redundant with the doc baseline. Both fix the location no-op, which the pinned contract also does. |

## Consequences

**Positive** — the command surface is learnable (`cco config`→personal/global, `cco project`→cwd unit,
`protect` the lone annotated exception); each `validate` job has one scope-correct home (resolving F46 +
F26-scope + F53 together); `cco project validate` is a contract E can test line-for-line and is the
keystone of P14 layers c/d; embed-at-add becomes one discoverable verb family with a one-call
coordinate-and-path ergonomics that reuses the existing index writer and origin-derivation; AD3/G8
(truthful `git diff`) is preserved because no path ever enters a manifest.

**Negative** — two `validate` verbs (`cco config validate` orphan vs `cco project validate`
share-readiness) coexist; mitigated because they answer different questions on different scopes ("is my
internal bookkeeping clean?" vs "is this project share-ready?"). Relocating `coords`/`validate` out of
`cco config` and folding `add-pack` → `add pack` touches the ADRs' illustrative naming (refinement, not
reversal) and needs a guide/snippet pass (the pre-commit hook line becomes `cco project validate`).
D3's `add <res>` is net-new verb wiring across `cmd-project-*`.

## Reuse / Drop / Build-new

| Element | Verdict |
|---------|---------|
| `cco project resolve --repo/--mount <name> <path>` index writer (`cmd-project-query.sh:259`); the `_sanitize_project_paths` **origin-derivation** half (`local-paths.sh:281`); `_prompt_for_path` non-TTY guard (`local-paths.sh:159`); `lib/secrets.sh` heuristic-scan philosophy; the `cco sync --from` precedent for `coords --sync` | **Reuse** |
| `cco config coords` / share-readiness `cco config validate` naming; the path-in-`project.yml` → sanitize-on-commit flow (already dropped by §3 D4); F19's separate top-level `cco repo` namespace; `cco llms install`'s embed side-effect (`_llms_add_to_yaml`) once `add` exists | **Drop / repurpose** |
| `cmd_pack_internalize` / `cmd_project_internalize` (verbs exist; cut to the coupling-family semantics); pack sharing path (templates reuse it for the four template verbs); `cco new` literal-path compose/mount (shares the P0 primitives with `cco start`, skips H1); `yml_get_extra_mounts` parser (extend to `name`+`url?`+`ref?`+`target`+`readonly`) | **Refactor / Reuse** (not net-new — corrects ADR-0019 D3/D4 verdicts; `cco new` keeps its behavior) |
| `cmd-project-publish.sh` + `cmd-project-install.sh` + their `bin/cco` arms (project publish/install removed, ADR-0018 D2); the `knowledge.source` copy step in `cmd_pack_internalize` | **Drop** |
| `cco project validate` share-readiness contract (invocation/exit/output/agnostic-detection/`--reachable`/hook/non-TTY); `cco project add <repo\|mount\|llms\|pack>` + one-shot `--path` + url-from-origin; `cco project coords` relocation; template `publish/install/export/import` (reuse pack path); `internalize --as` fork; `cco project internalize` Case-C (post-v1) | **Build-new** (spec here; mechanism → E along P0–P5) |

## Open / cross-refs (Cluster 5 — all groups RESOLVED)

- **F49/F50** (Group B) — **RESOLVED 2026-06-19** as `design.md` refinements (no ADR D-section):
  §4.4 named unresolved-start affordances + source-transparency print + passive-⚠ naming `cco project
  validate`; §6.2 `cco update` discovery-flag division-of-labor table + `--dry-run` scope
  disambiguation. The illustrative `cco config validate` next-step was renamed to `cco project validate`
  (D1).
- **F34/F47/F13** (Group C) — **RESOLVED 2026-06-19** (D4): verdict-faithful §6.2/§7; templates on the
  full 2×2 (disambiguate D2/D3-distribution vs D7-scaffold-output); `internalize` = unified sever-coupling
  family (pack/template cut-url v1 + `--as` fork; project = Case-C, post-v1) with the cache on a separate
  Locality axis. Forward-annotations: ADR-0018 D6, ADR-0019 D3/D7.
- **F18/F25** (Group D) — **RESOLVED 2026-06-19** (D5): `cco new` survives index-less (shared P0
  primitives, skips H1); `extra_mounts` join the coordinate model (`name`+`url?`+`ref?`+`target?`+
  `readonly`, host path in the index, no cache/vendor). Forward-annotation: ADR-0016 §Open (M5).
- **F27** (Group E) — **RESOLVED 2026-06-19** (D6): `cco config protect` is **doc-only in v1**; the
  helper is deferred with a pinned contract (host-recognized CODEOWNERS location, origin host-detection,
  per-host strings). Kept under `cco config` (D1). Forward-annotation: ADR-0020 D4.
