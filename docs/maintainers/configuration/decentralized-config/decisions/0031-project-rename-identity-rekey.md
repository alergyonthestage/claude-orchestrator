# ADR 0031 — `cco project rename`: identity re-key across stores

**Status**: Accepted (2026-06-29) — pre-merge **dogfooding follow-up D** (host e2e of `cave-flow`)
**Deciders**: maintainer + dogfooding session
**Context docs**: the handoff
[`../cd-list-rename-handoff.md`](../cd-list-rename-handoff.md) (symptom, code map, test plan);
`../../roadmap.md` §"Dogfooding findings"
**Related ADRs**: **0024 D1 (project identity = `project.yml` `name:` = index key)**, 0021 (lifecycle —
`forget`/`init --migrate`), 0023 D1/D3 (`cco project` namespace), 0018 D2 (projects ride their
code-repo remote, not a sharing repo), 0029 D2 (uniform destructive-confirm)

---

## Context

A project's identity is its `project.yml` `name:` — the same string keys the STATE index
(`projects:`), the DATA tag registry (`projects:`), and the identity-keyed machine-local directories
(`<state|cache|data>/cco/projects/<name>/`). There was **no supported way to rename a project**: a
correct rename is therefore a **multi-store re-key**, not a single-file edit. A user asked for it
after `cco sync` during host dogfooding.

Two facts forced genuine decisions rather than a mechanical edit:

1. **`project.yml` is replicated across member repos.** `cco sync` copies the whole `<repo>/.cco/`
   (including `project.yml`) into every member repo, and its D2 clobber-guard uses `name:` as the
   discriminator — a member whose `name:` differs from the source is treated as "hosts a different
   project" and **skipped**. So if `name:` were rewritten in only *some* members, the others would
   diverge **permanently** (sync would keep skipping them), and another machine resolving an
   un-rewritten member would key it under the old name. The identity field must be rewritten across
   **all** member repos coherently or not at all.
2. **Identity is consumed verbatim (`id == name`).** No code sanitizes the name into the id — the
   index/tags/dir keys are the raw `name:`. A name containing `:` silently corrupts the index
   (`_index_section_*` split the key on the first `:`; read-back returns empty); `/` would nest the
   identity directories. Names are validated at the CLI creation points, but the three project
   entry points disagree (`cco init` allows `[a-z0-9-]`, `cco start` allows `[a-zA-Z0-9_-]`), and a
   rename adds a fourth place a name is set.

## Decision

### D1 — `cco project rename [<old>] <new>` (one new verb under the `cco project` namespace)

- **Forms**: `cco project rename <old> <new>` (explicit) and `cco project rename <new>` (cwd-first —
  renames the project hosting the current directory, via `_resolve_find_unit_dir`). Mirrors the
  cwd-first ergonomics of the other `cco project` verbs (`validate`/`coords`), ADR-0023 D1/D3.
- Lives in a new `lib/cmd-project-rename.sh` (`cmd_project_rename`), dispatched from `bin/cco`'s
  `project)` case. A project has no `install`/`publish`/`remove` (P13/ADR-0018 D2); `rename` joins
  `add`/`validate`/`coords`/`show`/`export`/`import` as an identity-lifecycle verb.

### D2 — What a rename re-keys (all keyed by the project name)

1. **`project.yml` `name:`** in **every** member repo's `.cco/` (`^name:` at column 0 — repo/pack
   `name:` keys are indented, so the rewrite cannot touch them).
2. **STATE index** `projects:` — `<old>` → `<new>` (member repo names unchanged; the `paths:`
   section is untouched).
3. **DATA tags** `projects:` — `<old>` → `<new>` (the tag set is carried over).
4. **Identity-keyed directories** — `<state|cache|data>/cco/projects/<old>` → `…/<new>` (each a
   move; a no-op when the directory is absent — e.g. a project never started has no STATE session
   dir).

New internal helpers keep the re-key DRY and testable: `_index_rename_project` (index.sh — set new +
remove old) and `_tags_rename` (tags.sh — get → set under new → forget old).

### D3 — Strict member resolution (no partial rename)

Because a partial `name:` rewrite breaks the cross-repo identity invariant (Context #1), the rename
**refuses** to proceed unless **every** member repo is resolved on this machine. An unresolved member
→ `die` with a "run `cco resolve` to bring all members onto this machine first" message; **nothing is
written**. For a single-repo project (the common case) this is always satisfiable from within the
repo, so there is zero added friction; the strictness only bites the multi-repo case, where it is the
safe behaviour. This is the maintainer's choice over best-effort+warn (which the handoff floated)
after the sharing-divergence evidence above.

### D4 — Validation, atomicity boundary, and ordering

- **Validate `<new>` before any write**: charset via the shared `_cco_valid_project_name` (D5),
  reserved names (`_check_reserved_project_name`), **uniqueness** (`_index_get_project_repos <new>`
  must be empty — the F12 pattern), and that the three identity **target** directories do not already
  exist (a stale-dir clash → refuse). `<old>` must resolve to a known project.
- **Confirm** (ADR-0029 D2): preview the plan (stores re-keyed, member repos touched) and confirm
  interactively; `-y`/`--yes` skips; **non-TTY without `-y` → die**. Rename is reversible, but it
  mutates several stores and rewrites `name:` in N git repos, so it takes the uniform confirm.
- **Atomicity boundary**: the machine-local re-key (index, tags, the three directory moves) is done
  together after pre-validation — each operation is individually atomic (`mktemp`+`mv`), and
  pre-validating every precondition makes a mid-way failure unlikely; true cross-store transactions
  are not achievable in bash and are not attempted. The cross-repo `project.yml` edits live in git
  working trees and **cannot** be transactional across repos → they are applied to all (resolved,
  hence all under D3) members, then the command **warns to commit + push + `cco sync`** each changed
  repo (P17 delegate-to-git, mirroring `cmd_sync`'s closing warnings).
- **Order**: resolve `<old>` + collect members → validate `<new>` → confirm → move STATE/CACHE/DATA
  dirs → `_index_rename_project` → `_tags_rename` → rewrite `name:` in each member → warn.

### D5 — One project-name definition (validate, don't sanitize)

A project name is an **identity** (`id == name`), so the correct tool is **validation that rejects**,
not sanitization that transforms (transforming the name to build an id would desync the two and break
every store keyed by the name). A shared predicate **`_cco_valid_project_name <name>`** (charset
`^[a-z0-9][a-z0-9-]*$` — the canonical lowercase-hyphen-digit form mandated by **Design Invariant
10** and already used by packs/templates/remotes; excludes uppercase, `_`, `:` `/` space and
YAML/shell specials) becomes the single definition, used by `cco init`, `cco start`, and `cco project
rename`. This also **closes a latent inconsistency**: `cco start` previously validated against a
looser `[a-zA-Z0-9_-]` regex than `init`'s canonical form, so it would have accepted names Invariant
10 forbids; unifying on the strict predicate makes `start` enforce the invariant too. No name that a
conformant `init` could create is rejected.

**Deferred (roadmap follow-up, not required to ship rename safely)**: a single cross-resource name
policy (packs/templates/remotes/llms still carry their own regexes) and a **defensive re-validation
at the id-consumption layer** (`_cco_project_id`) so a hand-edited or shared malformed `name:` cannot
silently corrupt the stores. Recorded as a hardening item; out of scope here to keep D bounded.

## Consequences

- **No file migration** (no tracked config file renamed/moved; no `*_FILE_POLICIES` change). The new
  verb is additive; the init/start unification only widens `init`'s accepted charset (no existing
  project breaks).
- **No `changelog.yml`** entry — pre-merge, internal to the in-development decentralized-config
  surface (consistent with dogfooding A/B/C).
- **Tests**: new `tests/test_project_rename.sh` — a 2-member project + tags + a STATE dir; assert
  every member `project.yml` `name:` updated, index membership re-keyed (`<old>` gone, `<new>`
  present with the same members), tags carried over, and `<state|cache|data>/cco/projects/<old>` →
  `<new>`; negatives: rename to an existing name / an unresolved member / an invalid `<new>` are
  rejected with no machine-local write.
- **Docs**: `docs/users/reference/cli.md` (`cco project` section) + `cco project --help` +
  top-level `usage()` gain `rename`.
- **Frozen-model intact**: identity-as-`name:` (0024 D1), projects-ride-code-repo (0018 D2), and the
  `cco project` namespace (0023) are unchanged — this ADR adds the missing identity-mutation verb and
  pins how it stays consistent across the replicated/​distributed stores.

## Alternatives considered

- **Best-effort + warn/skip on unresolved members** (the handoff's first option): rejected — a
  partial identity rewrite permanently diverges the un-rewritten members under `cco sync`'s D2 guard
  (Context #1). Strict refusal (D3) is safe and frictionless for the common single-repo case.
- **Sanitizing the name into the id** (accept any input, transform to a safe key): rejected —
  desyncs `id` from the stored `name:`, breaking the load-bearing `id == name` invariant (D5).
- **A top-level `cco rename`**: rejected — rename is a project-identity operation; it belongs in the
  `cco project` namespace next to the other identity/lifecycle verbs (no new top-level noun).
