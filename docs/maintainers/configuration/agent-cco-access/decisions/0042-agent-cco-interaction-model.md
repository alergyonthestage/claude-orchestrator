# ADR 0042 — Agent ↔ cco interaction model (three levels; retire workspace.yml)

**Status**: Accepted (2026-07-02) — design + the four open decisions (§design §9) ratified
by the maintainer; implementation in a following session. Builds on ADR-0036 (capability
knobs); **supersedes the `workspace.yml` surface of ADR-0041 R1** (the unification goal
stands; the *file* is removed).

**Deciders**: maintainer (set the three-level framing, the no-file decision, the
config-editor UX direction), implementer (analysis + code-grounding + recommendations).

**Design**: [`../design.md`](../design.md) (living doc, full detail + open questions).

## Context

cco delivered the agent's project awareness as a generated file — `packs.md`, then the
unified `workspace.yml` (ADR-0041 R1). Grounded investigation on the real tree found the
file model to be flawed:

- `<repo>/.cco/claude/workspace.yml` is **git-tracked** in real installs — a generated
  file committed as config (violates ADR-0005 F1); stale `packs.md` / `scheduled_tasks.lock`
  likewise. Legacy projects still mount stale committed `packs.md`.
- The file is mounted `:ro`, yet `init-workspace` and the file header instruct editing
  descriptions *in it* — a **silently-failing round-trip**; descriptions never persist.
- It **duplicates `project.yml`** data (resources, descriptions) with divergence/staleness
  risk, and reads like editable config while being a cache artifact.

Separately, ordinary sessions default to `cco_access=none` (no in-container `cco`), so the
agent has no on-demand channel to learn its environment beyond the injected file.

## Decision

Model **all** cco↔agent context and access through **three levels**, and **remove the
`workspace.yml` file entirely** (not in the committed tree, not in CACHE).

1. **(A) Hook context injection.** A short, always-present block injected at SessionStart /
   SubagentStart. It introduces the cco environment, lists the project's resources (repos,
   mounts, packs, llms) with optional descriptions and — when `show_host_paths` is on — the
   host↔container `path_map`, and **declares the wrapped `cco` is available** for detail.
   Computed as a **split**: in-container discovery (repos/skills/agents/MCP from the
   filesystem, as the hook already does) + host-side data (descriptions from `project.yml`,
   knowledge/llms index from `pack.yml`, `path_map` from the STATE index, access scope)
   passed via an **environment variable** in the generated compose. **No file.** Carries
   only session-fixed information (INV-1).

2. **(B) Wrapped `cco`, with read scoping.** Add **`read-project`** to `cco_access`
   (symmetry with `edit-*`): `none · read-project · read-global · read-all · edit-project ·
   edit-global · edit-all` (full symmetric read scoping). **Normal-project default moves
   from `none` to `read-project`**, giving the agent an on-demand, project-scoped read
   channel so Level A stays minimal. `cco docs` is reachable at any read level in every
   session. **In-container help is scope-aware**: host-only verbs are shown but flagged
   `(host only — run on your host)`, verbs above the current access level marked
   unavailable. Secrets/tokens remain masked/absent in every case (ADR-0036 unchanged).

3. **(C) Managed `.claude` resources.** Framework-wide, version-stable enforcement +
   awareness baked at `/etc/claude-code/.claude/` (existing: memory-policy,
   documentation-first, use-official-docs). **Add** an access-gated **config-interaction
   rule** that applies when `cco_access ≥ edit`: verify diff/status before editing config,
   atomic config commits, use `cco config save` / `cco project save`, never write secrets
   into committed files, mutate internal XDG only via wrapped `cco`, show host-only verbs
   for the user's host terminal.

**Descriptions** have one structured source — **`project.yml`** (new optional
`repos[].description` / `extra_mounts[].description`) — rendered into Level A at start (no
persisted derived copy). `CLAUDE.md` remains the rich narrative home authored by
`init-workspace`. `init-workspace` keeps CLAUDE.md authoring, drops the `workspace.yml`
write-back, and may write `project.yml` descriptions only in an `edit-project`+ session.

**config-editor UX** is redesigned use-case-first: bare `cco start config-editor` mounts the
personal store + **all** projects' `<repo>/.cco` (no repos); `--project <name>` narrows to
that project's `.cco` **and mounts its repos** (the natural, explicit home for authoring
repo-aware `project.yml` descriptions); `--repo <name>` adds a single repo. Repos in a
config session are an **explicit opt-in** (refines P18 / ADR-0036 D6, does not break it).

## Alternatives considered

- **Keep `workspace.yml`, fix pollution + round-trip (Alt 1).** Rejected as the primary
  model: still a generated file that reads like config, still needs a descriptions store,
  still duplicates `project.yml`. (Its cleanup migration is adopted regardless.)
- **Single-road wrapped-`cco`, no injection (Alt 2).** Rejected: not zero-step (the agent
  must actively query to learn its environment), and it can't surface semantic descriptions
  (not in `cco` output) — it also forces `cco` into every session unconditionally. Its good
  part — read scoping — is adopted as `read-project`.
- **Pure hook injection with no wrapped-`cco` (Alt 3).** Rejected as *sole* mechanism:
  fine for awareness but gives the agent no way to act on or drill into config. Adopted as
  Level A, paired with B.
- Chosen model is the **hybrid (Alt 4)**: A for always-present minimal awareness, B for
  on-demand read/write, C for enforcement.

## Consequences

- **Positive**: no generated file in any tree (INV-2); descriptions single-sourced in
  `project.yml` (INV-3), no round-trip/divergence; zero-step awareness that works at every
  access level; on-demand detail keeps injected context small; one coherent A/B/C model to
  extend; the `config-editor --project` session cleanly resolves description authoring.
- **Negative / trade-offs**: the wrapped-`cco` shim (container-operator mode) is present in
  **every** session once the normal default is `read-project` — more machinery per session
  than today's `none` (mitigated: read-only, project-scoped, secrets/tokens always masked).
  The normal-default change and the config-editor UX flip are **behaviour changes**,
  explicitly **confirmed by the maintainer (2026-07-02)** before build (design §9).
- **Migration**: additive schema (optional `project.yml` fields + new enum values) +
  cleanup migration (id 014) removing committed generated files + `.gitignore` scaffolding;
  retire `lib/workspace.sh`, the compose overlay, the hook `_ws_section` reader, and the
  `init-workspace` workspace.yml read; changelog #32 ("requires `cco build`").
- **Supersession**: ADR-0041's *goal* (one agent-facing surface, no `packs.md`) is kept and
  advanced (the surface is now injected context, not a file). ADR-0041 is forward-annotated
  to point here.
