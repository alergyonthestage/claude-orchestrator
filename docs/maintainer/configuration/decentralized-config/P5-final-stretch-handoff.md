# P5 final-stretch handoff — config-protect docs → P5-doc → pre-merge dogfooding

Self-contained launcher for a **clean session** (open after `/clear`) to finish **Phase 5** and bring the
decentralized-config refactor to v1-complete. The command surface is essentially **built**: P5-0…P5-5 are
done. What remains is **documentation + the pre-merge gate** — no further feature code is planned for v1.

Branch `feat/vault/decentralized-config`, commits **LOCAL** (the maintainer pushes from the Mac).

---

## ⏩ RESUME STATUS (read this FIRST)

> **✅ PHASES 0–4 CLOSED + P5-0…P5-6 DONE (2026-06-25). ▶ RESUME AT P5-doc.** Build order (maintainer-confirmed):
> P5-0 → P5-1 → P5-2 → P5-3 → P5-4 → P5-5 → P5-6 (config-protect docs ✅) → **P5-doc** → **pre-merge dogfooding**.
> The P4→P5 boundary audit is consumed (`reviews/24-06-2026-p4-p5-adherence-review.md`, 0 code 🔴). **Index
> per-project namespacing = POST-V1** (ADR-0022 D2). **`cco config protect` helper = POST-V1** (ADR-0023 D6).

**P5 commits so far** (each delta-green; full detail at the tail of `decentralized-config-impl-progress.md`):

- **P5-0** `2f93de8` — llms name-derivation (path segment wins over domain).
- **P5-1** `95b7767`/`0da6153`/`6209bae`/`7e9d458`/`0116679` — P4-5d central-layout (`$PROJECTS_DIR`/`CCO_*_DIR`)
  teardown; every command enumerates via the STATE index.
- **P5-2** `ed2b7ee`/`d706226`/`93542cd` — `cco forget` + `cco config validate` + delete-cascade (ADR-0021).
- **P5-3** `9c5986d`/`4961d87`/`b88bc18`/`44199f9` — three-layer pack resolution + `internalize` +
  `export --bundle-packs` + `init --template` `{{VAR}}` (ADR-0019/0023).
- **P5-4** `48a44b0`/`5f6c506`/`75c1377` — `cco project validate` (share-readiness, ADR-0023 D2 + ADR-0022 D4
  pack-collision ERROR) + `cco project coords` (cross-unit ADR-0016 D3, `--sync --from` in-place writer).
- **P5-5** `5753513`/`13b7573`/`b5080fc` — `cco update --check` (DATA-source-driven, install-presence-gated
  3-state, exit-0; **packs+templates only**, projects excluded P13) + template `installed_commit` prereq.
- **P5-6** `c96fcda`/`6e03502` — config-protect **governance docs** (no code): configuration-management.md
  §9 "Governance & Protecting Config" (P17 delegate-to-git, two governance models, per-host CODEOWNERS +
  ruleset setup, 🚧 helper note) + design.md §11/§7 living-doc reconciliation to docs-only (ADR-0020 D4 +
  ADR-0023 D6). Suite **894/0** (docs-only, no delta).

**Suite 894/0** — delta-green is measured against **ZERO** failures (any failure = regression). Run with the
hatch: `CCO_ALLOW_HOST_RESOLVE=1 ./bin/test` (`--file <name>` / `--filter <substr>` to scope).

**The `decentralized-config` design is the single SOURCE OF TRUTH**, precedence: `guiding-principles.md`
(P1–P18) → ADRs (0005–0027) → living `design.md` → `requirements.md`. The more specific/authoritative wins;
**record any reconciliation**; a genuine design gap ⇒ **PAUSE and discuss**.

**First actions (resume):** (1) `git log --oneline -12` + read the live progress note
`decentralized-config-impl-progress.md` (cursor: P5-6 done; P5-doc scope at the tail); (2) re-confirm baseline
**894/0**; (3) start **P5-doc** (§2); per §0, **propose the decomposition to the maintainer before writing.**

---

## 0. Authoritative methodology (the law — unchanged across the whole refactor)

- **Design governs.** Precedence as above. The build realizes the frozen design; it does not invent.
- **Build method**: dependency + reuse + open-closed, build-once-in-final-form, breaking cutover (no
  dual-read; ~2 known users). Removed verbs get **no alias** unless an ADR says so (AD12).
- **Delta-green per commit.** Each commit leaves cco runnable and the suite at **894/0** (no new reds).
- **Maintainer-confirm** any UX / interface / placement / sequencing choice (AskUserQuestion). Propose the
  sub-commit decomposition + any open reconciliations **before** coding.
- **Code-ground every claim** (re-read; line numbers drift). **bash 3.2 / macOS** (`/bin/bash`, guard empty
  arrays under `set -u`).
- **Doc-lifecycle** (`.claude/rules/documentation-lifecycle.md`): decision records = immutable history
  (forward-annotate, never rewrite); living design/shipped-behavior docs = rewrite to truth, but **shipped-
  behavior docs only at the phase that makes the change true** (never ahead of code).
- **Self-development caveat:** edits to `config/`, `Dockerfile`, baked `defaults/managed/**` are NOT live this
  session (need `cco build`); `lib/`, `internal/`, `templates/`, `docs/` ARE host-side and testable now.

---

## 1. Boundary audit — recurring playbook (run at the P5→merge boundary)

The per-phase boundary audits are consumed. The **next** one is the **P5→merge audit**, run with the recurring
`implementation-review-handoff.md` playbook (read-only, code-grounded, 4-state classify; scaled to the phase)
just before merging to `develop`. It is NOT needed to start P5-6.

## 2. Remaining scope — the final v1 stretch

> Each unit: code-ground fresh, confirm micro-UX with the maintainer, delta-green each commit (vs **894/0**).

- **P5-6 ✅ DONE — `cco config protect`: DOCUMENTATION ONLY (no code).** ADR-0020 D4 + **ADR-0023 D6** pin this:
  v1 ships **a guide section**, the **helper command is deferred post-v1**. Write the guidance for protecting
  `<repo>/.cco/**` via the **host**, delegated-to-git (P17, like auth P7) — cco never gatekeeps:
  - CODEOWNERS goes to a **host-recognized** path — repo-root `CODEOWNERS` or `.github/CODEOWNERS`,
    **never** `<repo>/.cco/CODEOWNERS` (GitHub does not honor `.cco/`) — entry `/.cco/** @org/cco-maintainers`.
  - Per-platform write-protection instructions: **GitHub** Rulesets (fnmatch path) + required CODEOWNERS
    review on a protected branch · **Gitea** protected-branch file-pattern globs · **GitLab** pre-receive /
    push rules. CODEOWNERS is **review-routing, not a hard write gate** (enforced only via branch protection).
  - Truthful diff (G8) + S8 no-token-leak are the safety net; CODEOWNERS never hard-blocks.
  - There is currently **no** `cco config protect` doc section to de-🚧 — this is a NEW guide subsection
    (likely in `configuration-management.md` §Sharing/permissions or a short `permissions` guide).
  - Likely **no suite delta** (docs-only). Confirm placement + scope with the maintainer first.
- **▶ P5-doc — close-out docs + changelog + migration.** The refactor practice deferred the changelog/migration
  for all new P5 verbs to here (unmerged branch, no users yet). Tasks:
  - One coherent **`changelog.yml`** entry (or a few) covering the P5 user-visible additions: `cco forget`,
    `cco config validate`, `cco project validate`, `cco project coords`, `cco update --check`,
    `pack/template internalize`, `project export --bundle-packs`, `init --template`.
  - Any **migration** needed for the new STATE/DATA layouts introduced this phase (re-check: P5 mostly added
    readers/new dirs, not schema-breaking moves — verify no migration is actually required before writing one).
  - **Shipped-behavior doc sweep:** grep for residual stale tokens — `CCO_PROJECTS_DIR` env mentions left from
    P5-1, the removed `cco project update` verb, any remaining 🚧 markers whose feature now ships.
- **pre-merge dogfooding** — §3 below. After it passes, the refactor is **v1-complete**.

**Out of scope for v1** (do NOT build unless the maintainer pulls them in): the `cco config protect` **helper**
command; index per-project **namespacing** (ADR-0022 D2, global-flat stays); **T** = DATA/STATE cross-PC
state-sync engine; `cco project internalize` (Case-C); the D6 interactive internalize-as-cache prompt;
`cco template update` (its 🚧 marker stays — a separate future item).

## 3. Cross-cutting invariants (never violate)

- **4-bucket taxonomy** (ADR-0007/0015/0016): CONFIG `~/.cco` · DATA `~/.local/share/cco` (synced) · STATE
  `~/.local/state/cco` (machine-local: index, base/+meta, tokens, memory/transcripts) · CACHE (regenerable).
- **The STATE index is the sole name→path map** (the schema bridge is collapsed; no `@local`, no
  `local-paths.yml`, no `path:` in project.yml). **AD3/G8 — no real host path ever enters committed config.**
- **P13** projects ride the code-repo remote. **P14** reachability is layered + never a hard block. **P17**
  permissions delegated to git, cco never gatekeeps. **Host-side resolver guard (H4)** + the
  **compose↔entrypoint container-path contract** are invariants.

## 4. Pre-merge to develop/main (the gate)

Full **dogfooding e2e on the Mac** (`P2-dogfooding-validation.md` §3) on a vault **copy** with sandboxed roots
(`CCO_USER_CONFIG_DIR` + `CCO_{DATA,STATE,CACHE}_HOME` + HOME-flip). **Never accept the legacy-vault
offer-to-remove until merged + validated.** After P5, the refactor is v1-complete — reconcile both roadmaps
(global `docs/maintainer/decisions/roadmap.md` + `analysis-roadmap.md`) and mark the ADRs.

> Next free ADR = **0028**. Live cursor = `decentralized-config-impl-progress.md`. All per-phase scaffold
> handoffs (M/P1/P2/P3*/P4*/V/W/X/Y/Z*) are consumed and removed — content lives in the progress note + git
> history. Recurring audit playbook = `implementation-review-handoff.md`; pre-release validation =
> `P2-dogfooding-validation.md`.
