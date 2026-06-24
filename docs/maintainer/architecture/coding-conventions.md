# Coding Conventions — claude-orchestrator

> How to write new code in this codebase so it does not re-introduce the
> classes of bug that pre-release hardening had to clean up. Read this
> before adding CLI commands or helpers that touch `project.yml`, a repo's
> committed `<repo>/.cco/`, the personal `~/.cco` store, or the
> machine-local STATE index.

## Principles

1. **Single source of truth for classification and parsing.** If two
   callsites answer the same question ("is this a tracked file?", "is
   this a secret?", "which host path does this repo resolve to?"), they
   must go through the same helper. Two implementations of the same
   logic *will* drift — `#B10` (status vs diff divergent counts, see the
   case study below) is the canonical example.

2. **Small, named phases.** Top-level command handlers coordinate; they
   do not implement. When a handler grows past ~150 lines, extract its
   phases as `_<cmd>_<phase>` helpers with clear inputs and outputs.
   `cmd_start` is the live example: `_start_resolve_project`,
   `_start_load_config`, `_start_generate_compose`, … each do one thing.

3. **Pure collectors, side-effectful writers.** Data-collection
   functions output on stdout and do not modify files. Writers take
   explicit targets and do not silently re-derive data. Keep these
   roles distinct inside any feature.

4. **Atomic replace, not in-place mutation.** Any operation that rewrites
   a tracked or machine-local file must write a temp file and `mv` it
   into place (so a crash mid-write never leaves a half-written or ghost
   `foo.XXXXXX` file — see `#B20`). The STATE index is the template:
   `_index_set_path` writes to `mktemp` then `mv`s atomically. When a
   working-copy edit cannot be made atomic, set a restore trap *before*
   the write and restore explicitly before `die` (`exit` does not fire
   `trap ERR`).

## Shared services — use them, do not reimplement

The table below lists the canonical helpers for tasks that appear in
multiple places. **Do not inline these** — reach for the helper, or
extend it if your case is not covered.

| Task | Helper | Module |
|---|---|---|
| Resolve a logical name → absolute host path (the name→path map) | `_index_get_path` / `_index_set_path` | `lib/index.sh` |
| Parse repo coordinates (`name` + optional `url`/`ref`) from project.yml | `yml_get_repo_coords` | `lib/yaml.sh` |
| Parse extra-mount coordinates (`name` + optional `url`/`ref`/`target`/`readonly`) | `yml_get_mount_coords` | `lib/yaml.sh` |
| Resolve one referenced name into the index (prompt/clone if missing) | `_resolve_entry_index` | `lib/local-paths.sh` |
| Get the effective source path + status for every repo / mount of a project (single source of truth for display + runtime) | `_project_effective_paths` | `lib/local-paths.sh` |
| Die if any referenced path is unresolved or missing (the `cco start` guard) | `_assert_resolved_paths` | `lib/local-paths.sh` |
| Match a path against known secret filename patterns | `_secret_match_filename` | `lib/secrets.sh` |
| Scan a file's content for secret indicators | `_secret_match_content` | `lib/secrets.sh` |
| Parse `git status` output (always `--porcelain --no-renames`) | `_emit_config_reminders` | `lib/reminders.sh` |
| Get a project's STATE `update/meta` / `update/base` dir or DATA `source` | `_cco_project_meta` / `_cco_project_base_dir` / `_cco_project_source` | `lib/paths.sh` |
| Test if a filesystem path exists (file OR directory) | `_path_exists` | `lib/utils.sh` |

> Path resolution is **index-only**. There is no `@local` marker, no
> `.cco/local-paths.yml`, and no `path:` field in `project.yml` — a repo
> or mount is a logical name, and its absolute host path lives in the
> machine-local STATE index (`lib/index.sh`). The sole exception is
> `_local_paths_get` (`lib/local-paths.sh`), a read-only reader kept so
> `cco init --migrate` can recover real paths from a *legacy vault backup*.

## Rules you are likely to violate

### Operations that rewrite a tracked or machine-local file

Write to a temp file and `mv` it into place; never edit in place. The
STATE index (`lib/index.sh`) and the update-merge engine
(`lib/update-merge.sh`) are the templates. Always set a `trap … RETURN`
that removes the temp file so a failed `awk`/`mv` never leaves a
`foo.XXXXXX` ghost in the working tree (`#B20`).

### `git status` parsing

Always use `--porcelain --no-renames`. `--short` is an alias in
practice but makes parser assumptions implicit, and rename detection
(default in recent git) emits `R  old -> new` that breaks naive
`${line:3}` extraction. See `lib/reminders.sh` (the cross-repo
divergence reminder) for the canonical invocation.

### Secret-like files

Do not inline `*.env`, `*.key`, `.credentials.json`, `.netrc`,
`secrets.env`, the DATA `remotes` registry. Call `_secret_match_filename`.
If you believe a new pattern is universally a secret, add it to
`_SECRET_FILENAME_PATTERNS` in `lib/secrets.sh` so every gate
(`cco config save`, `cco pack publish`, `cco project export`) picks it up
at once.

### Repo / mount path resolution

`project.yml` carries logical names only. Read them with
`yml_get_repo_coords` / `yml_get_mount_coords` (each emits
`name\turl\tref…`), then resolve the absolute path with
`_index_get_path "$name"`. **Never** parse a host path out of
`project.yml` — there is none (AD3/G8: no real host path ever enters
committed config). A name with no index entry is *unresolved*; surface
it via the resolver, never fabricate a path.

### Command handlers

A new `cmd_<command>` that grows past ~150 lines is a smell. Split it
into phases named after what they *do*, not the step number. `cmd_start`
(its `_start_*` phases) and `cmd_pack_publish` (`_pack_sync_merge`,
`_record_pack_base`, `_pack_internalize_knowledge`) are the templates —
no `STEP 1/2/3` block comments.

### DRY for migrations

Every migration must be idempotent (safe to re-run). If a migration
turns out to be wrong (as `012` did), **do not amend it** — add a
corrective migration at the next ID (as `013` did) and annotate the
original as superseded. Existing users have already run the broken
migration; changing its behavior invalidates their state.

### Paths that may be files: use `_path_exists`, not `-d`

A repo path is always a directory, but an `extra_mounts` source can be a
single file (e.g. a `.docx`, a `.md`). Every existence check on a
resolved project path must use `_path_exists` (which tests `-e` after
`~` expansion). Literal `[[ -d "$p" ]]` checks on mount sources produce
false negatives and flow through to prompt / die paths.

### `cco start` path resolution and the start guard

`cco start` must call `_assert_resolved_paths` after
`_resolve_start_paths`. Do not silently `continue` on an unresolved
reference during compose generation — a silently-skipped mount becomes a
Docker empty bind (`#B17`). The resolver is the place that decides
whether to prompt, clone, or consciously skip (P14): a skipped member is
excluded from the mount set *and* ⚠-badged, never papered over
downstream.

### Two readers for the same question → single helper

Everything that answers "where does this repo resolve on this machine?"
— the start guard, `cco resolve`, `cco project show` — must derive from
the **same** reader, `_project_effective_paths`, so a `✓ exists` in one
view never diverges from an "unresolved" in another (`#B18`, same class
as `#B10`). Whenever two commands respond to the same data-model
question, add or reuse a canonical reader; never copy the loop.

## Case study — `#B10` (status vs diff divergence)

### What happened

A versioned config tree reported *N uncommitted files* from one read
path while a second read path reported *no changes* on the same state.

### Root cause

Two callsites answered "are there real changes?" independently: one
counted raw `git status --porcelain` lines, the other normalized first
and then counted. The raw-count callsites were missed when normalization
was added, so they counted virtual diffs as real changes.

### Lesson

When logic about a data model (what counts as a "change", what counts
as a "secret", how a path resolves) lives in more than one place, those
places will go out of sync. Reach for a helper on the first
duplication, not the fifth. (`#B10` predates the decentralized-config
refactor — the vault subsystem it occurred in has since been removed —
but the lesson is why `_project_effective_paths` and
`_secret_match_*` are single entry points today.)

## References

- `docs/maintainer/configuration/decentralized-config/design.md` — the
  current config model: in-repo `<repo>/.cco/`, the personal `~/.cco`
  store, and the machine-local STATE index.
- `docs/maintainer/configuration/_archive/vault/` — the removed vault
  subsystem (historical: file classification and `@local`/local-path
  resolution), kept for the decision trail only.
- `docs/maintainer/decisions/roadmap.md` — `#B10`/`#B17`/`#B18`/`#B20`
  and the pre-merge hardening entries track the findings this document
  codifies.
