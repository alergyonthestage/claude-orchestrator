# P3 — Phase-3 launch handoff (legacy cutover)

**Purpose.** Launch **Phase 3 (legacy cutover)** in a fresh, clean session, now that **Phase 2
(migration & bootstrap) is CLOSED** (`c1e0369`→`767de86`, suite **1087/8** delta-green) and the
**P2→P3 adherence audit is DONE** (`reviews/23-06-2026-impl-adherence-review.md`: P2 fully conformant,
0 🔴 / 0 blockers). Phase 3 is **the big breaking deletion** — it removes the legacy vault/profile world
and lights up the **decentralized `<repo>/.cco/` runtime** that the migration (P2) made possible. This
file is self-contained: the **authoritative methodology**, the source-of-truth map, the reading order,
the mandatory preliminary analysis, the scope with exact symbols, the proposed build sequence, the
invariants, and what comes after. Produced 2026-06-23 on `feat/vault/decentralized-config` (commits
**local** — the maintainer pushes from the Mac).

```mermaid
flowchart LR
  P0["✅ P0 substrate"]
  P1["✅ P1 core local"]
  P2["✅ P2 migration & bootstrap"]
  P3["▶ P3 legacy cutover"]
  P4["P4 sharing core"]
  P5["P5 sharing ext"]
  P0 --> P1 --> P2 --> P3 --> P4 --> P5
```

---

## 0. The authoritative methodology (read first — applies to every P3 decision)

> **The `decentralized-config` design IS the law.** For **every** decision in this phase — what to
> delete, what to wire, where a datum lives, what a command does, how the UX reads — the **single
> authoritative reference** is, in this precedence order:
> 1. **`guiding-principles.md` (P1–P18)** — the cross-cutting principles. A choice that clashes with a
>    principle is a **defect to correct**, not a judgment call.
> 2. **The ADRs** (`decisions/0001`–`0025`) — the settled decisions, with their **forward-annotations**
>    (later ADRs refine earlier ones; honor the chain).
> 3. **The living `design.md`** (§2/§3/§4/§6/§7/§9 P3/§11) — the current/target truth.
> 4. **`requirements.md`** (AD*/FR*).
>
> **The more specific / more authoritative wins**; where this handoff and the living design diverge,
> **design §9/§11 + the ADRs win** (the P1 and P2 cycles each confirmed this — see the scope-forks).
> Record any reconciliation. **Do not invent, do not "improve" the design, do not re-open settled
> questions.** If implementation reveals a **genuine** design/sequencing gap, **PAUSE and discuss**
> (workflow rule) — never silently diverge.

**Non-negotiable build rules (carried from `Y-handoff-implementation.md` §1):**

1. **Build every module ONCE, in its final form.** Nothing built in P0–P2 is reworked; P3 deletes the
   legacy and wires the final decentralized runtime on the substrate already built.
2. **Breaking cutover (AD12): no dual-read, no deprecation window, no aliases for removed verbs.** New
   layout only. Develop on `feat/vault/decentralized-config`; `main` only at release.
3. **Each commit leaves `cco` runnable + the suite green** (delta-based — §5).
4. **Maintainer confirmation is required** on any choice that affects **how the toolkit is used**
   (UX wording, interface, bucket placement, sync strategy) — these are **not** derivable from code
   alone (P10 method-lesson b). Use `AskUserQuestion`, present options + a spec-grounded recommendation,
   **persist the decision** (ADR / design) **before** acting on it. *(P1 and P2 used this at every fork —
   keep it; the F49 prompt copy / divergence notice / source-transparency line / `cco config` messages
   are explicit HITL points below.)*
5. **Code-ground every claim** — re-read; line numbers drift; map writers/readers/consumers **incl.
   tests** before editing.
6. **bash 3.2 / macOS `/bin/bash`** throughout: no `declare -A`; guard empty arrays under `set -u`
   (`${arr[@]+"${arr[@]}"}`); awk for parsing; no Homebrew-bash features.
7. **Doc lifecycle** (`.claude/rules/documentation-lifecycle.md`): **P3 IS the shipped-behavior doc
   cutover sweep** — this is the phase where the README / guides / tutorial / FRs / index pages / the
   "Config Repo"→"sharing repo" sweep / the managed `memory-policy.md` are **finally rewritten to the
   shipped truth** (they were correctly held back until now). The driver/checklist is
   **`resource-coherence-inventory.md`**. Decision/analysis records (ADRs, reviews) stay immutable —
   forward-annotate, never rewrite.
8. **Self-development caveat** (`/workspace/.claude/CLAUDE.md`): edits to `config/entrypoint.sh`,
   `config/hooks/*`, `Dockerfile`, and the **managed** `defaults/managed/.claude/**` (incl.
   `memory-policy.md`) are **baked into the image** — **NOT active in the running session**. To test them:
   exit and `cco build && cco start` (or `docker build -t claude-orchestrator:latest .` from inside, aware
   it rebuilds the image the next `cco start` uses). **The compose↔entrypoint container-path contract is an
   invariant — change only the host-side compose generation; container paths stay fixed.**

## 1. Source of truth for P3

- **`design.md`** — **§9 Phase 3** (the scope spine), **§4.4** (the `cco start` source-selection &
  divergence ordered sequence — the re-sequenced D-start lands here), **§4.5/§4.6** (Cases A/B/C +
  sync-state), **§6.1** (Domain A — `cco config save/push/pull`, allowlist double-barrier, secret scan,
  non-blocking reminders), **§7** (command surface: the removed verbs + the transformed/NEW ones),
  **§2.2** (memory = STATE; tags = DATA), **§11 row 3** (the Phase-3 test contract + the existing-suite
  teardown). **§9 P4** for the boundary (what P3 must **not** delete yet — the manifest **code**,
  the `source`→DATA relocation, the sharing rewrite).
- **ADRs** — **0008** (sync mechanics: explicit manual semantic commits, `cco config push/pull`, pull
  non-FF → abort+notify, no auto-commit); **0009** (memory = machine-local STATE; **drop** the vault
  auto-commit D33 + `.gitkeep` D32 — GATE BL2 satisfied); **0010/0011** (profiles **removed** → **tags**:
  `cco tag add/rm` + `cco list --tag` over `<data>/cco/tags.yml`, tags are **internal DATA**, NOT in
  `~/.cco` and NOT in any manifest); **0015/0016** (tags = DATA bucket, the `!tags.yml` allowlist line
  **dropped**); **0017 D2** (`cco start` source precedence `--from` > `entry` > prompt; F49 unresolved
  prompt — never a silent launch); **0017 D4** (`~/.cco` always git-init'd, remote opt-in, private-default,
  public allow+warn); **0024 D3/D6** (cwd → **hosted** project; sync-set = whole committed `.cco/` minus
  `secrets.env`); **0018 D1** (nomenclature "config repo" → **sharing repo** — the doc sweep). **Principles**:
  **AD3/G8** (no real path in committed config), **AD12** (breaking cutover), **P14** (reachability
  layered, never hard-block), **P17** (permissions delegated to git), **H1** (resolution before
  notices), **H4** (host-side resolver guard).
- **`resource-coherence-inventory.md`** — **the doc cutover-sweep driver** (sections A config-editor +
  tutorial · B managed/CLAUDE.md/.gitignore · C docs · D archive). P3 executes it.

## 2. Context to load (reading order)

1. §0 above (the authoritative methodology). 2. `guiding-principles.md` (**P1–P18**).
3. `Y-handoff-implementation.md` (master: build method + full P0–P5 map + invariants + the v1 command
   surface + the **deferred-to-P4/P5** list). 4. **The recurring `implementation-review-handoff.md`**
   (esp. the **§4 Transitional Registry** — what dies in P3 vs what is still deferred to P4) **and the
   P2→P3 audit `reviews/23-06-2026-impl-adherence-review.md`** (its §"Phase-3 readiness" is the concrete
   deletion/rewire inventory). 5. `design.md` §9 P3 / §4.4 / §6.1 / §7 / §11 row 3 / §2.2. 6. ADRs
   0008/0009/0010/0011/0015/0016/0017/0024/0018. 7. `resource-coherence-inventory.md` (the doc sweep).
   8. Personal progress note `decentralized-config-impl-progress.md` (the live cursor). 9. The code P3
   deletes/rewires (§3 below).

## 3. Mandatory preliminary analysis (before writing code)

1. **Confirm baseline green-as-expected.** `git status` clean on `feat/vault/decentralized-config`; run
   the FULL **`CCO_ALLOW_HOST_RESOLVE=1 ./bin/test`** → **1087 passed / 8 failed** (the P2 end-state).
   A *different* failure set ⇒ stop and reconcile. **Always use the hatch** — without it 3–4 pure
   path-resolver unit tests fail on the H4 guard *by design* (the P2 audit reconciled this; not a
   regression).
2. **The P2→P3 adherence audit is DONE** (`reviews/23-06-2026-impl-adherence-review.md`) — read it; do
   **not** re-run a full audit. Verdict: P2 conformant, **T5 (base/meta) retired**, all other transitional
   hybrids correctly still present (registry §4). The deletion/rewire inventory there is your starting map.
3. **Read the actual current code** (line numbers drift — re-read, build the writer/reader/consumer map
   incl. tests):
   - `lib/cmd-start.sh` — the **central** read-path P3 replaces: `_start_resolve_project`
     (`project_dir=$PROJECTS_DIR/$project`) and `_start_generate_compose` (mounts
     `${project_dir}/.claude:/workspace/.claude` + `${project_dir}/project.yml`). The P1 reminder
     aggregator hook (`_start_emit_reminders` after `_start_resolve_paths`, H1) is the seam the D-start
     source-selection wires onto. The bucket re-point (Commit B) + overlays (T8) are already final.
   - `lib/cmd-vault.sh` — the whole vault surface to delete (init/save/diff/log/restore/status +
     `cmd_vault_profile_*` + remote/push/pull aliases + the `_auto_resolve_framework_changes` memory
     auto-commit D33 + `.gitkeep` D32 + the vault `.gitignore` mirror).
   - `lib/local-paths.sh` — the `@local` **sanitize/extract/restore/virtual-diff** plumbing to delete;
     **keep** the index-backed resolve/assert helpers (still consumed by `cco start`/`cco sync`). Remove
     the `cco project resolve` pointers in its error messages.
   - `lib/cmd-project-create.sh` — delete (`cco init`/`join`/`--migrate` replace it).
   - `lib/cmd-project-query.sh` / `lib/cmd-project-pack-ops.sh` — delete the superseded legacy
     `cco project resolve` / `cco project validate <name>` / `cco project add-pack` / `remove-pack`
     (kept transitional in P1; **die here**).
   - `lib/paths.sh` — any `_cco_profile_*` profile-detection helpers to delete; the legacy `CCO_*_DIR`
     consumers (drop them as their commands cut over — be surgical, keep the suite green).
   - `bin/cco` — remove the `vault)` arm + the `project create`/legacy-verb arms; add the `cco tag` +
     `cco config save/push/pull` arms.
   - `tests/helpers.sh` / `tests/mocks.sh` — the **dual-seed** + legacy `CCO_*_DIR` retire as their
     consumers go; **be deliberate** (the P0/P1 forks kept them precisely because dropping early broke
     delta-green — drop each only when its last legacy consumer is gone).
4. **Map the full consumer set incl. tests** before each deletion. The 5 P3-owned test files (§4) are
   **removed/rewritten** as their feature dies; the new P3 tests (config/tags/memory-as-STATE/
   multi-project/truthful-diff) are written **with** the code.
5. **Confirm the invariants (§6) + the evolving delta-green contract (§5) before the first edit.**

## 4. The 8 known baseline failures — P3 OWNS 5

Full list + rationale: `implementation-review-handoff.md` §4 / `reviews/23-06-2026-impl-adherence-review.md`.
P3 **removes** the 5 vault/profile failures (their files are deleted as the feature dies); the other 3
stay red until P4–P5.

- **P3 — remove THIS phase (5):** `test_vault_switch_to_main_shared_only`, `test_profile_show_active_profile`,
  `test_vault_move_preserves_unaccounted_files`, `test_vault_push_with_profile_syncs_shared`,
  `test_profile_create_preserves_unaccounted_files` (the §11 teardown: `test_vault_profiles.sh` removed,
  `test_vault.sh` shrinks to the migrate-reader).
- **P4–P5 — rewrite (3):** `test_resolve_name_from_full_variant_url`, `test_publish_ignore_path_patterns`,
  `test_project_internalize_updates_base`.

**End-of-P3 delta-green target = 3 failures** (the 3 P4–5). The 5 P3 failures **disappear** (their files
are deleted, not "turned green"); the new P3 tests must be green. A *new* red outside this trajectory =
a regression → stop.

## 5. P3 — scope (confirm against the code you just read)

Final form, build-once, breaking cutover (new layout only — **no dual-read, no aliases for removed
verbs**). Six work-streams; group into a few large coordinated commits (§5b).

### 5a. The decentralized `cco start` runtime + D-start source-selection (re-sequenced from P2-5)

This is the **enabling** change — it lights up the `<repo>/.cco/` layout the migration writes. Per
**design §4.4** (the authoritative ordered sequence) + **ADR-0017 D2 / 0024 D3**:
- **Replace the central read-path**: `cco start` reads `<repo>/.cco/project.yml` (cwd-first, AD6) instead
  of `$PROJECTS_DIR/$project`; `_start_generate_compose` mounts the decentralized `<repo>/.cco/` tree (the
  bucket destinations from Commit B / overlays from T8 are unchanged — only the **source** flips from
  central to `<repo>/.cco`).
- **cwd → hosted project** (ADR-0024 D3): from a repo dir, resolve the project that repo **hosts**
  (its `project.yml` `name`); a repo it only **references** needs an explicit name or `--from`; a
  host-nothing repo needs an explicit name.
- **Source precedence `--from <repo>` > optional `entry` repo > prompt** (Case-C divergence; ADR-0017 D2).
- **Unresolved member/mount → explicit F49 prompt** (`[r]esolve · [c]lone from <url> · [s]kip`), reusing
  `_prompt_for_path` — **never a silent empty mount**.
- **Divergence notice** (non-blocking) + **source-transparency line** `started <project> from <repo>
  [source: --from|entry|cwd]` + the passive ⚠ badge (P14, never a block).
- **Honor the ordered sequence (H1)**: resolve source → resolve members → resolve/clone unresolved →
  **only now** compute divergence + reminders → start.
- **HITL**: the **exact F49 prompt copy, the divergence notice wording, the source-transparency line** are
  maintainer-confirm (P10 lesson b) — present options + recommendation, persist.

### 5b. Legacy deletion (the breaking removal — safe because the migration exists)

Delete entirely (no aliases; `cco vault`/`cco project create` are **removed**, design §7):
- `lib/cmd-vault.sh` — the whole vault surface (init/save/diff/log/restore/status) + **all**
  `cmd_vault_profile_*` (create/list/show/switch/rename/delete/add/remove/move) + the deprecated
  vault remote/push/pull arms; remove the `vault)` case in `bin/cco`.
- **Profile/switch/shadow machinery** — the git-branch profile system + `profile-state/<branch>/`
  shadows + any `_cco_profile_*` in `paths.sh`.
- `lib/cmd-project-create.sh` — `cco project create` (+ its `bin/cco` arm).
- The **superseded legacy verbs** kept transitional in P1: `cco project resolve` /
  `cco project validate <name>` / `cco project add-pack` / `remove-pack`
  (`cmd-project-query.sh`/`cmd-project-pack-ops.sh` + their `bin/cco` arms). Update the
  `cco project resolve` pointers in `local-paths.sh` error messages → point to `cco resolve`/`cco path`.
- The `@local` **sanitize / extract / restore / virtual-diff / backup-trap** block in `local-paths.sh`
  (unnecessary under AD3 — the committed config is already path-free). **Keep** the index-backed resolve
  helpers + secret-scan + gitignore-heal.
- The **vault memory auto-commit** (`_auto_resolve_framework_changes`, D33) + `.gitkeep` tracking (D32) —
  memory is now machine-local STATE (ADR-0009; GATE BL2).
- As each command cuts over, retire its **dual-seed** + legacy `CCO_*_DIR` use in the harness
  (`tests/helpers.sh`) and code — **surgically, keeping the suite green** (drop each only when its last
  legacy consumer is gone; the P0/P1 forks kept them for exactly this reason).

### 5c. Tags wiring (over the P2-seeded DATA registry)

Per **ADR-0010/0011/0015**: wire `cco tag add/rm` + `cco list --tag <t>` over `<data>/cco/tags.yml`
(typed keys `{packs,projects,templates}`, already **seeded** at migration in P2). Tags are **internal
DATA**, **not** in `~/.cco`, **not** in any `project.yml`/`pack.yml`/manifest/index, **no** `!tags.yml`
allowlist line. `cco list [--tag]` reads the registry; authoring is direct edit / the CLI verbs.

### 5d. `cco config` — Domain A personal store (§6.1 / ADR-0008)

- `cco config save [-m]` — version `~/.cco` with the **allowlist double-barrier** (whitelist `.gitignore`
  `*` → `!packs/ !templates/ !global/.claude/` + `setup*.sh`/`mcp-packages.txt`/`languages`; **explicit-path
  staging, never `git add -A`**) + the **2-pass secret scan + `.example` exemption**. No auto-commit.
- `cco config push/pull` — explicit remote sync (private-default, public allow+warn — ADR-0017 D4);
  **pull non-fast-forward → abort + notify** (resolve in the IDE). Sync **transports commits, never
  fabricates them** (ADR-0008).
- `cco config validate [--dry-run|--fix]` — orphan-sanitization of global id-keyed internal state
  (ADR-0021; preview-first, warn-never-hide, never automatic) — *(may be minimal in v1 / coordinate with
  the P5 lifecycle work; confirm scope with the maintainer).*
- **HITL**: the `cco config save`/`push`/`pull` user-facing messages + the public-remote warning copy.

### 5e. `config-editor` template rehome + authoring (inventory A.1)

Rehome the `config-editor` project template to mount **`~/.cco`** (was `user-config/`); update its
`setup-pack`/`setup-project` skills (write into `~/.cco/packs|templates/`) and the `config-safety` rule
(`cco vault save` → `cco config save`). *(Template files — host-side; not baked.)*

### 5f. The shipped-behavior documentation cutover sweep (inventory-driven — design-authoritative)

**This is the phase that rewrites the shipped-behavior docs to the new truth** (doc-lifecycle §"timing").
Execute `resource-coherence-inventory.md` end-to-end — every rewrite states the **decentralized model as
defined by design.md + the ADRs** (no improvisation):
- **A**: `config-editor` (5e above) + `internal/tutorial/` substantial rewrite.
- **B**: the **managed** `defaults/managed/.claude/rules/memory-policy.md` ("vault-synced" →
  "machine-local STATE; cross-PC = future opt-in") — **baked, needs `cco build`**; CLAUDE.md; `.gitignore`
  (drop `/user-config/`, add `<repo>/.cco/secrets.env`).
- **C**: README, user guides, the "contract" docs, onboarding, the ~43-occurrence **"Config Repo" →
  "sharing repo"** sweep (ADR-0018 D1), docs index pages, the ADR-0024 shipped-behavior additions.
- **D**: **archive** the removed-feature maintainer-design subtrees to `_archive/` (doc-lifecycle;
  re-home any surviving concepts into living docs first).

## 5g. Proposed build sequence (P3-1 … P3-N — confirm with the maintainer)

Cutover = a few large, coordinated commits (the deletions/rewirings are coupled), each full-suite
delta-green before+after. Read the actual current code at the start of each commit (line numbers drift).
**This sequence is a recommendation — the maintainer approves/edits it before P3 starts** (as was done
for P2-1…P2-5).

| # | Commit | Scope (from §5) | Delta-green | Status |
|---|--------|-----------------|-------------|--------|
| **P3-1** | decentralized `cco start` + D-start | 5a — flip the read-path to `<repo>/.cco/`, cwd→hosted, `--from`/`entry`/prompt precedence, F49 unresolved prompt, divergence notice + source-transparency + ⚠, H1 order; new `test_start_*` | 8 (no new red) | ✅ `36660fd`+`365d16f` |
| **P3-2** | tags + `cco config` | 5c + 5d — `cco tag add/rm` + `cco list --tag`; `cco config save/push/pull` (validate → P5); new `test_tag.sh`/`test_config.sh` | 8 | ✅ `548f2e5`+`f7f41c1` |
| **P3-3** | legacy deletion *(large, coordinated)* | 5b — delete vault/profiles/sanitize/memory auto-commit; remove `bin/cco` arms; **remove** `test_vault_profiles.sh`+`test_vault.sh`; new coexistence/truthful-diff/memory-as-STATE tests. **Tier-2 verbs + `@local` block + `cco project create` SPLIT OUT** (tier-2/@local → P4; create → P3-3b) | **8 → 3** | ✅ `a76e1f6` |
| **P3-3b** | `cco init` scaffold + delete `cco project create` | ADR-0026 — `cco init` = idempotent global-ensure (`~/.cco/global`) + per-repo `<repo>/.cco/` scaffold + index-register; §3b marker-gate non-destructive `cco update`; delete `cco project create`. **Build re-sequenced (Option B): c1 global-home cutover `GLOBAL_DIR`→`~/.cco/global` + `init_global` helper · c2 init transform** (see `P3b-handoff-init-scaffold.md`) | 3 | ✅ `9e15924`+`35f5797`+`d9e44a2` |
| **P3-4** | config-editor rehome | 5e — template + skills + `config-safety` rule | 3 | ⏳ next (`P3cd-handoff-config-editor-and-docs.md`) |
| **P3-5** | doc cutover sweep | 5f — inventory A–D end-to-end (incl. managed `memory-policy.md` → needs `cco build`); "Config Repo"→"sharing repo"; archive removed-feature design subtrees | 3 | ⏳ |

UX copy (F49 prompt, divergence notice, source-transparency line, `cco config` messages, public-remote
warning, profile→tag already done in P2) is **maintainer-confirmed at build time per commit** (P10
lesson b) — present options + a spec-grounded recommendation, then persist.

## 6. Invariants (never violate)

- **AD12 breaking cutover** — new layout only; **no dual-read, no aliases** for removed verbs.
- **AD3 / G8** — no real path ever enters committed config; `git diff` on `.cco/` stays truthful (the
  `@local` sanitize machinery is deleted precisely because the committed config is already path-free).
- **H1** — any divergence/reminder computed **after** member resolution (the §4.4 ordered sequence).
- **H4 host-side resolver guard** + the **compose↔entrypoint container-path contract** — change only the
  host-side compose **source**; container paths stay fixed; `entrypoint.sh` container side unchanged.
- **Memory = STATE, no auto-commit** (ADR-0009); **tags = DATA, never in config buckets/manifests**
  (ADR-0010/0015); **`~/.cco` always git-init'd, allowlist double-barrier, never `git add -A`**
  (ADR-0008/0017 D4).
- **P14** reachability layered, **never a hard block**; **P17** permissions delegated to git.
- **Do NOT undo the P4-deferred transitionals** — the `source` provenance stays at `<repo|pack>/.cco/source`
  read **in place** (the →DATA relocation + `url`/`ref`/`resource` rename + `publish_target` re-derivation
  is **P4**); the **manifest code** + structure-based discovery is **P4** (the inert `manifest.yml` files
  are cleaned by this cutover, but `lib/manifest.sh` + `cco manifest` are deleted in **P4**, discovery-
  before-delete). See the Transitional Registry (`implementation-review-handoff.md` §4).

## 7. Explicitly NOT in P3 (deferred — do not build/delete here)

The **sharing rewrite** (P4): `source`→DATA relocation + field rename + `publish_target` re-derivation
(ADR-0022 D1); manifest **code** removal / structure-based discovery / `lib/manifest.sh` + `cco manifest`
deletion (discovery-before-delete, F14); sync-before-publish 3-way merge fix; 2×2 verb wiring;
project-publish/install removal. **P5**: 3-layer pack resolution, internalize (`--as`),
`export --bundle-packs`, `cco update --check`, `cco forget` + delete-cascade, `cco project validate` full
contract + `cco config validate [--fix]` orphan-prune (full), `cco config protect` helper. See
`Y-handoff-implementation.md` §6 for the full deferred list.

## 8. After P3 — proceeding

Phase 3 leaves the **decentralized runtime live** and the legacy world gone — `cco start` reads
`<repo>/.cco/`, `cco config`/`cco tag` replace the vault, memory is STATE, and the shipped docs tell the
truth. Next: **Phase 4 — sharing core** (manifest removal code/data split, sync-before-publish fix, 2×2
verbs, `source`→DATA relocation, "config repo"→"sharing repo" code paths). Re-read the spec, run the same
delta-green loop (the FAIL set keeps shrinking from 3 as the sharing tests are rewritten), dedicate a
**clean session**, and **pause + maintainer-confirm** any UX/interface/placement decision. Run an
**adherence audit** (`implementation-review-handoff.md`) at the P3→P4 boundary first.

## 9. Developer note — pre-merge validation (not part of P3 code)

Before `develop`/`main` merge, the migration must be validated **end-to-end in a sandbox** on a copy of
the real vault (`P2-dogfooding-validation.md`, recipe §3 — `CCO_USER_CONFIG_DIR` + `CCO_*_HOME` +
HOME-flip). **Rule: never accept the legacy-vault offer-to-remove until merged + validated.** This is a
dev-process step on the Mac (this session runs in the container).
