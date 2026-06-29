# Adversarial Review — Decentralized In-Repo Config (sync focus)

**Date**: 2026-06-15
**Scope**: The sync sub-design of the decentralized in-repo config refactor —
correctness/robustness, requirements & design consistency, user flow & UX.
Covers `requirements.md`, `design.md`, and ADR `0001-decentralized-in-repo-config.md`.
**Method**: 3 parallel adversarial review agents (sync-engine correctness,
requirements/design consistency, UX/flows), each grounding claims against the
**actual codebase** (`lib/update-*.sh`, `lib/cmd-start.sh`, `lib/secrets.sh`,
`lib/paths.sh`, `lib/packs.sh`), synthesized by the lead.
**Status of design**: DESIGN complete, implementation NOT started. This review is
the §5.6 "adversarial sync robustness review" gating the GO to Phase 0.

> **Verdict**: The architectural **direction is sound** — decentralization
> structurally removes the #B13–B23 switch/sanitize/shadow bug class, enables
> concurrent sessions, and aligns config with code. But the **sync sub-design is
> NOT implementation-ready**: 5 Critical blockers (one of which invalidates the
> "zero-cost engine reuse" premise and another is a Phase-0 mount collision
> independent of sync), plus 8 High correctness/UX issues. The GO to Phase 0
> should be held until the Critical items and the correctness-class High items
> (H1, H3, H4, H5, H6) are resolved in the design docs.

---

## Severity summary

| Sev | Count | IDs |
|-----|-------|-----|
| Critical | 5 | C1 engine-reuse, C2 N-way topology, C3 sync-base drift, C4 `/workspace/.claude` collision, C5 secret-scan blocks the example |
| High | 8 | H1 commit-time, H2 start-wizard, H3 partial-push, H4 atomicity, H5 off-branch, H6 re-entrancy, H7 registry bootstrap, H8 memory regression |
| Medium | ~9 | see §4 |
| Low | ~5 | see §4 |

---

## 1. Critical blockers

### C1 — The "zero-cost engine reuse" claim is false (verified against code)

`design.md` §5.5 and `requirements.md` FR-Y2 state the sync **reuses
`_merge_file` / `_resolve_with_merge` / `_interactive_sync` unchanged, with "no
new merge logic"**. Verification against the source:

- `_merge_file(current, base, new, output)` — `lib/update-merge.sh:13` — is a
  genuine 3-way primitive and **is** reusable. ✅
- `_resolve_with_merge` — `lib/update-merge.sh:52` — and `_interactive_sync` —
  `lib/update-sync.sh:45` — **interpolate templates** (`_interpolate_template_tmp`,
  assuming the incoming side is a `{{PROJECT_NAME}}` framework template). A sibling
  repo's `.cco/` is not a template. Their prompt strings are framework-directional
  ("framework updated, you haven't modified", `update-sync.sh:108`).
- `_collect_file_changes` — `lib/update-discovery.sh:9` — the **classifier** that
  produces the change set, **omitted from the §5.5 reuse list** — is hard-bound to
  `scope ∈ {global, project}` (lines 23–34, 49) and filters by `*_FILE_POLICIES`.
  There is no "sync" scope, and it interpolates the incoming side (lines 61–68).

**Impact**: FR-Y2 is the load-bearing justification that the sync feature is
cheap (Phase-3 LOC budget). In reality the sync needs a new sync-scoped
classifier, suppression of interpolation, peer-neutral status vocabulary, and new
prompt strings. The 3-way *primitive* is reusable; the *orchestration layer* is
not.

**Recommended resolution**: Downgrade FR-Y2 to "reuses the 3-way merge primitive
(`_merge_file`, `_file_hash`, `_save_base_version`); adds a sync-scoped
classifier/driver in `lib/cmd-sync.sh`." Re-estimate Phase 3 LOC. The omission of
`_collect_file_changes` from the reuse list is itself a signal the directional
nature of the engine was not fully traced during design.

### C2 — N≥3 peer+confirm has no defined merge topology → non-deterministic (OPEN DECISION)

`_merge_file` takes a single (current, base, new). With 3+ repos diverged from a
common `sync-base`, an N-repo sync must decompose into sequential pairwise merges,
and `merge(merge(A,B),C) ≠ merge(merge(A,C),B)` when conflicts overlap. The result
depends on `members:`/registry **iteration order**, which is never defined as
canonical. Non-determinism in a config-coherence tool is a correctness bug: the
same divergent state syncs to different `.cco/` contents on different runs.

**Status**: **Decision deferred by the maintainer** (2026-06-15) — to be resolved
after dedicated analysis. The two candidate directions:

| Option | Pros | Cons |
|--------|------|------|
| **A. `root`-only for N≥3** (peer+confirm limited to N=2) | Simplest; deterministic by construction (root is authoritative); least code | Less symmetric; forces a "root" choice on projects that wanted peer |
| **B. Anchored accumulator** (peer for any N) | Symmetric; keeps peer model | Needs a documented canonical order (primary per AD6 first, then alphabetical), fixed `sync-base` as the ancestor for every pairwise step, fan-out + single sync-base update; more code/tests |

This must be closed before Phase 3 (and informs the C3 reconciliation design).

### C3 — `sync-base/` is inside the synced set → chicken-and-egg + silent drift

For a valid 3-way merge, the `sync-base` used as ancestor must be **identical
across all members** at comparison time. The design never guarantees this: each
repo commits its own `sync-base` independently and carries it on its own remote.
After a partial pull, a skipped/offline/conflicted sync (which the design itself
says are common, FR-C4.2), or a forgotten commit of one member, members hold
**different `sync-base`** snapshots → 3-way merges compare against different
ancestors → **false conflicts or a silently wrong winner**. This is precisely the
opaque-failure class the refactor sets out to kill (`design.md` §5.2 invariant).

**Recommended resolution**: Make `sync-base` consistency a **checked
precondition** — before any sync, compare the committed `sync-base` hash across
all members; if they differ, refuse and run an explicit "reconcile sync-base"
step (newest-by-content, or confirm resolution) first. Document that an
interrupted/uncommitted sync leaves `sync-base` dirty and that the next sync must
detect on-disk-vs-committed `sync-base` skew.

### C4 — `/workspace/.claude` single-slot mount collision (Phase-0 blocker, not sync) (verified)

`lib/cmd-start.sh:454` mounts exactly **one** directory to `/workspace/.claude`.
In the new model every synced member repo carries its own `.cco/claude/` "→
`/workspace/.claude`" (AD4), but the slot is single and **the design never says
which repo wins**. Worse (`lib/packs.sh:91–130`): packs inject `rules/`/`agents/`
into that **same** `/workspace/.claude` tree via per-file mounts; a directory mount
of `.cco/claude/` would **shadow** them (Docker does not merge overlapping bind
mounts). This breaks pack delivery (an existing feature) **and** the headline
multi-repo feature (G5).

**Recommended resolution**: Specify that the **host/primary** repo's `.cco/claude/`
(`.` per AD6) is the sole mount source for `/workspace/.claude`; member
`.cco/claude/` dirs are sync replicas, not independently mounted. Re-design the
layering with packs (likely keep the existing per-file/per-subdir mount strategy
rather than a single dir mount). This must be decided in **Phase 0**.

### C5 — The secret-scan blocks the file FR-S4 mandates committing (verified)

FR-S4 requires committing `secrets.env.example`, which by definition documents
required vars (`API_KEY=…`). But `_secret_match_content` (`lib/secrets.sh:68–82`),
which the design reuses in the pre-commit gate, **flags that exact content** and
refuses the commit. (The filename only escapes `*.env` by the `.example` suffix
coincidence — also brittle.)

**Recommended resolution**: Exempt `*.example` files from the **content** scan
(they are skeletons by definition), add an explicit `!secrets.env.example`
un-ignore rule, and add a Phase-0 test asserting `secrets.env.example` is
stageable while `secrets.env` is not.

---

## 2. High-severity findings

### H1 — `last-commit-wins` orders by git commit time, which is not cross-machine-reliable

`design.md` §5.2 calls commit time "the only reliable cross-repo/cross-machine
timestamp". It is not: `GIT_COMMITTER_DATE` is wall-clock (clock skew), and
rebase/cherry-pick/amend/squash rewrite it. "Commit time of `.cco`" is also
ambiguous (a commit touching only `state/` or `secrets.env.example` moves the
timestamp without changing the synced set). A wrong winner **silently overwrites**
genuinely-newer clean config.
**Fix**: Do not order by time. Use `sync-base` as ancestor — "which side changed
vs base?" If exactly one changed, it wins (no timestamp). If both changed → genuine
divergence → fall back to confirm. Restrict the synced-set path in any timestamp
query (`git log -1 --format=%ct -- <synced-set>`), and document the rebase/skew
footguns if LCW is kept at all.

### H2 — `cco start` can open an interactive conflict wizard before the session starts

Default `peer+confirm+on-command` runs sync first; `confirm` is interactive by
definition, so "best-effort" and "confirm" contradict on the hottest command.
FR-C4.2's non-blocking guarantee is scoped to `~/.cco` (Domain A), **not** per-repo
sync on `cco start`.
**Fix**: On the hot path, sync must be **detect-and-defer only** — print "config
diverged across repos; run reconcile" and start with the host repo's `.cco`. Never
open the wizard from `start`. Add `--no-sync` / `CCO_NO_SYNC=1`.

### H3 — Distributed coherence is misreported ("synced A,B,C but pushed only A")

If one member's push fails (warning scrolls past), PC2 pulls and `cco start`
declares "no-op, already coherent" (§5.4 diagram) while running stale config. There
is no per-machine record of the synced `sync-base` generation to compare against
what was actually pulled. The "no lost edits" invariant is local and says nothing
about the distributed push gap.
**Fix**: Commit the post-sync `sync-base` hash in each member's
`.cco/tracked/`; on `start`/`sync`, compare members and report "coherent among N
of M reachable members" — never an unqualified "coherent".

### H4 — "Atomic" cross-repo write is not achievable in bash; no rollback story

§5.4 claims `cco sync` "writes all members + sync-base atomically". No POSIX/bash
primitive spans N working directories atomically. A kill mid-write leaves partial
sync (A,B synced, C stale; A's `sync-base` advanced, C's not — compounds C3).
**Fix**: Replace "atomic" with **stage-then-commit**: compute all merge results
into `.cco/state/.tmp/`, validate (no conflict markers, secret-scan), write each
member tracking a per-repo journal, roll back on failure, and leave a
`sync-in-progress` marker that the next `sync`/`start` detects and offers to
complete/abort.

### H5 — `git show <branch>` off-branch read contradicts the working-tree model; write is undefined

FR-Y6/§5.4 read an off-branch member via `git show <branch>:.cco/...`. But confirm
mode reads **working-tree** files (to capture WIP); `git show` reads **committed**
content of another branch → that member's WIP is invisible (violates no-lost-edits)
and **writing back via git-show is impossible**. The design specifies the read but
never the write, and never which branch sync targets.
**Fix**: Single model — sync operates on each member's **currently checked-out
working tree**. A member on an unexpected branch → **report & skip**, never silent
git-show. If cross-branch read is needed, restrict it to `--check` (read-only) and
forbid writing to off-branch members.

### H6 — Re-entrancy guard `CCO_SYNCING` (env var) is insufficient across processes

An env var only guards a single process tree. It does not guard two independent
`cco` invocations or a `git commit` hook (a fresh process without the var). Concrete
loop: `cco sync` → commit → installed pre-commit hook → `cco sync`.
**Fix**: Use a **filesystem lock** per project (`mkdir`-based for macOS lacking
`flock`, bash-3.2-safe), honored by hooks and concurrent invocations alike; define
exactly where it is acquired/released; make hooks no-op when held. Reconsider
whether "auto on *every* cco command" is worth the blast radius vs. only
`start`/`sync`.

### H7 — Registry is per-machine, empty on a fresh machine, with no rebuild-from-disk

`registry.yml` is gitignored/not-synced yet is the sole source for `cco list` /
`cco sync <name>` / tags. On PC2 after `git clone`, it is empty → no project
inventory (contradicts the G3 IDE-first multi-PC value prop). The design mentions
`cco registry refresh` only for **pruning**, not **population**.
**Fix**: Add `cco registry refresh --scan <dir>` (or auto-scan of registered repo
roots) that rebuilds the registry from on-disk `.cco/project.yml` +
`tracked/source`.

### H8 — `memory/` no longer syncs cross-PC: silent regression

Today `memory/` is vault-tracked and syncs across machines (CLAUDE.md). RD1 makes
it gitignored-per-machine and FR-Y1 excludes it from sync; with the vault gone,
**auto-memory no longer crosses machines** unless the user opts into per-repo
commit. This removal of an existing capability is presented as a clean "decided"
checkbox and is **not** recorded in the ADR Consequences.
**Fix**: State the consequence explicitly in RD1 + ADR (or reconsider the default).

---

## 3. §5.6 open-question resolutions

### (1) Uncommitted edits during sync — per mode, never lose WIP
- **confirm / root**: the working tree IS a valid source (participates in the
  3-way: current=worktree, base=sync-base, incoming=peer worktree). Before
  overwriting any member, back up its synced set to
  `.cco/state/.tmp/sync-backup/`. Never overwrite without diff + explicit choice.
- **last-commit-wins**: operates on committed state and **refuses (hard, not
  warn-skip) if any member's `.cco` working tree is dirty**.

### (2) Trigger-mode × divergence matrix

| Trigger | Committed divergence | Uncommitted divergence | User sees | Choice required |
|---|---|---|---|---|
| **manual** | until `cco sync` | until `cco sync` | nothing until invoked, then full diff (confirm) | confirm: per-file; LCW: abort if dirty |
| **on-command** (default) | reconciled at next `start`/`sync` (best-effort) | confirm: reconciled (worktree); LCW: **persists** (skipped on dirty) | sync summary before the command | as manual; on dirty+LCW user must commit or switch mode |
| **hooks** (opt-in) | pre-commit: at commit (may block); pre-push: warns | committing repo is clean; other members may be dirty → skipped (LCW) / merged (confirm) | block message / push warning | confirm conflict at commit |
| **daemon** (future) | on debounced save (worktree) | **half-edit risk** — see (3) | notification (ideal) | true conflicts must route to interactive confirm |

Silent-persistence cells: *LCW + dirty member* (skipped) and *manual until
invoked*. Both must be **surfaced** by `cco list`/`cco start` via a "repos
divergent — run reconcile" flag derived from comparing committed synced-set hashes.

### (3) Future daemon semantics
Keep as future scope (§12). If built: working-tree watch + on-save + debounce, but
with a **parse-gate** (propagate only if `project.yml` and `.claude/**` parse),
staging copy, and **never auto-resolve a true conflict** (notify + leave intact).
Commit-based daemon is redundant with hooks (agree with the design).

### (4) No-sync / enabling sync later
- `mode: none`: zero reconciliation and **do not create/advance `sync-base`**
  (otherwise a later enable finds a fabricated ancestor); do not flag divergence.
- First sync after enabling: **force confirm** (ignore LCW), treat as
  `BASE_MISSING` (the non-destructive path already at `update-discovery.sh:88`),
  show every difference, and only after resolution establish `sync-base`.
- Add a `sync.ignore:` list in `project.yml` for intentional per-path divergence
  (e.g. `claude/mcp.json`).

---

## 4. Consistency contradictions & remaining findings

### Top contradictions (must be reconciled in the docs)
1. **RD2 vs FR-Y10** — RD2 says default `peer+confirm`; FR-Y10 says absent `sync:`
   ⇒ `none`. Two defaults for a `project.yml` with no `sync:` block (compounded by
   `project.yml` being user-owned and never merged by `cco update`). → RD2 means
   "the scaffolded default of `cco init --sync`", not the runtime default.
2. **FR-Y7 (commit-based idempotency) vs §5.2 (working-tree comparison)** — two
   working trees can diverge with no new commits → confirm must prompt, yet FR-Y7
   says no-op. → Redefine idempotency per mode; `--check` must use the same
   comparison as its mode.
3. **Two "sync" verbs** — `cco sync <project>` (multi-repo) vs `cco config sync`
   (`~/.cco` multi-PC) conflate the two domains AD10 insists must never be
   conflated. → Rename one (e.g. `cco reconcile` for multi-repo).
4. **`registry.yml` inside the `~/.cco` git store** — guarded only by gitignore
   while managed-sync auto-commits; a mis-healed gitignore would leak per-machine
   absolute paths. → Commit with an **allowlist** (`packs/ templates/
   global/.claude/`), not `git add -A` + denylist.
5. **`source`/`source-url` in the synced set** — per-repo provenance; syncing it
   overwrites a member installed via `cco project install`, breaking its
   `cco update` remote discovery. → Exclude from sync.

### Medium
- **M-paths** — `lib/paths.sh` dual-read is presented as reuse but is new code: it
  must define precedence when legacy flat `.cco/` and new hybrid paths coexist
  (e.g. both `.cco/secrets.env` and `.cco/secrets/secrets.env`); no `project.yml`
  location helper exists today.
- **M-migrate** — multi-repo migration: the decline-to-clone path is unspecified
  and re-run idempotency is asserted without a mechanism (mark migrated in
  registry; never overwrite an existing `.cco/` without confirm).
- **M-members** — the `sync:` block (mode/policy/members) is itself synced content;
  if members disagree (A: peer, B: root; A lists [B,C], B lists [A]) the governing
  config is undefined. → The invoking repo's `sync:` block governs the run;
  membership is undirected and validated/reconciled first.
- **M-bootstrap** — auto-sync on `cco start` can run **before** `@local` resolution
  on a fresh machine → siblings unresolved → an "empty successful sync" that may
  advance `sync-base`. → Resolve `@local` before sync; a skip must never advance
  `sync-base` (FR-Y7).
- **M-vault-machinery** — "none of the old vault's machinery" is overstated (it
  reuses gitignore-setup, clone helpers, merge engine). → Tighten to "none of the
  branch-switch/sanitize/shadow machinery" and enumerate retained vs deleted
  functions for Phase-2 teardown clarity.
- **M-config-name** — `cco config` (personal store) collides with the intuitive
  "configure this project". → Consider `cco home`/`cco store`.
- **M-knobs** — the knob matrix (3 triggers × 2 modes × 2 policies × none × hooks)
  is too large for single-repo users to whom none of it applies.
- **M-enable-cliff** — enabling sync on an intentionally-divergent project lands in
  a wall-of-conflicts; needs `sync.ignore:` + an `--adopt <repo>` baseline seed.
- **M-init-overload** — `cco init` / `--sync` / `--migrate` overload one verb;
  prefer `cco init` + `cco join` + `cco migrate`.

### Low
- `gitignore`/scan suffix coincidence for `secrets.env.example` (covered by C5).
- Installed hooks must invoke `cco` by **PATH** (AD11 packaging-awareness).
- RD5 (authored vs installed packs) and RD7 (remotes not synced) are marked
  "deferred" but are already decided and depended-upon in the design → promote to
  Decided.
- Migration J6 can be a long interrogation → make it resumable/incremental
  (`cco vault migrate <one-project>`, idempotent skip-done, loud up-front backup).
- `cco init` overload, `cco start` no-op message overclaim (covered by H2/H3).

---

## 5. UX — simplest-path recommendation (80% case: solo dev, 1 repo)

The cross-cutting UX risk is knob overload + the hot-path wizard + an unacknowledged
N-commit/N-push regression vs the single `cco vault save`. Target flow:

1. `cco init` → scaffolds `.cco/` with **no `sync:` block**, no sync surface.
2. Edit `.cco/project.yml` in the IDE.
3. `cco start` → starts immediately; no sync step exists.
4. `git commit && git push` → one repo, one commit.

Sync appears only on opt-in:
- `cco join <project>` (explicit, not `init --sync`) adds the 2nd repo and only
  then scaffolds a `sync:` block (`peer+confirm`).
- Hot path = detect-and-defer only; interactive resolution lives in an explicit
  `cco reconcile` (rename kills the `sync` / `config sync` collision).
- `cco reconcile --commit --push` performs the N commits/pushes in one command
  (closes the unacknowledged multi-repo regression).
- A post-sync ledger always prints written/skipped/pending-push; `cco start`
  reports "coherent among N of M reachable members", never an unqualified
  "coherent".

---

## 6. Recommended next steps

1. **Hold the GO to Phase 0** until the 5 Critical items and the correctness-class
   High items (H1, H3, H4, H5, H6) are resolved in the design docs.
2. **Close C2** (N≥3 topology) with a dedicated analysis — decision deferred by the
   maintainer (2026-06-15).
3. **Update the three design docs** to reconcile the §4 contradictions (FR-Y2
   re-scope, RD2/FR-Y10, sync verb naming, C4 mount model, C5 secret-scan,
   `source`/`source-url` exclusion, registry rebuild, memory regression). —
   separate, maintainer-approved edits.
4. Re-baseline the Phase-3 LOC budget given C1.

---

## Appendix — code references grounding the findings

- `lib/update-merge.sh:13` — `_merge_file` (3-way primitive, reusable).
- `lib/update-merge.sh:52` — `_resolve_with_merge` (template-directional, not reusable unchanged).
- `lib/update-sync.sh:45,108` — `_interactive_sync` + framework-directional prompts.
- `lib/update-discovery.sh:9,88` — `_collect_file_changes` (scope-bound classifier, omitted from reuse list); `BASE_MISSING` non-destructive path.
- `lib/update-hash-io.sh:6,20` — `_file_hash`, `_save_base_version` (reusable primitives).
- `lib/cmd-start.sh:454,508` — single `/workspace/.claude` mount; sibling repo mounts.
- `lib/packs.sh:91–130` — packs/rules/agents layered into `/workspace/.claude`.
- `lib/secrets.sh:24–46,51–82` — secret filename + content scan patterns.
- `lib/paths.sh` — existing dual-read covers `.cco-X`→`.cco/X`, not flat→hybrid.
- `lib/cmd-sync.sh`, `lib/cmd-config.sh` — do not exist yet (all sync/hook/lock logic is design-stage).
