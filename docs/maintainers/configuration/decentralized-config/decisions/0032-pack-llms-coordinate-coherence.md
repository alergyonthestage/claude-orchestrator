# ADR 0032 — Pack llms coordinate coherence: enforce the uniform `url` invariant

**Status**: Accepted (2026-06-29) — pre-merge **dogfooding follow-up (round 2)** (host e2e of `cave-web`/`cave-flow`); all decisions D1–D5 land pre-merge (nothing deferred)
**Deciders**: maintainer + dogfooding session
**Context docs**: `../../roadmap.md` §"Dogfooding findings"; dogfooding round-2 finding F2
(`cco pack validate cave-web` → `llms … not found (run 'cco llms install' first)`, a non-executable remedy)
**Related ADRs**: **0014/0016 D2 (uniform referenced-resource coordinate schema for `project.yml` AND
`pack.yml`)**, **0017 D1 (llms `url` is MANDATORY in v1)**, **0019 D2/D6 (unified boundary-less
reachability P14; packs are the SOLE cache exception *because* llms are always re-fetchable via their
mandatory url)**, 0023 D2 (`cco project validate` share-readiness contract), 0029 D2 (UX uniformity)

**Resolves**: an **implementation drift** from the coordinate-model invariant — `pack.yml` accepts
url-less (short-form) llms references, pack migration relocates packs wholesale without backfilling the
llms url, and `cco pack validate` checks only local presence (not url presence) — so a shared/migrated
pack is **not self-contained for its llms** and the validation remedy is non-executable. **Hands off**:
implementation (validate parity, pack migration, authoring/template, `cco resolve` llms heal).

> This ADR records the **closure of a drift**, not a new architecture: the uniform schema (ADR-0016 D2)
> and the mandatory-llms-url invariant (ADR-0017 D1) already cover `pack.yml`; ADR-0019 D6 *depends* on
> that invariant ("llms content … always re-fetchable, url mandatory"). The build enforced it for
> projects (embed-at-add `cco project add llms` requires `--url`, `cmd-project-add.sh`; project migration
> injects the url, `migrate.sh:732-743`) but left the pack side unenforced.

---

## Context

The decentralized model treats repos, llms, and packs as **referenced resources** carrying a
machine-agnostic coordinate in the versioned manifest (ADR-0014/0016 D2, P14). ADR-0017 D1 pins the
field semantics: repo `url` optional, **llms `url` MANDATORY**. ADR-0019 D6 makes packs the *sole*
vendor-as-cache exception with an explicit justification: *"llms content already lives in CACHE and is
always re-fetchable (url mandatory, ADR-0017 D1)."* The whole reachability model (P14) therefore
assumes every llms reference can be re-fetched from its coordinate.

Dogfooding round 2 (host e2e) exposed that the pack side never enforced this:

- **Schema/authoring**: `pack.yml` accepts the short form (`llms: - svelte`, no url). The base template
  shows the short form; `lib/yaml.sh` `yml_get_llms` explicitly documents "empty for short form / pack
  legacy entries".
- **Migration**: packs are **relocated wholesale** (`_relocate_legacy_pack_sources`; there is no
  `_migrate_write_pack_yml`; `migrations/pack/` is empty). The legacy `pack.yml` `llms:` section is
  carried verbatim — no url backfill, unlike project migration.
- **Validation**: `cco pack validate` → `_validate_llms_refs` (`lib/llms.sh:200`, called from
  `lib/packs.sh:298` **with the pack.yml as `$1`**) reads **names only** (`yml_get_llms_names`) and
  checks only local download presence. It does **not** flag a url-less llms, and its remedy —
  `run 'cco llms install' first` — is **non-executable** (`cco llms install` requires a url,
  `cmd-llms.sh:83`).
- **Heal**: `cco resolve` heals only repos + extra_mounts (`cmd-resolve.sh`); llms have **no heal path**.

Net effect: a pack whose llms were never installed on this machine has **no url anywhere** to re-fetch
from, breaking the ADR-0019 D6 premise and making the pack non-shareable for its llms.

## Decision

### D1 — Reaffirm and enforce the uniform invariant for packs
A `pack.yml` llms reference **must** carry a `url` (ADR-0017 D1, uniform schema ADR-0016 D2). A url-less
(short-form) pack llms reference is a **share-readiness gap**, not a valid steady state — the same status
a missing repo coordinate has for a shared project (ADR-0023 D2). This does not invent a rule; it closes
the gap between the decided invariant and the pack implementation.

### D2 — `cco pack validate` gains the llms reachability check (parity with `cco project validate`)
`_validate_llms_refs` already receives the manifest path (`$1`) and `yml_get_llms` already parses the
url — **no new parameter is needed** (correcting the round-2 analysis). The function switches from
names-only to url-aware:

- referenced llms **present locally** → ok (unchanged);
- referenced llms **missing locally, url present** → emit the **executable** remedy:
  `pack '<name>': llms '<n>' not installed — run: cco llms install <url> --name <n> [--variant <v>]`;
- referenced llms **missing locally, url absent** → emit a **reachability gap** (exit per the validate
  contract): `pack '<name>': llms '<n>' has no url coordinate — required to share/re-fetch`.

This aligns pack validate with `cco project validate`'s ADR-0023 D2 contract and the P14 layer-c
share-readiness check (ADR-0019 D2). It also fixes the broken remedy hint for projects (same function).
**`validate` only ever advises** — it prints the executable command and exit-codes the gap; it **never
mutates** (the heal action belongs to `cco resolve`, D5). This preserves the validate/resolve split
(advisor vs actor) established by ADR-0023 D2 / ADR-0017 D2.

### D3 — Pack migration backfills the llms url where recoverable (idempotent)
Add `migrations/pack/001_llms_url_backfill.sh` (`MIGRATION_ID=1`, idempotent): for each short-form /
url-less `pack.yml` llms entry, backfill `url` (+ `variant`) from the **global llms `.cco/source`**
(`$LLMS_DIR/<name>/.cco/source`) when present — the exact source project migration already uses
(`migrate.sh:732-743`). When the llms was never installed (no recorded source), the entry is left
url-less and **D2 validate surfaces it** for the user to add the url manually. This is honest about the
genuinely irrecoverable case (no migration can invent a url that was never recorded).

### D4 — Authoring embeds the url uniformly
The pack-authoring add-llms path and the `pack.yml` base template adopt the **long form with `url`**,
at parity with `cco project add llms` (`cmd-project-add.sh:145`, which already enforces it). New packs
never produce url-less llms references.

### D5 — Resolve symmetry: heal missing llms at `cco resolve` (P14 unification), not a new verb
Per P14 (repos/llms/packs are one reachability category) and ADR-0019 D2 layer-b (heal-at-resolve),
extend **`cco resolve`** to also heal missing **url-bearing** llms, mirroring the repo clone offer. A
separate `cco llms resolve` verb is **rejected** — it fragments the unified heal surface that
P14/ADR-0019 deliberately collapsed onto one verb.

The interactive offer is a **hybrid** (the repo-resolve analog applied to llms): for a referenced llms
whose content is missing on this machine and whose manifest entry carries a `url`, `cco resolve` prompts —

- **(i) install from `<url>`** (recommended) — download into CACHE via the `cco llms install` backend;
- **(ii) update the url** — the recorded `url` is wrong/moved: set a new url, then install from it;
- **(iii) skip** — proceed unresolved (a conscious skip, surfaced by the `validate`/passive-warn layers).

A url-less referenced llms (the share-readiness gap of D1/D2) offers only **specify a url** (then
install) or **skip** — there is nothing to fetch from yet. The non-interactive `cco start` keeps the
conscious-skip + warn behaviour it already uses for url-bearing packs (ADR-0019 D5/E-note); `cco resolve`
is the interactive actor, `validate` the advisor (D2).

> **Scope: all of D1–D5 land pre-merge** (maintainer directive, dogfooding round 2 — nothing deferred).
> Sequencing only: D2 (pack-validate semantics) precedes finding-F1's validate-output reformat since both
> touch `lib/packs.sh` validate.

## Alternatives Considered

| Alternative | Pros | Cons | Verdict |
|---|---|---|---|
| **Accept short-form pack llms** (amend ADR-0017 D1 to make pack llms url optional) | no schema tightening | breaks the ADR-0019 D6 premise (packs cease to be self-contained for llms); reopens a settled invariant; a shared pack silently can't resolve its docs | **Rejected** |
| **Separate `cco llms resolve` verb** | tactically symmetric with `cco resolve` | fragments the unified P14 heal surface; two heal entry-points to learn | **Rejected** (fold into `cco resolve`, D5) |
| **Message-only fix** (no validate parity, no migration) | smallest change | leaves the validate parity hole and the data gap; packs still not share-ready | **Rejected** (insufficient — D2/D3/D4 needed) |
| **Enforce uniform url + validate parity + migration backfill + resolve heal (chosen)** | restores the invariant; share-ready packs; executable remedy; honest about irrecoverable case | schema tightening + a pack migration + a `cco resolve` llms branch | **Accepted** |

## Consequences

**Positive** — packs rejoin the coordinate invariant (uniform with repos/llms/projects); `cco pack
validate` reaches parity with `cco project validate` (ADR-0023 D2 / P14 layer-c); the remedy hint becomes
executable (also for projects); ADR-0019 D6's "llms always re-fetchable" premise is restored; `cco
resolve` becomes the single heal verb for all referenced resources (P14). **Negative** — `pack.yml` is
tightened to long-form llms (template + authoring change, D4) and a new `migrations/pack/001` is added
(D3); `cco resolve` gains an llms fetch backend (D5); the genuinely irrecoverable case (an llms a pack
references that was never installed and whose url is unknown) still needs a manual url — but it is now
**surfaced** by validate instead of failing with a dead-end hint.

## Reuse / Drop / Build-new

| Element | Verdict |
|---|---|
| `yml_get_llms` (already parses url) | **Reuse** (D2 reads url from it) |
| `migrate.sh:732-743` llms-url-from-`.cco/source` pattern | **Reuse** (D3 applies it pack-side) |
| `_llms` install/download path | **Reuse** (D5 fetch backend) |
| `_validate_llms_refs` names-only check | **Refactor** — url-aware message + reachability gap (D2) |
| `cco resolve` repo/mount loop (`_resolve_unit`) | **Refactor** — add an llms heal branch (D5) |
| `migrations/pack/001_llms_url_backfill.sh`; pack add-llms long-form + base template | **Build-new** (D3/D4) |

## Open (deferred, not unresolved)

- Implementation: D2 message wording finalized against the F1 validate-output unification (this ADR
  fixes pack-validate *semantics*; finding F1 unifies pack/template/config validate *output format* —
  sequence F1 after D2 since both touch `lib/packs.sh` validate).
- `changelog.yml` #19 (additive: executable pack-validate llms remedy + reachability flag + `cco
  resolve` llms heal) and the `migrations/pack/001` entry — per `update-system.md`.
- **Post-merge (roadmap, separate analyses, do not reopen this ADR):** (1) a fuller `cco clean`
  resource-classification + default/subcommand redesign for the decentralized model (finding F4 is
  conservative-default + hint pre-merge only); (2) a `cco update` responsibility re-analysis (native
  cco update vs migrations vs team-shared resource updates, e.g. llms version bumps — explicit
  command separation vs maintained unification + subcommands) for the new architecture and later-added
  cached resources.
