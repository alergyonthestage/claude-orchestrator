# Coding Conventions — claude-orchestrator

> How to write new code in this codebase so it does not re-introduce the
> classes of bug that the pre-release hardening of 2026-04-22 had to
> clean up. Read this before adding new CLI commands, vault operations,
> or helpers that touch `project.yml`, `.cco/`, or the vault.

## Principles

1. **Single source of truth for classification and parsing.** If two
   callsites answer the same question ("is this a tracked file?", "is
   this a secret?", "which host path does this repo live at?"), they
   must go through the same helper. Two implementations of the same
   logic *will* drift — `#B10` (vault status vs diff divergent counts)
   is the canonical example.

2. **Small, named phases.** Top-level command handlers coordinate; they
   do not implement. When a handler grows past ~150 lines, extract its
   phases as `_<cmd>_<phase>` helpers with clear inputs and outputs.

3. **Pure collectors, side-effectful writers.** Data-collection
   functions output on stdout and do not modify files. Writers take
   explicit targets and do not silently re-derive data. Keep these
   roles distinct inside any feature.

4. **Protect atomicity with traps, not discipline.** Any operation that
   rewrites a working-copy file (e.g. `_extract_local_paths` swapping
   in `@local` markers) must set a restore trap *before* the write,
   clear it only when the restore is no longer correct, and always
   restore explicitly before `die` (because `exit` does not fire
   `trap ERR`). See the module header of `lib/cmd-vault.sh`.

## Shared services — use them, do not reimplement

The table below lists the canonical helpers for tasks that appear in
multiple places. **Do not inline these** — reach for the helper, or
extend it if your case is not covered.

| Task | Helper | Module |
|---|---|---|
| Categorize a vault-relative file (packs / projects / global / templates / metadata) | `_vault_categorize_file` | `lib/cmd-vault.sh` |
| Count "real" vault changes excluding virtual `@local` diffs | `_vault_has_real_changes` | `lib/cmd-vault.sh` |
| Parse `git status` output (always `--porcelain --no-renames`) | inline, but use the exact flag string | `lib/cmd-vault.sh` |
| Extract machine-specific paths from `project.yml` to `@local` | `_extract_local_paths` | `lib/local-paths.sh` |
| Restore real paths from `.cco/local-paths.yml` | `_restore_local_paths` / `_resolve_all_local_paths` | `lib/local-paths.sh` |
| Resolve `@local` + legacy `{{REPO_*}}` for a project (install flow) | `_resolve_installed_paths` | `lib/local-paths.sh` |
| Same, for `cco start` (stricter: non-TTY fatal) | `_resolve_start_paths` | `lib/local-paths.sh` |
| Read a section from `local-paths.yml` as `k=v` lines | `_local_paths_get_section` | `lib/local-paths.sh` |
| Read a single value from `local-paths.yml` | `_local_paths_get` | `lib/local-paths.sh` |
| Match a path against known secret filename patterns | `_secret_match_filename` | `lib/secrets.sh` |
| Scan a file's content for secret indicators | `_secret_match_content` | `lib/secrets.sh` |
| Read `.cco/publish-ignore` skipping blanks/comments | `_read_publish_ignore` | `lib/cmd-project-publish.sh` |
| Get a repo's host path from `project.yml` in "path:name" form | `yml_get_repos` + `IFS=: read -r path name` | `lib/yaml.sh` |
| Get a project's `.cco/meta` / `.cco/base` / `.cco/source` path | `_cco_project_meta` / `_cco_project_base_dir` / `_cco_project_source` | `lib/paths.sh` |
| Self-heal vault `.gitignore` to match `_VAULT_GITIGNORE` template | `_ensure_vault_gitignore` | `lib/cmd-vault.sh` |
| Untrack stale pre-save backups at any branch | `_untrack_stale_pre_save` | `lib/cmd-vault.sh` |
| Remove ghost project directories and orphan shadows post-switch | `_clean_branch_ghost_projects` | `lib/cmd-vault.sh` |
| Test if a filesystem path exists (file OR directory) | `_path_exists` | `lib/utils.sh` |
| Get the effective source path for every repo / mount of a project (single source of truth for display + runtime) | `_project_effective_paths` | `lib/local-paths.sh` |
| Die if any project.yml path is unresolved or missing (start guard) | `_assert_resolved_paths` | `lib/local-paths.sh` |

## Rules you are likely to violate

### Vault operations that rewrite `project.yml`

If your code runs `_extract_local_paths`, it **must** restore on every
exit path. The trap-and-manual-restore pattern in `cmd_vault_save`,
`cmd_vault_diff`, `_vault_has_real_changes`, and
`cmd_vault_profile_switch` is the template. Read the module header of
`lib/cmd-vault.sh` for the two invariants.

### `git status` parsing

Always use `--porcelain --no-renames`. `--short` is an alias in
practice but makes parser assumptions implicit, and rename detection
(default in recent git) emits `R  old -> new` that breaks naive
`${line:3}` extraction. See `lib/cmd-vault.sh` (all seven callsites).

### Secret-like files

Do not inline `*.env`, `*.key`, `.credentials.json`, `.netrc`,
`secrets.env`, `.cco/remotes`. Call `_secret_match_filename`. If you
believe a new pattern is universally a secret, add it to
`_SECRET_FILENAME_PATTERNS` in `lib/secrets.sh` so every gate picks it
up at once.

### Repo path parsing

`yml_get_repos` emits `path:name` lines. Split with
`IFS=: read -r path name` only; **never** `cut -d:` — that truncates
the first colon which, while rare in paths, is a silent corruption.

### Command handlers

A new `cmd_<command>` that grows past ~150 lines is a smell. Split it
into phases named after what they *do*, not the step number. Example:
`_publish_check_migrations`, `_publish_scan_secrets`,
`_publish_check_framework_alignment` replace the `STEP 1/2/3` block
comments in `cmd_project_publish`.

### DRY for migrations

Every migration must be idempotent (safe to re-run). If a migration
turns out to be wrong (as `012` did), **do not amend it** — add a
corrective migration at the next ID (as `013` did) and annotate the
original as superseded. Existing users have already run the broken
migration; changing its behavior invalidates their state.

### Prefer runtime invariants to migrations for cross-branch state

A migration runs on the currently checked-out branch. When a fix must
apply to every profile branch of a git-backed vault (e.g. a missing
`.gitignore` pattern), a single migration leaves all other branches
untouched forever. Prefer a **runtime invariant** — a self-heal helper
that every entry point calls — over a migration that cannot reach the
branches it needs to.

Examples: `_ensure_vault_gitignore`, `_untrack_stale_pre_save`,
`_clean_branch_ghost_projects`. See vault/file-classification.md §8.

### Paths that may be files: use `_path_exists`, not `-d`

`repos[].path` is always a directory, but `extra_mounts[].source` can
be a single file (e.g. a `.docx`, a `.md`). Every existence check on a
user-supplied project path must use `_path_exists` (which tests `-e`
after `~` expansion). Literal `[[ -d "$p" ]]` checks on mount sources
produce false negatives and flow through to prompt / die paths.

### `cco start` and `@local` resolution

`cco start` must call `_assert_resolved_paths` after
`_resolve_start_paths`. Do not silently `continue` on a residual
`@local` during compose generation — a silently-skipped mount becomes
a Docker empty bind (#B17). If `_resolve_start_paths` cannot guarantee
every entry is resolved, that is a bug in the resolver, not something
to paper over downstream.

### Two sources of truth for the same question → single helper

`cmd_project_resolve --show` and `cco start` both answer "where does
this repo live on this machine?". They must use the **same** helper —
`_project_effective_paths` — so a `✓ exists` in display never diverges
from an "Unresolved" at runtime (#B18). Same class as #B10. Whenever
two commands respond to the same data-model question, add or reuse a
canonical reader; never copy the loop.

## Case study — `#B10` (vault status vs diff divergence)

### What happened

On a vault with resolved machine paths in `project.yml`, `cco vault
status` reported *N uncommitted files* while `cco vault diff` reported
*no uncommitted changes* on the same state.

### Root cause

`cmd_vault_status` and both branches of `cmd_vault_profile_show` ran
`git status --porcelain` directly and counted raw lines. `cmd_vault_save`
and `cmd_vault_diff` instead normalized via `_extract_local_paths` plus
`_untrack_stale_pre_save` before counting. The three status-read
callsites were missed when normalization was added, so they counted
virtual diffs (real path vs committed `@local`) as real changes.

### Fix

Introduce `_vault_has_real_changes` as the single entry point for
"are there real changes?"; replace the three raw counts with this
helper. Extract `_vault_categorize_file` as the canonical categorizer
shared between save and diff. Regression test added in
`tests/test_vault.sh:test_vault_status_and_diff_agree_after_save_with_local_paths`.

### Lesson

When logic about a data model (what counts as a "change", what counts
as a "secret", how a path decomposes) lives in more than one place,
those places will go out of sync. Reach for a helper on the first
duplication, not the fifth.

## References

- `docs/maintainer/configuration/vault/file-classification.md` — the
  data model for how vault-relative files are categorized.
- `docs/maintainer/configuration/vault/local-path-resolution-design.md`
  — how `@local` markers and `.cco/local-paths.yml` interact during
  save, pull, switch, and start.
- `docs/maintainer/decisions/roadmap.md` — `#B10` and the
  pre-merge hardening entries track the findings this document codifies.
