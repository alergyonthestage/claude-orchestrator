# Design Coherence & Completeness Review — Decentralized In-Repo Config

**Date**: 2026-06-16
**Scope**: cross-domain validation of `requirements.md`, `design.md`, ADR 0001–0008 after
resolving RD-claude-mount (0005), RD-paths (0007), RD-home (0008).
**Method**: 4 specialized agents in parallel (coherence, flows/journeys, phase/dependencies,
code-grounded feasibility), then synthesis. Design-phase: no code or doc changes made by the agents.

---

## Verdict

The architecture is **coherent and correct in substance** — the three pillars
(machine-agnostic config, git as the only cross-PC transport, sync-as-copy) and the eight
ADRs converge with no contradiction of *merit*. **Phase 0 is ready** (its only gate,
RD-claude-mount, plus RD-paths, are resolved; scope is specified). However the design is
**not yet fully implementation-ready** below Phase 0: one real contradiction was introduced
during the ADR-0007 expansion, several flows lack ordered sequences/edge-cases, and the
code-grounded mapping has gaps that would surface in Phase 0/2/3. Estimated completeness of
the code-grounded mapping: ~70%.

The recurring cross-cutting theme: **resolution-before-notices ordering** — divergence
checks, sync target resolution, and the reminder aggregator all assume project members are
already resolved in the index, but on a fresh machine/clone the index is empty. This
ordering must be specified once as a global invariant.

---

## Blockers

### BL1 — ADR-0007 contradicts ADR-0008 on auto-commit (and reuses the `cco sync` verb)
`0007-system-dir-locations.md` §"Personal store as a git working tree" still states the
personal store "cco **auto-commits its own mutations** … exposes `cco sync`". ADR-0008
(same date) **rejects** auto-commit ("No auto-commit in v1") and names the verbs
`cco config save/push/pull`. `cco sync` is the project multi-repo verb (AD7) — reusing it
for `~/.cco` is the exact verb collision AD10/the adversarial review warned against. A reader
stopping at ADR-0007 would implement the rejected model.
**Fix**: in ADR-0007, replace the auto-commit/`cco sync` guardrail text with a pointer to
ADR-0008 (explicit manual commits, `cco config save/push/pull`). *Doc-only; no new decision.*

### BL2 — Removing the vault (Phase 3) strands `memory/` sync while RD-memory is open
*(flagged by 3 of 4 agents)* `memory/` is today vault-tracked and auto-committed
(`cmd-vault.sh:1628-1663`) and syncs cross-PC; `cmd-start.sh:459` mounts it. The new layout
gives it **no home**: not machine-agnostic config, not `.cco/claude/` (config-only), not in
the STATE inventory (ADR-0007 lists `claude-state/` but not `memory/`). Phase 3 deletes the
only mechanism that versions/syncs it. RD-memory is open and unassigned to a phase.
**Fix**: make RD-memory an **explicit gate of Phase 3** (as RD-claude-mount gated Phase 0);
record the capability regression in ADR-0001/0003 Consequences; decide at least a default
location before the breaking cutover.

### BL3 — Compose uses relative `./` mounts anchored to one `project_dir`; the config/state/cache split breaks it
`cmd-start.sh:759` runs compose with `--project-directory "$project_dir"` and emits relative
sources (`./.claude`, `./project.yml`, `./.cco/claude-state`, `./memory`, `./mcp.json`,
`./setup.sh`, `./.cco/managed`, `:454-495`). These work only because config+state+compose are
co-located today. ADR-0004/0007 split them across three bases; `--project-directory` can point
to only one, so the `./` sources will no longer resolve.
**Fix**: Phase-0 action item — convert all framework mount sources to host-absolute paths and
fix the compose base dir (likely STATE). Repo/extra_mount sources are already absolute
(`expand_path`); the framework config lines are not.

---

## High

### H1 — Resolution-before-notices ordering is unspecified (cross-cutting)
`cco start` worst-case (empty index + unresolved repo + divergence + dirty tree), `cco sync`
target resolution, and the reminder aggregator's cross-repo divergence (ADR-0008 §2c) all
require members resolved in the index first. On a fresh machine the index is empty, so
divergence/reminders cannot be computed before resolution. The old review's M-bootstrap
("resolve `@local` before sync") flagged this and it is not carried into the current design.
**Fix**: add to §4.4 an explicit ordered `cco start` sequence (resolve cwd → resolve members
via index → resolve/clone unresolved → *then* compute divergence + reminders → start) and
state it as a global invariant reused by sync and the aggregator.

### H2 — Reminder aggregator: "config-sensitive commands" set undefined + cost/scoping
ADR-0008 says "every config-sensitive command" but no doc enumerates the set. The aggregator
runs `git status` on `~/.cco` + each involved `<repo>/.cco` + a cross-repo divergence check on
every such command; today `_check_vault` is O(1) on one small repo + one `docker ps`. On large
member repos this is real latency.
**Fix**: enumerate the set (likely `start, sync, join, migrate, config*`); scope `git status`
to the `-- .cco/` pathspec; use the §4.6 last-synced fingerprint for divergence instead of a
full content diff; allow per-session cache/opt-out. Candidate dedicated analysis:
"reminder-aggregator cost & scoping".

### H3 — Reminder aggregator / `cco config` orphaned across phases; §9 P3 says stale "per RD-home"
§9 P3 reads "`cco config` (`~/.cco`; managed depth per RD-home)" — RD-home is resolved
(ADR-0008), the reference is stale. The reminder aggregator is a P1 concern (the §4.4 `cco
start` notice and §4.6 sync-state need it) but §9 assigns it to no phase.
**Fix**: §9 → "per ADR-0008"; split the aggregator: reminders (a)/(b) and (c) → P1 (with
`cco start` transform + sync-state); `cco config save/push/pull` + allowlist + whitelist
`.gitignore` + `.example` exemption → P3.

### H4 — `expand_path()`/resolver host-side guard missing
`expand_path()` (`utils.sh:11-17`) expands `~` via `$HOME`; in-container `$HOME=/home/claude`.
ADR-0007 mandates host-side-only resolution. Today resolution is already host-side (entrypoint
does no host-path resolution — confirmed), so this is a latent trap, not a regression.
**Fix**: add an explicit anti-in-container guard to the XDG resolver (refuse if
`$HOME=/home/claude` or `/.dockerenv` present); record as an ADR-0007 robustness invariant.

### H5 — Uninventoried project config: `mcp.json`, `setup.sh`, `mcp-packages.txt`, `.cco/managed/`
`cmd-start.sh:469,481,487,493` mount these as project config/generated artifacts, but the
`.cco/` inventory (§2.1) and the sync-set (§4.1) list only `project.yml`, `secrets.env(.example)`,
`claude/`. `mcp.json`/`setup.sh` can carry secrets; `.cco/managed/` is framework-generated
(should follow F1 → CACHE + `:ro` overlay, like `packs.md`).
**Fix**: extend the `.cco/` inventory + sync-set rule; classify `.cco/managed/` as generated →
CACHE. Candidate analysis: "project-config inventory completeness".

### H6 — Merge-engine path remap (`cco update` "unchanged" is true for logic, false for paths)
`paths.sh` helpers (`_cco_project_meta`/`_cco_project_base_dir`/`_cco_project_compose`) derive
everything from one project dir; the merge engine uses `.cco/base/` + `.cco/meta` as state
*inside* the project dir. Under the split, those are per-machine STATE but live in the
now-committed `.cco/`. The design says the merge engine is unchanged (N5) but does not remap
its paths.
**Fix**: specify that `.cco/base/` and `.cco/meta` move to STATE; `_cco_project_*` take
separate config vs state bases. Candidate analysis: "merge-engine path remap".

### H7 — Index concurrency + cross-project name-collision schema undecided
AD5 enables concurrent sessions, but the index is a single YAML written by several commands
with no lock/atomicity. Separately, the index `paths:` is a flat global map; two different
projects using the same logical name (`frontend`) on different paths collide with the
per-machine uniqueness invariant.
**Fix**: specify atomic write (temp+rename) + lock on `<state>/cco/index` (and the
sync-metadata); decide whether logical names are global-per-machine or namespaced per project.
Candidate analysis: "index concurrency & namespacing".

### H8 — `join` in Case C (divergent) flow underspecified
How divergence is detected before any sync-state exists (fresh machine); register-in-index vs
prompt-source order; whether membership may stay divergent after a "join all"; `join --sync`
source detection when fingerprints are empty (must degrade to on-the-fly content diff).
**Fix**: define the ordered join flow and state that Case-C membership may remain divergent by
design.

### H9 — Stale ADR range + deferred/resolved drift in living docs
`design.md:6-8` and `requirements.md:4-5` cite "ADR 0001–0006" (0007/0008 exist). `requirements`
§6 title "depth deferred" + AD10 "deferred to RD-home" contradict FR-C3/§8 "RD-home resolved".
`design.md` §12 still lists "`~/.cco` auto-management (RD-home)" as a future evolution though
ADR-0008 moved auto-sync to RD-triggers.
**Fix**: bump headers to 0001–0008; update §6 title/AD10 to "versioning model = ADR-0008,
auto-sync deferred to RD-triggers"; fix §12 ownership. *Doc-only.*

---

## Medium

- **M1 — sync edge cases**: target unresolved in index; non-git target (+ Case A first copy);
  whether `cco sync` secret-scans the copied set or only structurally excludes `secrets.env`;
  `--from <repo>` source without `.cco/`. *Fix*: define each.
- **M2 — sync-state lifecycle (when, not what)**: enumerate event→mutation (init/join/sync/
  migrate/resolve) for membership + last-synced fingerprint (§4.6).
- **M3 — remotes/tokens**: `.cco/remotes` (token-bearing) moves to STATE — migration not
  described; `cmd-remote.sh:123-174` is coupled to the vault git (`$USER_CONFIG_DIR/.git`) so it
  is NOT "unchanged"; make remotes file `0600` unconditionally.
- **M4 — index behavior details**: exact uniqueness-violation behavior (init/join *refuse* vs
  `path set` *rebind* for moves); repo-vs-extra_mount share the index namespace (collision);
  `refresh --scan` merge vs replace (replace loses non-discoverable extra_mounts).
- **M5 — extra_mounts schema/migration**: §2.4 example shows `name` but no container `target`;
  migration covers repos, not extra_mounts.
- **M6 — J0 bootstrap**: per-root idempotent creation (not all-or-nothing); order
  bootstrap-`~/.cco`-before-FR-M1-backup; where the legacy vault lives under packaging-awareness
  (AD11); backup idempotency (don't re-archive on decline); root/sudo behavior.
- **M7 — entry-point edge cases**: `cco init` when `.cco/` exists (idempotency, like migrate);
  `cco migrate` when backup lacks the project / no backup present.
- **M8 — migration ordering invariant**: `cco migrate` must verify backup integrity before
  reading; offer-to-remove only after verified backup (P3 deletes the only legacy reader).
- **M9 — test plan gaps (§11)**: XDG resolver matrix (unset/empty/relative/override, 0700,
  host-side); secret-scan `.example` exemption (skeleton passes, real `secrets.env` blocked) —
  note `_publish_scan_secrets` has no exemption today; reminder aggregator; F2 cross-tree
  collision warning.
- **M10 — `cco new` (ephemeral sessions)**: `cmd-new.sh:50-106` co-locates compose/state/.claude
  and uses `--repo <path>`; never mentioned in the design. *Fix*: declare it stays an
  index-less ephemeral path and document it.
- **M11 — memory regression record**: even with BL2, add a Consequences note in an ADR.
- **M12 — `.cco/remotes` content scan interplay**: the 2-pass scan with `.example` exemption
  now runs on arbitrary code repos (`<repo>/.cco/`), risk of false positives on other tools'
  `.env`; scope the scan to `<repo>/.cco/` only.

---

## Low

- **L1** — `requirements.md:330-331` "Next artifacts: design.md … ADR 0001" is stale (all exist).
- **L2** — terminology: "registry" reused for the retired legacy index, the remotes registry, and
  the pack/llms store; prefer "central pack/llms store" in ADR-0005 to avoid collision.
- **L3** — `design.md §259` names "RD-syncmeta" but it appears in no RD table; either add a
  "Resolved" row (absorbed into FR-Y-S6) or reword.
- **L4** — `requirements.md:300` cites "§4.6" unqualified (it is a design.md section).
- **L5** — symlink-installed `cco` (`bin/cco:11` BASH_SOURCE without realpath) → promote from an
  ADR-0007 note to a Phase-0 action item, since Phase-0 rewrites `lib/paths.sh`.
- **L6** — Windows/WSL: add an explicit non-goal ("Windows native out of scope; WSL = Linux").

---

## Recommended actions

**(1) Immediate doc-fixes — no new decisions** (align docs to decisions already made):
BL1 (ADR-0007 ↔ ADR-0008), H3 + H9 (stale phase/ADR refs, deferred/resolved drift, §12 ownership),
L1/L3/L4. Safe editorial pass.

**(2) Phase-plan / invariant write-downs** (small additions, direction is clear):
BL3 + L5 (Phase-0 action items: absolute mounts, symlink fix), H1 (ordered start sequence +
global invariant), H3 (aggregator phase split), H4 (host-side guard invariant), BL2 (RD-memory
gates Phase 3 + regression note), M8 (migration ordering), M9 (test-plan additions).

**(3) New dedicated analyses to schedule** (genuine decisions still open):
- **reminder-aggregator cost & scoping** (H2)
- **project-config inventory completeness** — mcp.json/setup.sh/mcp-packages.txt/.cco/managed (H5)
- **merge-engine path remap** under the split layout (H6)
- **index concurrency & namespacing** (H7)
- **sync-state lifecycle** event→mutation table (M2) + sync edge cases (M1)
- **join Case-C flow** (H8) + extra_mounts schema/migration (M5, M4)
- **RD-memory** (existing open RD; now a Phase-3 gate — BL2)

Phase 0 can start in parallel with (3); none of these new analyses block Phase 0, but H1/BL3/H4
and the Phase-0 action items should be folded into the Phase-0 spec first.
