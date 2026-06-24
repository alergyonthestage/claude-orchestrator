# P5 handoff — Sharing-ext + the deferred verbs (+ P4→P5 audit) — opens the final v1 phase

Self-contained launcher for a **clean session** (open after `/clear`) to run the **P4→P5 adherence
audit** at the Phase-4 boundary, then build **Phase 5** — the deferred-to-v1 command surface on the
Phase-4 substrate. The build (P0–P4) + P4-doc are done; the schema bridge is collapsed to index-only;
the vault is gone. What remains is the §6 deferred list, including the **P4-5d** central-layout→index
teardown that P4-5 carried forward.

Branch `feat/vault/decentralized-config`, commits **LOCAL** (the maintainer pushes from the Mac).

---

## ⏩ RESUME STATUS (read this FIRST)

> **✅ P4→P5 ADHERENCE AUDIT DONE 2026-06-24 → PHASE 4 CLOSED.** The §1 first-action audit has run
> (`reviews/24-06-2026-p4-p5-adherence-review.md`, 4 parallel read-only lenses + adversarial verify):
> Phase-4 code **fully conformant — 0 code 🔴 / 0 blockers / 0 design gaps**. One **doc-only** cluster
> (shipped-behavior docs documented P5-not-built verbs as shipped) → maintainer Option A, **FIXED** (🚧
> markers, suite 827/1). Transitional Registry refreshed (P0–P4 retired; live = P4-5d + the 1 straddler).
> **§1 is satisfied — a fresh session can skip it and go to P5 build (§3); propose the build order +
> sub-commit decomposition to the maintainer BEFORE coding (§0/§3).** First P5 unit likely = **P4-5d**.

**Phases 0–4 ✅ CLOSED. Phase 4 build (P4-1…P4-5c) + P4-doc + P4→P5 audit ✅ COMPLETE. Suite 827/1.** The
**1** = `test_resolve_name_from_full_variant_url` (P5 llms straddler — resolved in P5). Delta-green is
measured against this 1; a 2nd failure is a regression. Run tests with the hatch:
`CCO_ALLOW_HOST_RESOLVE=1 ./bin/test` (`--file <name>` / `--filter <substr>` to scope).

**The `decentralized-config` design is the single SOURCE OF TRUTH**, precedence:
`guiding-principles.md` (P1–P18) → ADRs (0005–0027) → living `design.md` → `requirements.md`. The more
specific/authoritative wins; **record any reconciliation**; a genuine design gap ⇒ **PAUSE and discuss**.

**First actions:** (1) `git log --oneline -15` + read the live progress note
`decentralized-config-impl-progress.md` (the cursor + full P4 detail); (2) re-confirm the baseline 827/1;
(3) **run the P4→P5 adherence audit (§1) before building.**

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

## 1. FIRST ACTION — the P4→P5 adherence audit (the boundary check)

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
3. The live progress note **`decentralized-config-impl-progress.md`** (cursor + full P4 detail) + `git log`.
4. `Y-handoff-implementation.md` — the master build method + the P0–P5 phase map + the deferred-post-v1 list.
5. `implementation-review-handoff.md` — the audit playbook + the **Transitional Registry** (what P4-5d retires).
6. `design.md` **§9-P5** + the ADRs per item below.
7. The code (re-grep — line numbers drift).

## 3. Scope — Phase 5 (the §6 deferred list, on the P4 substrate)

Each item is its own dependency-ordered unit; **propose the build order + sub-commit decomposition to the
maintainer before coding** (per §0). Suggested grouping (confirm):

- **P4-5d — central-layout → index teardown (the carried-forward teardown).** Migrate the ~10 commands that
  iterate `$PROJECTS_DIR/*/` to enumerate via the STATE index (`_index_list_projects` + `_index_get_path`);
  then drop the harness dual-seed (`tests/helpers.sh` `create_project` legacy central layout) + the legacy
  `CCO_*_DIR`/`$PROJECTS_DIR`/`$GLOBAL_DIR`-default resolution + deprecation warnings in `bin/cco`. This is
  substantial (touches update/llms/pack/template/clean/chrome/stop/list/show + ~all fixtures' central seed).
  Likely the **first** P5 unit — several items below assume index-only enumeration.
- **`cco forget`** + delete-cascade (ADR-0021): deregister a project (id-keyed internal state — index/tags/
  STATE/DATA — repo untouched; index self-heals via cwd-first + `resolve --scan`) + `cco config validate
  [--fix]` orphan-prune (EXPLICIT/preview-first/NEVER-automatic; F59 delete-cascade pack/template/llms/remote).
- **`cco project validate`** full share-readiness contract (ADR-0023 D2): cwd-first, exit 0/1/2, ERE
  machine-agnostic, presence-only + `--reachable`, detect-only/never-block, carries the ADR-0022 D4 pack
  no-coord ERROR row. (cli.md §3.14 holds the target surface, currently marked 🚧 planned.)
- **`cco update --check`** (DATA-source-driven + install-presence-gated 3-state, exit-0; ADR-0022 D6).
- **Three-layer pack resolution + `internalize`** (ADR-0019 D3/D7, ADR-0023 D4): mount local-first
  `~/.cco/packs` → url → `<repo>/.cco/packs` cache; `internalize` = pack/template cut-url v1 + `--as` fork
  (project Case-C is name-reserved post-v1); `export --bundle-packs`. Plus the orphaned `_resolve_template_vars`
  full `{{VAR}}` resolution for `cco init --template` adapted to the new `claude/` layout.
- **`cco project coords`** (cross-unit ADR-0016 D3, on-demand coords-lookup) + **`cco config protect`** helper
  (docs-only v1 today; ADR-0020 D4 / F27 pinned contract).
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
> handoffs (P2/P3/P3b/P3cd/P3-5/P4/P4-5) were consumed and removed — their content lives in the progress note
> + git history. Master method/phase-map = `Y-handoff-implementation.md`; recurring audit playbook =
> `implementation-review-handoff.md`; pre-release validation = `P2-dogfooding-validation.md`.
