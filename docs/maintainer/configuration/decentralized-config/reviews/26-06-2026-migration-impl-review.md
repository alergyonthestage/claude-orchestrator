# Migration & Decentralized-Config Implementation Review — 26-06-2026

**Branch**: `feat/vault/decentralized-config`
**Type**: Pre-merge code/implementation review (read-only analysis; no code changed)
**Focus** (maintainer request):
1. Correctness & completeness of the legacy→decentralized **migration flow**
   (`any cmd` → backup → XDG bootstrap → `cco update` global migrate →
   `cco init --migrate` per-project) — resources transferred & transformed
   correctly, no bugs/gaps, no user-runnable paths/commands that break migration.
2. **Backup completeness for ALL profiles (every git branch)**, not just the active one.
3. General decentralized-config bugs + adherence to the approved design.

**Authoritative design**: `design.md` (source of truth) + `guiding-principles.md`
(P1–P18) + ADRs 0005–0027. Precedence: principles → ADRs → design → requirements.

**Method**: 6 parallel review subagents over distinct areas (A backup/first-run,
B global migrate, C per-project migrate, D paths/index, E user-command flows,
F test coverage) + direct lead reading of `migrate.sh`, `paths.sh`, `index.sh`,
`cmd-init.sh`, `cmd-update.sh`, `test_migrate.sh`. Every finding is code-grounded
and adversarially self-checked. Area **B was integrated in foreground by the lead**
(its subagent stalled on a Claude Code UI prompt and produced no report).

**Test baseline**: `test_migrate.sh` 33/0, `test_init.sh` 23/0, `test_update.sh`
global-migration tests green — 100% pass. The pass rate masks the data-loss bugs
below (the untested paths are exactly the gaps).

---

## Executive summary

- **The backup is COMPLETE for all profiles** (priority #2 answered): the raw `tar`
  includes the full `.git` (every branch's committed config) **and** every
  `.cco/profile-state/<branch>/` shadow (every inactive profile's gitignored
  secrets). Atomicity, idempotency, STATE location, 0600 are all correct. The
  backup loses nothing. ✓
- **The data-loss is in the per-project migration READER, not the backup.** For a
  project that lives only on a **non-active profile branch**, `cco init --migrate`
  extracts config via `git archive <branch>` (committed files only) and never reads
  the `profile-state/<branch>/` shadow — so that project's **secrets** (BL1) and
  **memory** (BL2) are silently dropped. This is the central correctness gap.
- **2 BLOCKER, 7 HIGH, 10 MEDIUM, 9 LOW, several NIT.** No issue corrupts a
  recoverable state irreversibly (the backup is the net), but BL1/BL2 cause silent
  data loss for a design-validated multi-profile use case, and several HIGH issues
  break the documented migration UX or leak extracted secrets to `/tmp`.

---

## BLOCKER — silent data loss (fix before merge)

### BL1 · Inactive-profile project **secrets** silently lost
- **Where**: `lib/migrate.sh:562–591` (`_cco_migrate_project`)
- **What**: A project found only on a non-active branch is materialized with
  `git archive "$b" "projects/$project" | tar -x` (line 567) — committed files only.
  `secrets.env` is gitignored, so it is **not** in the git tree and not extracted.
  The file-copy loop then copies `$leg/secrets.env` (line 589) which does not exist.
  The code **never reads `.cco/profile-state/<branch>/projects/<project>/`**, where
  an inactive profile's gitignored secrets live.
- **Design**: `design.md §9` — "the reader reads a project's machine-agnostic config
  from the archived branch and its secrets from the working tree / the matching
  `profile-state/<branch>/` shadow." The shadow read is missing.
- **Impact**: Any project on a non-active vault profile migrates without secrets;
  fails at auth/API at first `cco start`. No error, no warning.
- **Fix**: Track the branch the project was found on (`found_on_branch`), then for
  each gitignored file fall back to `"$tmp/.cco/profile-state/$found_on_branch/projects/$project/$f"`.
- **Confidence**: High (2 independent agents + design quote + git invariant).
  *Sources: C1, F-MULTIPROFILE.*

### BL2 · Inactive-profile project **memory** silently lost
- **Where**: `lib/migrate.sh:612–617`
- **What**: Same root cause as BL1. Memory relocation copies from `$leg/memory`
  (the git-archived tree), which lacks the gitignored memory for an inactive-profile
  project. The shadow (`profile-state/<branch>/projects/<project>/.cco/claude-state/memory/`)
  is never read.
- **Design**: `design.md §9` (ADR-0009) — migrate copies the project's `memory/`
  from the backup into `<state>/cco/projects/<id>/memory/`.
- **Fix**: Extend the BL1 `found_on_branch`/shadow fix to memory (try `$leg/memory`,
  `$leg/.cco/claude-state/memory`, then the shadow path).
- **Confidence**: High. *Source: C2.*

---

## HIGH

### H1 · Global populate is non-atomic, fails silently, and leaks its temp dir
- **Where**: `lib/migrate.sh:198–262` (`_cco_populate_global_from`), `:330–331`;
  caller `lib/cmd-update.sh:142` (`_cco_migrate_global || true`)
- **What**: `cp -r` into `~/.cco/global/.claude` is not staged/atomic; a mid-copy
  failure leaves a **partial** `~/.cco/global/.claude` that `check_global` then
  accepts (sessions launch with incomplete global config). The failure is swallowed
  by `|| true` (no warning), and the extracted-vault temp dir (`$tmp`, contains
  `secrets.env`) is leaked because the `rm -rf "$tmp"` at line 331 is skipped on a
  non-zero populate.
- **Fix**: stage into a temp sibling of `~/.cco/global` + atomic `mv`; add a cleanup
  trap on `$tmp`; emit a `warn` on non-zero return instead of swallowing it.
- **Confidence**: High. *Source: E7 (foreground-confirmed).*

### H2 · `trap … RETURN` bypassed by `die` → extracted vault (with secrets) leaked to `/tmp`
- **Where**: `lib/migrate.sh:558` (and the same anti-pattern at `lib/cmd-init.sh:251`)
- **What**: `die()` calls `exit 1`; a `RETURN` trap does **not** fire on `exit`, only
  on `return`. Every `die` after the extraction (lines 571, 578, 605, 610) leaks
  `$tmp` — which holds the fully extracted vault including `global/secrets.env` and
  project `secrets.env`. The most common trigger is line 578 ("already registered"),
  hit whenever a user re-runs `cco init --migrate`.
- **Design**: `design.md §9` F44 — "partials cleaned on failure."
- **Fix**: use `trap "rm -rf '$tmp'" EXIT` (the convention already used in
  `cmd-new.sh`, `cmd-start.sh`, `cmd-pack.sh`).
- **Confidence**: High. *Sources: C4, E1.*

### H3 · Per-project migrate skips the AD5 index conflict check + F12 name-uniqueness is asymmetric
- **Where**: `lib/migrate.sh:621–627`; cross-ref `lib/cmd-init.sh:231–234`, `lib/index.sh:18`
- **What (two coupled defects)**:
  1. `_cco_migrate_project` calls `_index_set_path "$rname" "$rpath"` **unconditionally**.
     `index.sh` states AD5 conflict policy is the caller's job (`_index_path_conflicts`),
     and `cco init`/`cco resolve --scan` honor it — but migrate does not. Two legacy
     projects sharing a logical repo name → the second migrate silently overwrites the
     first's binding (ADR-0002/AD5 violation).
  2. F12 name-uniqueness is checked inconsistently: `cco init` checks the `paths:`
     section (`_index_get_path "$name"`), but `_cco_migrate_project` registers the
     project name only under `projects:` (repos go to `paths:`). So `migrate X` then
     `cco init --name X` (other repo) is **not** detected and clobbers the migrated
     project's membership.
- **Fix**: add a per-repo `_index_path_conflicts` guard in migrate; make init/migrate
  check the same section(s) for the project name.
- **Confidence**: High. *Sources: C3 + lead.*

### H4 · config-editor pollutes the global flat index, bypassing AD5
- **Where**: `lib/cmd-start.sh:71–73`
- **What**: `_index_set_path "cco-docs" "$REPO_ROOT/docs"` binds the **framework's own
  dev `docs/` path** into the user's persistent machine-local index on every
  `cco start config-editor`; `_index_set_path "${target_name}-config" …` can silently
  clobber a legitimate user binding (e.g. a repo named `myapp-config`). Raw
  `_index_set_path` bypasses the AD5 check; entries persist forever with no cleanup.
- **Fix**: route config-editor runtime mounts through a session-scoped mechanism (or a
  reserved `_cco_*` namespace excluded from AD5/`cco path list`), not the persistent index.
- **Confidence**: High. *Source: E2.*

### H5 · `check_global` misdirects legacy users to `cco init` instead of `cco update`
- **Where**: `lib/utils.sh:73–76` (called by `cmd_start`, `cmd_new`, `cmd_pack_*`, etc.)
- **What**: A legacy user who runs `cco start`/`cco new`/`cco pack …` before `cco update`
  is told "Run 'cco init' first." Per ADR-0025 the correct path is `cco update` (which
  populates `~/.cco` from the vault). Following the message runs `cco init`, which seeds
  `~/.cco/global` from **framework defaults** (not the vault) and then forces an
  unexpected overwrite-confirm dialog on the next `cco update`.
- **Fix**: make the message vault-aware — if a backup exists, point to `cco update`.
- **Confidence**: High. *Source: E3.*

### H6 · `cco join` implements Journey C only (not Journey E) + guides to a failing command
- **Where**: `lib/migrate.sh:661–684`
- **What**: `design.md §7/§8` define `cco join <project>` as registering the current
  repo **and adding it to `repos[]` in the project's `project.yml`** (Journey E: add a
  new member). The implementation only reads an existing `.cco/project.yml` and binds
  its members in the index (Journey C) — it never edits any `project.yml`. There is
  currently no supported way to add a new member repo without hand-editing. Also, the
  success message tells the user to run `cco resolve <name>`, which fails (by-name
  resolution needs an already-bound member path that join did not create).
- **Fix**: either implement Journey E (append to `repos[]`) or correct the help/message
  to the actual Journey-C semantics and bind the host repo's own name to `$PWD`.
- **Confidence**: High. *Sources: E-D1, D-D1.*

### H7 · Missing STATE path helpers; `_cco_project_claude_state` returns the wrong (repo-local) path
- **Where**: `lib/paths.sh:136–138`
- **What**: `paths.sh` is the canonical path reference, but it has no helper for the
  STATE session/memory/claude-state layout that `cmd-start.sh` and `migrate.sh`
  hardcode (`<state>/cco/projects/<id>/session/…`). `_cco_project_claude_state` returns
  a repo-local `<repo>/.cco/claude-state` path that no live code writes — actively
  misleading. (Same family as M10 orphaned helpers.)
- **Fix**: add `_cco_project_session_dir`/`_cco_project_memory`/`_cco_project_claude_state_dir`
  (name-keyed, like `_cco_project_cache_managed`); deprecate/rename the legacy helper.
- **Confidence**: High. *Source: D2.*

---

## MEDIUM

### M1 · Cross-filesystem `mv` of the stage breaks the F44 atomic-move guarantee
- **Where**: `lib/migrate.sh:610`; `lib/cmd-init.sh:293`
- **What**: the stage is `mktemp -d "${TMPDIR:-/tmp}/…"` and is `mv`'d into `<repo>/.cco`.
  When `$TMPDIR` and the repo are on different filesystems (Linux `/tmp`=tmpfs), `mv`
  is copy-then-unlink, **not** an atomic rename — a failure mid-copy leaves a partial
  `.cco/` (violating "a partial `.cco/` never survives a failure"). On macOS hosts
  `$TMPDIR` is usually the same volume, so it is platform-dependent — but the guarantee
  is stated unconditionally and the fix is cheap.
- **Fix**: stage as a sibling of the target (`<repo>/.cco.tmp.XXXX`) so `mv` is always a
  same-filesystem rename.
- **Confidence**: High (semantics); Medium (platform-dependent impact). *Source: lead.*

### M2 · Profile-exclusive pack gitignored secrets not migrated (global)
- **Where**: `lib/migrate.sh:256` (`git archive "$branch" "packs/$pack"`)
- **What**: profile-exclusive packs are pulled per-branch via `git archive`, which
  serializes committed files only — a pack's gitignored secrets in
  `profile-state/<branch>/packs/<pack>/` are not migrated. Same root cause as BL1.
  `design.md` is silent on whether pack-level profile-state secrets should survive.
- **Fix**: design decision first; if yes, mirror the BL1 shadow read for packs.
- **Confidence**: High (mechanism). *Sources: B (foreground), F-MULTIPROFILE-PACKS.*

### M3 · Inactive profiles' global secrets not surfaced (only the active profile's)
- **Where**: `lib/migrate.sh:212–215`
- **What**: the global populate copies `secrets.env` from the active profile only
  (`$src/global/secrets.env` or `$src/secrets.env`). The decentralized model has a
  single `~/.cco/secrets.env`, so inactive profiles' global secrets (present in the
  backup shadows) are not surfaced. Likely an inherent profile→tag collapse, but it
  is currently **silent** — it should be an explicit, documented accepted-regression
  (and ideally a printed note pointing at the backup).
- **Fix**: print a note when non-active profiles carry global secrets; record the
  regression in design/ADR.
- **Confidence**: Medium. *Source: B (foreground).*

### M4 · Non-TTY profile→tag prompt silently converts (additive without consent)
- **Where**: `lib/migrate.sh:641–648`
- **What**: in a non-TTY context `ans=""` and `[[ "" != "n" ]]` is true → the tag is
  seeded without consent. ADR-0010 §5 / design.md §9 specify a prompt (opt-in). The
  sibling destructive prompt (`_cco_confirm_overwrite_global`) correctly defaults to
  skip on non-TTY; this additive one should too.
- **Fix**: default to skip when no TTY (and no `CCO_ASSUME_YES`).
- **Confidence**: High. *Source: C5.*

### M5 · `cco config validate --fix` can prune migrated memory in a half-migrated state
- **Where**: `lib/cmd-config.sh` (`_cv_scan_dirs`); `lib/migrate.sh:613–627`
- **What**: migrate writes memory (line 613–616) **before** registering the index
  (line 621–627). If interrupted in that window, `STATE/projects/<id>/memory` exists
  with no index entry → `cco config validate` flags it as an orphan and `--fix`
  (`rm -rf`) destroys the migrated memory; the confirm label gives no provenance hint.
- **Fix**: copy memory **after** index registration (so a failed index write leaves a
  no-memory orphan), and annotate the validate label when an orphan contains `memory/`.
- **Confidence**: High (scenario); Medium (needs interruption). *Source: E5.*

### M6 · `cco new --name` is unvalidated → shell / path-traversal / YAML injection (SECURITY)
- **Where**: `lib/cmd-new.sh:20, 56, 63–65, 98, 176`
- **What**: `--name` flows unvalidated into an EXIT-trap `rm -rf "/tmp/cc-${name}"`
  (shell injection: `--name 'x" && rm -rf ~ #'`), into `tmp_dir` (path traversal:
  `--name '../../../bar'`), and verbatim into the generated docker-compose
  (`container_name`/`name`/env). `cco start` validates `project_name`; `cco new` has no
  equivalent guard.
- **Fix**: validate `^[a-zA-Z0-9][a-zA-Z0-9_-]*$` immediately after parsing (mirror
  `_start_load_config`); safe-quote the trap path.
- **Confidence**: High. *Source: E6.*

### M7 · `_prompt_for_path` stores non-absolute paths in the index
- **Where**: `lib/local-paths.sh:139–145`; `lib/utils.sh:11–17` (`expand_path` only
  expands `~`, not relative→absolute)
- **What**: a user-typed `../myrepo` passes existence (relative to cwd) and is stored
  relative in the index; from another cwd it resolves wrong/missing. `cco path set`
  correctly uses `_resolve_to_abs`; this prompt does not. Violates design.md §3
  "absolute paths only."
- **Fix**: absolutize after `expand_path` (reuse `_resolve_to_abs`).
- **Confidence**: High. *Source: D3.*

### M8 · `ls … | head -1` selects the OLDEST backup
- **Where**: `lib/migrate.sh:318` (`_cco_migrate_global`), `:549` (`_cco_migrate_project`)
- **What**: timestamp-named archives sort ascending; `head -1` picks the oldest. Benign
  while the idempotency guard keeps a single archive, but if a second archive ever
  appears (e.g. marker deleted → re-backup) migration reads the stale older one. F43
  says the authoritative archive is the newest.
- **Fix**: `… | sort | tail -1` (newest) + warn when more than one exists; use a glob
  array form instead of parsing `ls`.
- **Confidence**: High. *Sources: A1, E4, lead.*

### M9 · `_index_ensure_file` scaffold write is non-atomic (H7 deviation)
- **Where**: `lib/index.sh:39–48`
- **What**: the index scaffold is written with a direct `{ … } > "$f"`, the sole
  exception to the `mktemp + mv` convention used by every other index mutation
  (ADR-0022 D2 H7).
- **Fix**: write to `mktemp "${f}.XXXXXX"` then `mv`.
- **Confidence**: High. *Source: D4.*

### M10 · Orphaned legacy path helpers (dead code, wrong paths)
- **Where**: `lib/paths.sh:128–134` (`_cco_project_managed`, `_cco_project_compose`),
  `:154–156` (`_cco_project_pack_manifest`)
- **What**: no live callers (grep-verified); they return repo-local paths that no
  current code writes (compose/managed now live in STATE/CACHE; pack-manifest was
  removed by ADR-0013 D6). A future caller would get a wrong answer.
- **Fix**: remove them; add the correct STATE helper(s) (see H7).
- **Confidence**: High. *Sources: D5 + lead.*

---

## LOW

- **L1** · `for b in $(git for-each-ref …)` word-splits on branch names with spaces —
  `migrate.sh:565, 447`; use `while IFS= read -r`. (Also a prerequisite for the BL1
  `found_on_branch` fix.) *C7, E8.*
- **L2** · Legacy repo entry with only `path:` (no `name:`) is silently dropped by the
  `_migrate_legacy_repos` awk `flush()` — `migrate.sh:362–373`; warn on drop. *C6.*
- **L3** · `vault|` exception in `_cco_first_run` is dead code (the `vault` verb was
  removed from the dispatcher) — `migrate.sh:174`. *A2, lead.*
- **L4** · `chmod 0600 "$tmp" || true` swallows a chmod failure → archive could keep
  umask perms (mitigated by the 0700 backups dir) — `migrate.sh:150`. *A3.*
- **L5** · `design.md §3` index schema example (`{ repos: [...] }`, unquoted paths)
  diverges from the implemented `name: "space-separated"` format. *D6.*
- **L6** · `_cco_in_container` HOME check false-positives for a host user named
  `claude` — `paths.sh:226`. *D7.*
- **L7** · `_index_section_get` awk strips ALL quotes → index paths containing a single
  quote are silently corrupted — `index.sh:69`. *D8.*
- **L8** · `cco forget` on a half-migrated project deletes the migrated memory and the
  remaining `.cco/` then blocks re-migrate; the die message could suggest `cco join`
  as the no-loss recovery. *E9.*
- **L9** · Stale references in `cmd-update.sh`: comment at `:140` says the gate is
  "~/.cco/global presence" (the code uses the `global-migrated` marker, ADR-0026); TODO
  at `:218` still references legacy `user-config/packs/*`. *lead.*

## NIT
- `tar … 2>/dev/null` swallows the failure cause in the backup warning (`migrate.sh:139,145`). *A4.*
- "never fatal" comment at `bin/cco:156` describes only the backup step; bootstrap can
  abort under `set -e`. *A5.*
- Redundant `*/secrets.env` clause in the secret-scan loop (already excluded by `find`)
  — `migrate.sh:603,607`. *C8.*
- Misleading "runtime artifact, never committed" comment on the persistent index writes
  in config-editor — `cmd-start.sh:68–72`. *E-N1.*
- `_index_section_get` exact section-header match is fragile to hand edits; `REPO_ROOT`
  via `BASH_SOURCE` without `realpath` is symlink-unsafe (pre-existing, ADR-acknowledged). *D-N1/N2.*

---

## Verified-clean (confirmed correct)

- **Backup all-profiles completeness** (priority #2): `.git` + all `profile-state/<branch>/`
  shadows included; only `.cco/backups` excluded; STATE location; 0600; M8 ordering
  (`_cco_first_run` before dispatch); F43 idempotency (archive-as-authoritative-signal,
  marker self-heal, no destructive re-archive on wiped marker); F44 atomicity of the
  archive `mv` (same-dir rename). *A.*
- **Machine-agnostic `project.yml`** — all absolute paths routed to the index only;
  `name`/`url`/`ref` only in the committed file; no `@local`/host path leaks; tab-peel
  handles empty middle fields. *C.*
- **Non-clobber** `.cco/` (refuses pre-existing) and STATE `memory/` (`cp -rn`). *C.*
- **gitignore-heal** writes the secret-exclusion `.gitignore` before the move; tags →
  DATA `tags.yml`; `_cco_project_origin_profile` reads from git history (works for
  non-active branches). *C.*
- **Reads from the verified backup**, never the live vault (global + project). *A, C.*
- **Bucket resolvers** (CONFIG/DATA/STATE/CACHE) match ADR-0007/0015 defaults +
  `$CCO_*_HOME`/`$XDG_*_HOME` precedence; `_cco_first_abs` robustness; 0700 dirs;
  bash-3.2/`set -u` array guards; DATA/STATE remotes split (token 0600 in STATE);
  anti-in-container guard; `local-paths.sh` fully subsumed by the index;
  index set/remove atomicity + AD5 keep-existing in `--scan`. *D.*
- **`cco resolve --scan` cannot block migration**; `cco update --check` clean &
  3-state; `cco forget` shared-repo guard; `share|manifest` verbs die cleanly;
  eager-migration ordering (runs before `check_global` in `cco update`);
  `cco new` writes nothing to the index. *E.*
- **Eager global migration**: marker-gated idempotency (ADR-0026); non-destructive
  overwrite (backup + confirm) when `~/.cco/global` pre-exists; offer-to-remove
  default-keep, never auto-deletes; profile-exclusive packs pulled per-branch +
  tagged; `_relocate_legacy_pack_sources` idempotent provenance→DATA. *B (foreground).*

---

## Test gaps (add alongside the fixes)

| Gap | Would catch | Source |
|---|---|---|
| Per-project migrate of a project on a non-active branch **with profile-state secrets/memory** | BL1, BL2 | F (c) |
| Profile-exclusive pack with gitignored profile-state files | M2 | F |
| Inactive-profile global secrets handling | M3 | B |
| Secret-scan rejection path (`die` on secret-like filename) | (security control) | F |
| `cco init --migrate --sync` propagation | (--sync) | F |
| Order-independence (migrate before `cco update`) | (ADR-0025 claim) | F |
| Corrupt/unreadable/truncated backup handling | (error paths) | F |
| Multi-branch global migrate (>1 non-default profile) | (multi-profile) | F |

---

## Recommended resolution order

1. **BL1 + BL2** (one fix: `found_on_branch` tracking + shadow read for secrets *and*
   memory; includes the L1 word-split fix as a prerequisite) — highest priority, silent
   data loss. Add the F-(c) test.
2. **H2** (RETURN→EXIT trap — leaked extracted secrets) and **H1** (atomic + non-silent
   global populate) — both touch secret-handling robustness.
3. **H3 / H4** (index AD5 integrity: migrate conflict check + config-editor pollution).
4. **H5 / H6 / H7** (migration UX & path-layout correctness).
5. **M-series** — M6 (security: `cco new` validation) and M1 (sibling-stage atomic move)
   first, then M2/M3 (need a maintainer design decision on profile-state pack/global
   secrets), then M4/M5/M7/M8/M9/M10.
6. **L / NIT** — batch cleanup.

> **Open design decisions for the maintainer** (M2/M3): should profile-exclusive pack
> secrets and inactive-profile global secrets survive migration, or are they an accepted
> profile→tag collapse (documented + backup-preserved)? This gates the M2/M3 fixes.

---

### Process note
Review area **B** (global migrate) was produced by the lead in foreground: the assigned
subagent stalled on a Claude Code "Try the new fullscreen renderer?" UI prompt at startup
and never ran its task. The lead had already read `_cco_migrate_global` /
`_cco_populate_global_from` directly, and corroborated with E (E7) and F, so B's area is
fully covered.

---

## Resolution log (2026-06-26)

All findings resolved on `feat/vault/decentralized-config` (commits local). Suite
**904/0** after the batch. Each fix shipped with a regression test unless noted.

| Finding | Status | Commit |
|---|---|---|
| BL1 inactive-profile project **secrets** from shadow | ✅ fixed | `d136344` |
| BL2 inactive-profile project **memory** from shadow | ✅ fixed | `d136344` |
| H1 atomic + non-silent + leak-free global populate | ✅ fixed | `08c9ce1` |
| H2 RETURN→EXIT trap (no extracted secrets left in /tmp) | ✅ fixed | `a5ced02` |
| H3 index AD5 in migrate + symmetric F12 | ✅ fixed | `29124e0` |
| H4 config-editor mounts via session override, not the index | ✅ fixed | `9db9bcf` |
| H5 check_global → `cco update` for legacy users | ✅ fixed | `c325985` |
| H6 cco join post-join guidance + Journey-E gap documented | ✅ fixed | `ec2f53a` |
| H7 migrated memory → `session/memory` (real latent bug) + paths.sh helpers | ✅ fixed | `c39ebd6` |
| M1 stage as target sibling → atomic move | ✅ fixed | `a5b2d7b` |
| M4 non-TTY profile→tag defaults to skip | ✅ fixed | `622632a` |
| M5 memory after index + validate annotates memory orphans | ✅ fixed | `81fc4e8` |
| M6 `cco new --name` injection guard | ✅ fixed | `6e1ba15` |
| M7 `_prompt_for_path` absolutizes before storing | ✅ fixed | `ea76f99` |
| M8 select newest backup, not oldest | ✅ fixed | `3c5a19f` |
| M9 `_index_ensure_file` atomic | ✅ fixed | `3dd49d0` |
| M10 remove dead `_cco_project_managed`/`_cco_project_compose` | ✅ fixed | `af9814f` |
| **M2** pack profile-state secrets | ✅ **no-op (premise verified false)** | — |
| **M3** global secrets merge across profiles | ✅ **no-op (premise verified false)** | — |

**M2/M3 verdict** (verified against the legacy vault's canonical
`_archive/vault/file-classification.md` + `profile-isolation-design.md §2.2/§2.4`):
- `global/` is **"Always shared"** — there is a single top-level `secrets.env`
  (gitignored, synced across all branches), **not** per-profile secrets. The global
  populate already copies it. Nothing to merge (M3).
- Packs have **no gitignored secrets** — the only pack gitignored path is
  `packs/*/.cco/install-tmp/` (runtime, skipped); `packs/*/.cco/meta` is committed.
  Any pack-local gitignored file also persists in the working tree (git never removes
  gitignored files), so `cp -r $src/packs` already captures it (M2).
- The profile-state shadow holds **only per-project** gitignored files, already
  recovered for every profile by BL1.
- Net: "all profiles' secrets must migrate" is fully satisfied by BL1 (per-project,
  incl. inactive profiles) + the existing single global `secrets.env` copy. No code.

Also fixed on `main` (legacy app would not start): hardened the `numStartups`
comparison in `_start_prepare_state` against non-numeric `jq` output (`71de5b2`).

**Remaining**: a few LOW/NIT polish items from the review, then the documentation review.
