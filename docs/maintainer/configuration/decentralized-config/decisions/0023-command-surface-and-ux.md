# ADR 0023 — Command Surface & UX: `cco config`/`cco project` namespace, validate contract, coordinate-add verbs

**Status**: Accepted (2026-06-19) — Group A; D4+ appended as Cluster 5 Groups B–E land
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

## Alternatives Considered

| Decision | Chosen | Rejected alternative(s) | Why |
|----------|--------|-------------------------|-----|
| D1 namespace | split `validate` by job; `cco config`=store, `cco project`=cwd unit | A-unified (one `cco config validate` does both jobs, only `coords` moves); B (umbrella, enumerate+annotate, no relocation); C (also move `protect` out) | A-unified keeps the cross-bucket verb the finding flags; B documents the overload without curing it; C renames the ADR-0020-settled `cco config protect` for marginal gain. The job-split alone gives each `validate` predicate-set the correct scope. |
| D2 validate contract | exit 0/1/2, one-line, presence-only + `--reachable`, docs-only hook, non-TTY no-op | binary 0/1 exit (B); table output (B); no `--reachable` in v1 (B); first-class hook installer `cco config protect --hook` (C) | B drops the per-class CI signal the finding asks for and resolves the presence-vs-network fork by omission; C adds git-hook-generation surface the codebase has no precedent for and leans hardest on P17. A reuses shipped patterns (`_prompt_for_path`, inline secret scan). |
| D3 add verbs | `cco project add <res>` + one-shot `--path`, url-from-origin | per-resource namespaces `cco repo add`/`cco llms add` (Shape B); path-inline + `verify`-sanitize (note Option 2) | Shape B scatters add across three homes and adds a top-level `cco repo` only for `add`; the sanitize flow re-adds removed complexity + a path-leak window (AD3/G8). Folding under `cco project` matches D1 and the user's own `cco project add repo` instinct. |

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
| `cco project validate` share-readiness contract (invocation/exit/output/agnostic-detection/`--reachable`/hook/non-TTY); `cco project add <repo\|mount\|llms\|pack>` + one-shot `--path` + url-from-origin; `cco project coords` relocation | **Build-new** (spec here; mechanism → E along P0–P5) |

## Open / cross-refs (Cluster 5 Groups B–E — appended as D4+ or `design.md` §7 refinements)

- **F49/F50** (Group B) — unresolved-start prompt copy + passive-⚠ next-step naming `cco project
  validate`; `cco update` discovery-flag division of labor (`--check`/`--diff`/`--dry-run`/`--news`).
- **F34/F47/F13** (Group C) — §6.2/§7 sharing-surface verdict split; template 2×2 vs scaffold-only;
  `cco project internalize` semantics clash (the §7 `internalize` row references this).
- **F18** (Group D) — `cco new` as an index-less ephemeral entry; **F25** — `extra_mounts` schema +
  the optional machine-agnostic `--target` of D3's `add mount`.
- **F27** (Group E) — `cco config protect` contract (kept under `config` here by D1; full content/
  location/ship-in-v1 decision in Group E).
