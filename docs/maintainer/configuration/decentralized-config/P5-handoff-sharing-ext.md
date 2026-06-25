# P5 handoff — Sharing-ext + the deferred verbs — the final v1 phase

Self-contained launcher for a **clean session** (open after `/clear`) to build the rest of **Phase 5** —
the deferred-to-v1 command surface (lifecycle verbs, three-layer pack resolution, validation, protect)
on the Phase-4 substrate. The build P0–P4 + P4-doc are done; the schema bridge is collapsed to
index-only; the vault is gone; **the central `$PROJECTS_DIR`/`CCO_*_DIR` layout is gone too (P5-1)**. What
remains is the §3 lifecycle/sharing-ext command surface.

Branch `feat/vault/decentralized-config`, commits **LOCAL** (the maintainer pushes from the Mac).

---

## ⏩ RESUME STATUS (read this FIRST)

> **✅ PHASES 0–4 CLOSED + P5-0/P5-1/P5-2/P5-3/P5-4 DONE (2026-06-25). ▶ RESUME AT P5-5.** The §1 boundary audit ran
> (`reviews/24-06-2026-p4-p5-adherence-review.md`, Phase-4 fully conformant, 0 code 🔴) — **§1 is consumed,
> skip it.** P5 build order is maintainer-confirmed: P5-0 → P5-1 → P5-2 → P5-3 → P5-4 → **P5-5** → P5-6 →
> P5-doc → dogfooding; **index namespacing = POST-V1**.
>
> **P5-4 ✅ (`cco project validate` + `cco project coords`, 3 delta-green commits, suite 859→885/0):** P5-4a
> `48a44b0` (`cco project validate` share-readiness, ADR-0023 D2 + ADR-0022 D4 pack-collision ERROR;
> `lib/cmd-project-validate.sh`; cwd-first/by-name/`--all`; exit 0/1/2 max-severity; mounts included in the
> gap; `--reachable` opt-in offline-tolerant) · P5-4b `5f6c506` (`cco project coords` cross-unit consistency,
> ADR-0016 D3/F45/F48; `lib/cmd-project-coords.sh`; on-demand derive, `--diff` read-only, `--sync --from`
> in-place writer) · P5-4c `75c1377` (de-🚧 cli.md §3.14/§3.25 + config-mgmt + ADR impl-notes). **Live detail
> at the tail of `decentralized-config-impl-progress.md`.**
>
> **P5-3 ✅ (three-layer pack resolution + internalize + export --bundle-packs + template-vars, 4 delta-green
> commits, suite 843→859/0):** P5-3a `9c5986d` (`_pack_resolve_dir` mount order `~/.cco/packs`→`<repo>/.cco/packs`
> cache; start = warn+conscious-skip, NO layer-2 auto-fetch; rewired mount/packs.md/conflict/llms consumers) ·
> P5-3b `4961d87` (`pack internalize --as` fork + build-new `cco template internalize`) · P5-3c `b88bc18`
> (`project export --bundle-packs` closure + import-installs) · P5-3d `44199f9` (`init --template` full
> `{{VAR}}` over project.yml + whole `claude/` tree). **Deferred (not P5-3):** D6 interactive
> internalize-as-cache prompt at `cco resolve` + `cco update` cache refresh; `cco project internalize`
> (Case-C post-v1). ADR-0019 §Open forward-annotated.
>
> **Done so far:** **P5-0 ✅** `2f93de8` (llms name-derivation, baseline → 828/0). **P5-1 ✅ (P4-5d
> central-layout teardown, 4 delta-green commits):** P5-1a `95b7767` · P5-1b-1 `0da6153` · P5-1b-2
> `6209bae` · P5-1b-3 `7e9d458` · P5-1c `0116679` (central project layout fully gone; every project
> resolves via the STATE index). **P5-2 ✅ (`cco forget` + `cco config validate`, ADR-0021, 3 delta-green
> commits, suite 828→843/0):** P5-2a `ed2b7ee` (delete-cascade in pack/template `remove` + new
> `_tags_forget` primitive; remote already split, llms needs none) · P5-2b `d706226` (`cco forget
> <project>` — index/STATE/DATA/CACHE/tags deregister, shared-repo guard, preview+confirm/`-y`, repo
> untouched, scan self-heal) · P5-2c `93542cd` (`cco config validate [--dry-run|--fix [-y]]` orphan
> sweep — full predicate set, exit-0 report, STATE/CACHE main-confirm + synced-DATA second-confirm).
> The ADR-0021 §Open predicate-set item is RESOLVED + forward-annotated.

**Suite 885/0** — delta-green is measured against **ZERO** failures (any failure = regression). Run with
the hatch: `CCO_ALLOW_HOST_RESOLVE=1 ./bin/test` (`--file <name>` / `--filter <substr>` to scope).

**The `decentralized-config` design is the single SOURCE OF TRUTH**, precedence:
`guiding-principles.md` (P1–P18) → ADRs (0005–0027) → living `design.md` → `requirements.md`. The more
specific/authoritative wins; **record any reconciliation**; a genuine design gap ⇒ **PAUSE and discuss**.

**First actions (resume):** (1) `git log --oneline -15` + read the live progress note
`decentralized-config-impl-progress.md` (cursor: P5-4 done; **P5-5 scope** at the tail);
(2) re-confirm baseline **885/0**; (3) **skip §1 (audit consumed) — start P5-5** (`cco update --check`,
§3 below); per §0, **propose the sub-commit decomposition to the maintainer before coding.**

---

## 0. Authoritative methodology (the law — unchanged across the whole refactor)

- **Design governs.** Precedence as above. The build realizes the frozen design; it does not invent.
- **Build method** (Cluster-2 directive): **dependency + reuse + open-closed**, **build-once-in-final-form**,
  **breaking cutover** (no dual-read; ~2 known users). Removed verbs get **no alias** unless an ADR says so
  (**AD12**).
- **Delta-green per commit.** Each commit leaves cco runnable and the suite at the 1 known failure (no new
  reds). Decompose a co-dependent cutover into a few **large coordinated commits**.
- **Maintainer-confirm** any UX / interface / placement / sequencing choice (AskUserQuestion). Propose the
  sub-commit decomposition + any open reconciliations **before** coding.
- **Code-ground every claim** (re-read; line numbers drift). **bash 3.2 / macOS** (`/bin/bash`, guard empty
  arrays under `set -u`).
- **Self-development caveat:** edits to `config/`, `Dockerfile`, baked `defaults/managed/**` are NOT live
  this session (need `cco build`); `lib/`, `internal/`, `templates/`, `docs/` ARE host-side and testable now.
- **Lesson carried from P4-5c:** "bridge-fed" / "consumer of a removed thing" includes **runtime generators**
  (e.g. the config-editor project.yml) and **end-to-end tests whose name doesn't say so** (test_yaml_parser
  was full of `cco start` mount tests) — not just inline `create_project` fixtures. When you remove a code
  path, grep for *generators* and *e2e assertions*, not only direct callers.

---

## 1. The adherence-audit playbook (boundary check) — P4→P5 audit ✅ CONSUMED

> **✅ The P4→P5 boundary audit is DONE — `reviews/24-06-2026-p4-p5-adherence-review.md`** (Phase-4 fully
> conformant, 0 code 🔴). **A resuming session SKIPS this section and starts P5-2 (§3).** The playbook below
> is retained as the recurring reference for the **next** boundary (the P5→merge audit, §5). Baseline **828/0**.

Run the recurring **`implementation-review-handoff.md`** playbook (read-only, code-grounded, 4-state
classify ✅conformant/❌missing/🟡hybrid-intentional/🔴hybrid-error; the V multi-agent methodology, scaled to
the phase). Confirm before building P5:

1. **Baseline 827/1** by direct `--file` runs — the 1 = the P5 llms straddler, no 2nd regression.
2. **Phase-4 conformance** — sharing core (P4-1…P4-4) + the teardown (P4-5a/b/c) + P4-doc match design §6.2/§7/
   §9-P4 + ADRs 0018/0019/0022/0023; the schema bridge is index-only (no `@local`/`yml_get_repos` left);
   `cco config save/push/pull` + `cco tag` + sharing 2×2 conformant.
3. **Transitional Registry refresh** — most items are now RETIRED (vault, @local, tier-2 verbs, schema bridge,
   legacy parsers). What REMAINS transitional ⇒ the **P4-5d set**: harness dual-seed + legacy `CCO_*_DIR` in
   `bin/cco`, and the central `$PROJECTS_DIR/*/` enumeration in ~10 commands (`cmd-update`/`cmd-llms`/`cmd-pack`/
   `cmd-template`/`cmd-clean`/`cmd-chrome`/`cmd-stop`/`cmd-start:~1149`/`cmd-project-query`). Confirm no PREMATURE
   P5 cleanup happened.
4. **Doc-coherence** — shipped-behavior docs not rewritten ahead of code (the §6 commands below are mostly
   marked 🚧 planned in cli.md/configuration-management until built).

Commit the review under `reviews/` (e.g. `reviews/DD-06-2026-impl-adherence-review.md`) + refresh the
Transitional Registry + roadmaps. **If 0 🔴 / 0 blockers → Phase 4 CLOSED; proceed to P5. Else PAUSE + discuss.**

## 2. Context to load (reading order)

1. `guiding-principles.md` (**P1–P18**).
2. **This file.**
3. The live progress note **`decentralized-config-impl-progress.md`** (cursor: P5-4 done; **P5-5 scope** at the tail) + `git log`.
4. `design.md` **§9** (the P0–P5 phase map + per-phase test contracts; §11) and **§12** (deferred-post-v1: state-sync / local-llms / Case-C / namespacing) + the ADRs per item below.
5. `implementation-review-handoff.md` — the recurring audit playbook + the **Transitional Registry** (P0–P4 + P4-5d now retired).
6. The code (re-grep — line numbers drift).

## 3. Scope — Phase 5 (the §6 deferred list, on the P4 substrate)

> **✅ BUILD ORDER CONFIRMED (maintainer):** P5-0 llms-fix ✅ → **P5-1** P4-5d teardown ✅ → **P5-2**
> `cco forget` + `cco config validate` ✅ → **P5-3** three-layer pack resolution + `internalize` +
> `export --bundle-packs` ✅ → **P5-4** `cco project validate` + `cco project coords` ✅ → **▶ P5-5**
> `cco update --check` → **P5-6** `cco config protect` → **P5-doc** (remove the 🚧 markers as each ships) →
> **pre-merge dogfooding**. **Index per-project namespacing = POST-V1** (confirmed; global-flat stays,
> ADR-0022 D2). Per-unit: code-ground fresh (line numbers drift), decompose into sub-commits, confirm
> micro-UX with the maintainer, delta-green each commit.

Each item is its own dependency-ordered unit; **propose the sub-commit decomposition to the maintainer
before coding** (per §0). Remaining units:

- **P4-5d — central-layout → index teardown. ✅ DONE (P5-1, 2026-06-25).** Every command enumerates via the
  STATE index; `$PROJECTS_DIR`/`CCO_PROJECTS_DIR` + the bin/cco legacy branch + the harness dual-seed are
  gone; `cco update`'s project loop reads `<repo>/.cco/claude` and new projects are born-at-latest. Suite 828/0.
- **P5-2 — `cco forget` + `cco config validate` ✅ DONE (2026-06-25).** ADR-0021 Dec.2/3/4/5, 3 delta-green
  commits (`ed2b7ee`/`d706226`/`93542cd`), suite 828→843/0. `cco forget <project>` deregisters id-keyed
  internal state (index `projects:`+member `paths:` with shared-repo guard · STATE/DATA/CACHE `projects/<id>/`
  · `tags.yml`) — **repo untouched**, preview+confirm/`-y`, scan self-heal. Delete-cascade wired into
  `pack`/`template` `remove` (new `_tags_forget` primitive); `remote` already split, `llms` needs none.
  `cco config validate [--dry-run|--fix [-y]]` = full-bucket orphan sweep, exit-0 report, STATE/CACHE
  main-confirm + synced-DATA second-confirm. cli.md §3.4b/§3.21 + configuration-management.md de-🚧.
- **`cco project validate`** full share-readiness contract (ADR-0023 D2): cwd-first, exit 0/1/2, ERE
  machine-agnostic, presence-only + `--reachable`, detect-only/never-block, carries the ADR-0022 D4 pack
  no-coord ERROR row. **✅ DONE (P5-4a `48a44b0`).** `lib/cmd-project-validate.sh`; cli.md §3.14 de-🚧.
- **`cco update --check`** (DATA-source-driven + install-presence-gated 3-state, exit-0; ADR-0022 D6).
- **Three-layer pack resolution + `internalize` ✅ DONE (P5-3, 2026-06-25):** `_pack_resolve_dir` mount
  order `~/.cco/packs` → `<repo>/.cco/packs` cache (start = warn+conscious-skip, NO layer-2 auto-fetch —
  maintainer-confirmed); `pack internalize --as` fork + build-new `cco template internalize`;
  `project export --bundle-packs` closure + import-installs; `cco init --template` full `{{VAR}}` over
  project.yml + the whole `claude/` tree. **Deferred:** D6 interactive internalize-as-cache prompt at
  `cco resolve` + `cco update` cache refresh; `cco project internalize` (Case-C post-v1).
- **`cco project coords`** (cross-unit ADR-0016 D3, on-demand coords-lookup) — **✅ DONE (P5-4b `5f6c506`):**
  `lib/cmd-project-coords.sh`; bare lookup / `--diff` read-only / `--sync --from` in-place writer; F45 no-persist,
  F48 never-auto-elect; cli.md §3.25 de-🚧. **`cco config protect`** helper still PENDING (docs-only v1 today;
  ADR-0020 D4 / F27 pinned contract; P5-6).
- **index per-project namespacing** (ADR-0022 D2 — global-flat ratified for v1; namespacing post-v1) — confirm
  whether v1 or post-v1.
- **T = state-sync** (DATA/STATE cross-PC sync engine) — **post-v1**, owned by T; do NOT build in P5 unless
  the maintainer pulls it in.

## 4. Cross-cutting invariants (never violate)

- **4-bucket taxonomy** (ADR-0007/0015/0016): CONFIG `~/.cco` · DATA `~/.local/share/cco` (synced) · STATE
  `~/.local/state/cco` (machine-local: index, base/+meta, tokens, memory/transcripts) · CACHE (regenerable).
- **The STATE index is the sole name→path map** (the schema bridge is collapsed; no `@local`, no
  `local-paths.yml`, no `path:` in project.yml). **AD3/G8 — no real host path ever enters committed config.**
- **P13** projects ride the code-repo remote. **P14** reachability is layered + never a hard block.
  **Host-side resolver guard (H4)** + the **compose↔entrypoint container-path contract** are invariants.

## 5. Pre-merge to develop/main (the gate)

Full **dogfooding e2e on the Mac** (`P2-dogfooding-validation.md` §3) on a vault **copy** with sandboxed roots
(`CCO_USER_CONFIG_DIR` + `CCO_{DATA,STATE,CACHE}_HOME` + HOME-flip). **Never accept the legacy-vault
offer-to-remove until merged + validated.** After P5, the refactor is v1-complete — reconcile both roadmaps
(global `docs/maintainer/decisions/roadmap.md` + `analysis-roadmap.md`) and mark the ADRs.

> Next free ADR = **0028**. Live cursor = `decentralized-config-impl-progress.md`. The per-phase scaffold
> handoffs (P1/P2/P3/P3b/P3cd/P3-5/P4/P4-5) **and `Y-handoff-implementation.md`** (its launch purpose is
> consumed; the build method lives in §0 here, the P0–P5 phase map in `design.md` §9, the deferred-post-v1
> list in `design.md` §12) were consumed and removed — content in the progress note + git history. Recurring
> audit playbook = `implementation-review-handoff.md`; pre-release validation = `P2-dogfooding-validation.md`.
