# P3-3b — `cco init` scaffold + delete `cco project create` (launch handoff)

**Purpose.** Launch **commit P3-3b** in a fresh session, after **P3-1/P3-2/P3-3 are DONE** (the
decentralized `cco start` runtime, `cco tag`/`cco config`, and the **vault/profile world removed** —
baseline **949 passed / 3 failed**). P3-3b transforms `cco init` into the decentralized project entry
point and deletes the now-replaceable `cco project create`. The architecture is **decided — ADR-0026**
(the maintainer proposed it, the implementer validated it). This file is self-contained. Produced
2026-06-23 on `feat/vault/decentralized-config` (commits **local** — maintainer pushes from the Mac).

## 0. Authoritative methodology (unchanged from the P3 handoff)

The **`decentralized-config` design IS the law**, in precedence order: `guiding-principles.md` (P1–P18)
→ the ADRs (now incl. **0026**) → living `design.md` → `requirements.md`. The more
specific/authoritative wins; **record any reconciliation**; a genuine design gap ⇒ **PAUSE and discuss**
(this is how ADR-0026 itself was produced). Non-negotiables: **build-once final form**; **AD12 breaking
cutover** (new layout only, no dual-read, no aliases for removed verbs); **each commit leaves cco
runnable + the suite delta-green**; **maintainer-confirm** any UX/interface/placement choice (present
options + a spec-grounded recommendation, persist, then act); **code-ground every claim** (line numbers
drift — re-read); **bash 3.2 / macOS** throughout; **doc lifecycle** (shipped-behavior docs ride the
P3-5 sweep, NOT P3-3b); **self-development caveat** (edits to `config/`, `Dockerfile`, managed
`defaults/managed/**` are baked — not live this session).

## 1. The decision to implement — ADR-0026 (read it first)

`decisions/0026-cco-init-global-and-project-scaffold.md`. In short: **`cco init` is the single project
entry verb and idempotently bootstraps the global config on first use.** Run inside a repo it (1)
**ensures `~/.cco/global` from the framework defaults only if absent** (idempotent — skip when present),
then (2) **scaffolds the per-repo `<repo>/.cco/`** and registers it in the STATE index. Ownership:
**J0** = empty roots (ADR-0017 D3); **`cco init`** = global *content* for fresh users + project scaffold;
**`cco update`** = vault migration (ADR-0025). **No `cco setup` verb.** Required refinement: the
migration-idempotency gate moves from `~/.cco/global` presence to a **`migration-state` marker**, so
`cco update` stays runnable + **non-destructive** (backup + explicit confirm) after a fresh `cco init`.

## 2. Baseline & context to load

1. ADR-0026 (above). 2. `guiding-principles.md` P1–P18 (esp. P1 config-vs-internal, P6 hide-internal, P18
one-config-home). 3. `P3-handoff-legacy-cutover.md` (the parent P3 launcher — scope, invariants,
deferred-to-P4 list) + the personal progress note `decentralized-config-impl-progress.md` (live cursor).
4. `design.md` §7 (`cco init`/`join`/`migrate` rows + the §8 J0 note lines 725–732), §2.1 (committed
`<repo>/.cco/` layout), §2.3 (`~/.cco` layout), §3 (index), §9 P2/P3. 5. ADRs 0017 D3, 0025, 0021, 0012,
0024 D1. 6. The code in §4.

**Baseline check (do first):** `git status` clean on `feat/vault/decentralized-config`; run
**`CCO_ALLOW_HOST_RESOLVE=1 ./bin/test`** → **949 passed / 3 failed** (the 3 = P4–5 sharing baseline:
`test_project_internalize_updates_base`, `test_publish_ignore_path_patterns`,
`test_resolve_name_from_full_variant_url`). A different set ⇒ stop and reconcile.

## 3. Scope (build-once, AD12; group into coordinated commits if helpful)

### 3a. Transform `cco init` (`lib/cmd-init.sh`)

Today `cmd_init` (no `--migrate`) is the **legacy central global-init**: copies `defaults/global/.claude`
→ `$GLOBAL_DIR`, `mkdir $PROJECTS_DIR/$PACKS_DIR/$TEMPLATES_DIR`, `manifest_init`, builds the image; its
closing hint points to `cco project create` (`cmd-init.sh` ~76–191). Replace with the ADR-0026 entry
point:

- **Ensure-global (idempotent).** If `~/.cco/global/.claude` is **absent**: seed it from
  `$DEFAULTS_DIR/global/.claude` → **`$(_cco_config_dir)/global/.claude`** (retarget from `$GLOBAL_DIR`),
  apply the language substitution, copy `setup.sh`/`setup-build.sh`/`mcp-packages.txt` →
  `~/.cco/`, decompose languages → `~/.cco/languages`, and build the **global STATE** meta/base via the
  existing helpers (`_cco_global_meta`/`_cco_global_base_dir`, already STATE-relocated in P2). If present
  → **skip** (a one-time no-op afterwards). **Emit no `manifest.yml`** (ADR-0012 — drop the
  `manifest_init` call; design §9 P4 "the new `cco init` never emits a manifest"). Keep the image build
  on this first-run path (skip under `CCO_SKIP_BUILD=1`, as today); on a project-only re-init, do not
  rebuild.
- **Scaffold `<repo>/.cco/`.** From `templates/project/base/`, write the committed tree (design §2.1):
  `<repo>/.cco/{project.yml, claude/, secrets.env.example, .gitignore}` (+ optional H5 `mcp.json`/
  `setup.sh`/`mcp-packages.txt` if the base template carries them). `project.yml` is the **base template
  with logical names only** (no real paths — AD3/G8). **Register in the STATE index**:
  `_index_set_path "<name>" "<repo>"` + `_index_set_project_repos "<name>" <members>` (reuse the
  `cmd-init.sh --migrate` / `cmd_join` index-register pattern). Name from `--name`, else the repo
  basename, else prompt; **refuse if `<repo>/.cco/` exists** unless `--force`. Run from the repo root
  (cwd). The secret-scan + `.gitignore`-heal helpers are reused (`secrets.sh`,
  `_cco_write_project_gitignore` in `migrate.sh`).
- Keep `cco init --migrate <project>` (the lazy vault-migrate mode, ADR-0021) and `--lang`/`--force`
  flags. The legacy central paths (`$GLOBAL_DIR`/`$PROJECTS_DIR`/`manifest_init`) are removed from the
  clean path.
- **HITL**: the `cco init` output copy (what it created, the global-ensure vs project-only messaging) and
  whether `--name`/basename/prompt is the default naming — maintainer-confirm.

### 3b. Migration-idempotency gate → marker (ADR-0026 refinement)

`_cco_migrate_global` (`migrate.sh:245-254`) returns early when **`~/.cco/global/.claude` exists**
(line 254). Change the gate to the **`migration-state` marker** (`<state>/cco/migration-state`, the F43
file already used for the backup idempotency): migrate iff a **verified vault backup exists** AND the
marker has **no `global-migrated`** flag. When `~/.cco/global` already exists (e.g. a fresh `cco init`
ran first), make `cco update`'s migration **non-destructive**: **back up the current `~/.cco`** (a
restorable archive, mirror the existing raw-tar backup) and **ask explicit confirmation** before
populating from the vault; on success, set `global-migrated`. Keep `_cco_have_backup` (fresh install ⇒
no backup ⇒ no-op). Update the test contract in `test_migrate.sh` accordingly (the idempotency assertion
that currently keys on `~/.cco/global` presence).

### 3c. Delete `cco project create`

Delete `lib/cmd-project-create.sh` + the `create)` arm in `bin/cco` (and the `cmd-project-create.sh`
source line). Its dead vault-profile block (`:228-235`, already a guarded no-op) goes with it. Update
the usage hint. (Tier-2 verbs `cco project resolve/validate <name>/add-pack/remove-pack/delete` remain
**deferred to P4** — do **not** touch them here; ADR-0023 D3 / the P3 tier-split.)

### 3d. Migrate the test fixtures (delta-green)

`cco project create` is used as a **setup fixture** in six files **outside** the P3 teardown — they must
migrate or they red on its deletion:
`test_update.sh` (9), `test_publish_install_sync.sh` (13), `test_invariants.sh` (6), `test_tutorial.sh`
(4), `test_template.sh` (2), `test_secrets.sh` (2). Replace each `run_cco project create <name> …` setup
with the **harness `create_project "$tmpdir" "<name>" "$yml"` helper** (already decentralized — writes
`<repo>/.cco/` + seeds the index) or, where the test genuinely exercises *creation*, with `cco init`.
**Remove `test_project_create.sh`** (its feature is replaced by `cco init`); **extend `test_init.sh`**
(P2-rewritten) with the new contract: idempotent global-ensure (fresh seeds `~/.cco/global`; second init
skips it + only scaffolds), per-repo scaffold writes the committed tree + registers the index, refuse on
existing `.cco/`, no `manifest.yml` emitted, and the §3b non-destructive `cco update`-after-init path.

**Delta-green: stays 3** (no new reds; `test_project_create` removed, its coverage moves to
`test_init.sh`). Confirm full-suite `949-ish/3` before+after each commit (the pass count shifts as
fixtures move; the **3 P4–5 failures are the invariant**).

## 4. Code to read (re-read — line numbers drift)

- `lib/cmd-init.sh` — `cmd_init()` (the legacy global-init to transform; ~8–192) + the existing
  `--migrate` mode (delegates to `migrate.sh`).
- `lib/migrate.sh` — `_cco_migrate_global` (245-254, the gate), `_cco_populate_global_from` (179),
  `_cco_have_backup` / the `migration-state` marker (54-106), `cmd_join` (546, index-register pattern),
  `_cco_build_project_yml` / `_cco_write_project_gitignore` (the scaffold writers reused from migrate).
- `lib/cmd-project-create.sh` — the verb to delete (note what it writes, to mirror in the scaffold:
  project.yml from template, `.claude/`, base versions, name-uniqueness).
- `bin/cco` — `create)` arm + `cmd-project-create.sh` source line + usage.
- `templates/project/base/` — the scaffold source (project.yml shape, claude/ contents).
- `tests/helpers.sh` — `create_project` (decentralized, already updated) + `host_cco_dir`.
- The six fixture files (§3d) + `tests/test_init.sh` + `tests/test_project_create.sh`.

## 5. Invariants (never violate)

- **AD12** new layout only; **AD3/G8** no real path in committed config (`project.yml` logical names
  only; `git diff` truthful). **P18** one repo = one config home (`cco init` refuses a second host).
- **J0 owns roots; `cco init` owns global content (fresh); `cco update` owns vault migration** — the
  ADR-0026 split. **Idempotency is load-bearing**: global-ensure is a one-time no-op; the migration gate
  is the **marker**, and `cco update` is **never destructive** (backup + confirm).
- **No `manifest.yml`** from the new `cco init` (ADR-0012). **H4** host-side resolver guard +
  compose↔entrypoint contract unchanged. Memory = STATE; tags = DATA (untouched here).
- **Do NOT** delete the P4-deferred tier-2 verbs or the @local sanitize block (they die in P4 with their
  publish/install/query consumers — build-once; see the P3 handoff §7 + the Transitional Registry).

## 6. After P3-3b

- **P3-4** — rehome the `config-editor` project template to mount `~/.cco` (was `user-config/`); update
  its `setup-pack`/`setup-project` skills (write into `~/.cco/packs|templates/`) and the `config-safety`
  rule (`cco vault save` → `cco config save`). Host-side template files (not baked).
- **P3-5** — the shipped-behavior **doc cutover sweep** (inventory-driven, `resource-coherence-inventory.md`):
  README, user guides, tutorial, concepts/knowledge-packs, spec/architecture FRs, index pages, the
  "Config Repo" → "sharing repo" sweep, the managed `defaults/managed/.claude/rules/memory-policy.md`
  ("vault-synced" → "machine-local STATE; cross-PC = future opt-in") + `docs/reference/context-hierarchy.md`
  (managed-rule change needs `cco build`), and the Section-D `_archive/` move.
- Then **Phase 4 (sharing core)** — run an adherence audit (`implementation-review-handoff.md`) at the
  P3→P4 boundary first; the @local block + tier-2 verbs + `source`→DATA relocation + manifest code removal
  + sync-before-publish land there.

Next free ADR = **0027**. Pre-merge: dogfooding e2e validation on the Mac
(`P2-dogfooding-validation.md` §3) before develop/main; never accept the legacy-vault offer-to-remove
until merged + validated.
