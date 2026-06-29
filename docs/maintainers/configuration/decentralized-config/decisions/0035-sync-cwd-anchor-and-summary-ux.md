# ADR 0035 — `cco sync`: cwd-anchored `--from` target and a summary-first diff UX

**Status**: Accepted (2026-06-29) — pre-merge **Round 3 dogfooding** (host e2e on Mac); decisions land pre-merge
**Deciders**: maintainer + dogfooding session
**Context docs**: `../../roadmap.md` §"Round 3"; the live `cco sync` transcript that surfaced both issues
**Related ADRs**: **0003 (sync = copy, no merge engine)**, **0024 D1/D2 (project identity = `project.yml`
`name:`; the `cco sync` clobber-guard keys on it)**, **0033 (unified resolution surface — cwd-first)**,
**0022 D3 (`cco resolve --scan` upsert / the STATE index path binding)**; principles **P18** (one repo, one
config home) and the CLI-wide **cwd-anchor** convention (`_resolve_find_unit_dir`).

---

## Context

`cco sync` converges a project's per-repo `<repo>/.cco/` on one machine by copying a **source** repo's
committed synced set into **target** repos (ADR-0003: a filesystem copy, no merge). Two pre-merge UX
defects surfaced during host dogfooding:

1. **`--from <repo>` broadcast to *all* members by default.** The shipped matrix was `positional = TARGET,
   --from = SOURCE, default target = all members` — uniform on paper, but the implicit third rule
   ("missing target ⇒ all members") **collides with the cwd-anchor convention every other cco verb uses**
   (`cco start`, `resolve`, `project *`, `forget` all act on the repo you stand in). The natural workflow
   for a freshly cloned, not-yet-initialised repo is `cd repoB; cco sync --from repoA` meaning *"pull
   repoA's config into here"* — but the code iterated **every** member, prompting for repos the user never
   intended to touch. The transcript shows exactly this: standing in `cave-auth-web`, `cco sync --from
   cave-auth` also prompted for `cave-infrastructure`.

2. **The full diff floods the terminal.** Each out-of-sync target printed a complete unified diff before
   its confirm prompt. Against an absent target (a fresh repo) every file is a full addition — a 156-line
   `CLAUDE.md`, the whole `project.yml`, etc. — so the prompt is buried under hundreds of lines and the
   decision the user must make is invisible.

## Decision

### D1 — The cwd is an endpoint by default; `--from` targets the cwd repo

Re-anchor `cco sync` to the cwd, consistent with the rest of the CLI. The single rule:

> `cco sync` operates on the repo you are standing in, unless you fully specify both endpoints. `--from`
> says where config comes **from**; without `--from`, it comes **from here**.

Resulting matrix:

| Command                          | Source       | Targets                     |
|----------------------------------|--------------|-----------------------------|
| `cco sync`                       | current repo | all other member repos      |
| `cco sync <repo>`                | current repo | only `<repo>`               |
| `cco sync --from <repo>`         | `<repo>`     | **the current repo (cwd)**  |
| `cco sync <repoA> --from <repoB>`| `<repoB>`    | only `<repoA>`              |
| `cco sync --from <repo> --all`   | `<repo>`     | all other member repos      |

The cwd is one endpoint in every form except the explicit two-name form. `--from <repo>` with no positional
target resolves the target by **matching the cwd against the project's resolved member paths** in the STATE
index — so a **not-yet-initialised** member still matches (its path is indexed by `cco resolve --scan`,
ADR-0022 D3), which is the dominant use case (a fresh clone pulling config in).

### D2 — `--all` restores broadcast from an arbitrary source

The one capability the re-anchor removes is "broadcast from a non-cwd source" (the old meaning of `cco
sync --from X`). It is recovered two ways, both natural: `cd X; cco sync` (broadcast is anchored to where
you stand), or the explicit **`--all`** flag (`cco sync --from X --all`). `--all` combined with an explicit
positional target is contradictory and is **rejected**.

### D3 — A non-member cwd with `--from` (and no `--all`) is an error

If the cwd is not a member of the source's project and `--all` is absent, there is no implicit target.
Rather than silently fall back to broadcast (re-introducing the surprising magic this ADR removes), cco
**errors** with a directive message: *"the current directory is not a member of '<project>' — cd into the
target repo, pass a target name, or use --all to broadcast to all members."* Predictability over a
convenience fallback.

Rejected: auto-fallback to all-members broadcast when the cwd is not a member (less predictable; the same
command would do different things from different directories with no signal).

### D4 — Summary-first output; full diff via `--dry-run --dump`

The default `cco sync` view is a **compact per-file change summary**, not the full diff: one line per
changed file as `+ <rel>  (new, N lines)` or `~ <rel>  (mod, +A -B)`, under a header announcing the change
count. This gives the confirm prompt enough to decide on without flooding the terminal.

The complete unified diff stays one flag away: **`cco sync --dry-run --dump`** writes each target's full
diff to **`<target>/.cco/.tmp/sync-<source>.diff`** and copies nothing. This reuses the established
`cco start --dry-run --dump → .tmp/` idiom and is removable with `cco clean --tmp` (which already sweeps
`<repo>/.cco/.tmp/`). `--dump` requires `--dry-run`; `--check` is unchanged.

Rejected: an inline `[y/N/d=show diff]` prompt key (more interactive-loop code for the same end the
`.tmp/` dump reaches via an established idiom); paging the diff through `less` (awkward with the
per-target `/dev/tty` confirm read).

## Consequences

- **Pre-merge, no migration.** `cco sync` ships only on the unreleased `feat/vault/decentralized-config`
  branch, so the contract is fixed on the live path (pre-merge principle) — no changelog entry, no
  migration. The whole-refactor migration rides changelog #14/#15.
- **The synced set and the clobber-guard (ADR-0024 D2) are unchanged** — this ADR only changes target
  selection and the on-screen presentation, not what is copied or the divergence model (ADR-0003).
- **Tests**: `tests/test_sync.sh` gains the cwd-member target, non-member-cwd error, `--all` broadcast,
  `--all`+target rejection, summary-output, and `--dump`-to-`.tmp/` cases. Suite green at 1010/0.
