# ADR 0027 — config-editor as a built-in, agentic config edit-protection, and reference mounts

**Status**: Accepted (2026-06-23)

> **Forward note (ADR-0028, 2026-06-27):** the global config home is now **`~/.cco/.claude/`** —
> read every `~/.cco/global/.claude/` below (incl. the `:ro` edit-protection mount) as `~/.cco/.claude/`.
> **Forward note ([ADR-0049](../../agent-cco-access/decisions/0049-claude-access-concordant-model.md),
> 2026-07-13, WS-B):** **P17 is reversed for the project `.claude` tree.** Under the concordant
> `claude_access` model, `<repo>/.cco/claude` (B2) now **defaults read-only** (it follows `Pc`),
> so a normal session no longer authors it by default — `/init`/`init-workspace` need an explicit
> `--claude-access repo` or a cco edit level. The "co-writable by design" default below is
> superseded; the `settings.local.json` rw child overlay dropped here (line ~131) is **re-introduced**
> as the functional-write floor (ADR-0049 §5).
**Deciders**: maintainer (set the direction + the refinements), implementer (analysis + recommendations)
**Context docs**: `../design.md` §7 (command surface, Authoring row), §9 P3 (P3-4),
`../resource-coherence-inventory.md` A.1/A.4, `../P3cd-handoff-config-editor-and-docs.md` §3
**Related ADRs**: 0008 (`~/.cco` personal store), 0010 (authoring = direct `~/.cco` edit / rehomed
config-editor agent), 0020/P17 (`<repo>/.cco` co-writable by design — **refined here on a distinct
axis**), 0024/P18 (one repo = one config home), 0012 (no `manifest.yml`), 0026 (`cco init` is the
single project entry; `cco project create` deleted)

---

## Context

P3-4 was scoped as the **mechanical rehome** of the `config-editor` template (mount `~/.cco` instead
of the dead central `user-config/`, swap `cco vault save` → `cco config save`). Code-grounding it
surfaced two design questions the handoff (§3) flagged as **maintainer-confirm**, and the maintainer's
answer opened a **third, cross-cutting** concern:

1. **How is config-editor instantiated** now that `cco project create --template config-editor` is
   deleted (ADR-0026) and `cco init` has no `--template`?
2. **How does the session edit `~/.cco` path-free** without putting a real host path in a committed
   `project.yml` (AD3/G8)?
3. **(raised by the maintainer)** In the decentralized model `<repo>/.cco/` lives **inside the user's
   code repo**, which `cco start` mounts **read-write** at `/workspace/<repo>`. So the containerized
   agent, while working on code, can now **edit its own cco config** (`/workspace/<repo>/.cco/**`,
   incl. `project.yml`/`secrets.env`) — and via the `/workspace/.claude` overlay (= `<repo>/.cco/claude`,
   mounted rw) it can edit the committed claude config too. In the **old central model** the project's
   cco config lived in `user-config/projects/<name>/`, **outside any mounted code repo**, so a project
   session could not touch it as ordinary workspace files. This is a **new exposure** to involuntary
   agent edits.

Code-grounded facts (line numbers drift — re-read):
- `cmd-start.sh:_start_generate_compose` mounts each repo `${repo_path}:/workspace/${repo_name}` **rw**;
  `.cco/` is a subdir of the repo → rw-exposed inside the container.
- The project claude overlay `${claude_src}:/workspace/.claude` is **rw**; `${project_dir}/project.yml`
  is already `:ro`.
- The **global** config is already protected in a normal session: `~/.cco/global/.claude` mounts `:ro`
  except `settings.json` (rw for runtime prefs like `/effort`). The gap is **only** `<repo>/.cco`.
- The `tutorial` is already a **built-in**: a reserved name in `RESERVED_PROJECT_NAMES`, materialized at
  runtime by `_setup_internal_tutorial` from `internal/tutorial/`, never scaffolded or committed. This
  is the precedent for question 1.

### Reconciliation with P17/ADR-0020

P17 states `<repo>/.cco/` is "co-writable with the code by design, like Claude Code's own `.claude/`".
That principle is about **human contributor write permissions** (who may push changes to `.cco/`),
delegated to git (CODEOWNERS / host rulesets). Concern 3 is a **different, orthogonal axis**: the
**in-container agent involuntarily mutating config at runtime**. A runtime guardrail here is consistent
with cco's existing **managed deny rules** (`Read(~/.ssh/*)`, `Read(~/.claude.json)`) — it is a safety
guardrail, **not** permission gatekeeping, so it does **not** contradict P17. Recorded as the
reconciliation required by the methodology.

## Decision

### D1 — config-editor is a **built-in** (the tutorial model), with two modes

`config-editor` becomes a framework-internal, **non-scaffolded** session, exactly like `tutorial`:

- **Reserved name**: add `config-editor` to `RESERVED_PROJECT_NAMES`; `cco start config-editor` launches
  the built-in (blocked only if a real project claims the name, mirroring the tutorial guard).
- **Runtime materialization**: `_setup_internal_config_editor` refreshes a runtime dir from
  `internal/config-editor/` every start (content `templates/project/config-editor/` is **moved** there).
  The host path of `~/.cco` is **injected by the launcher at start time**, never written into a
  committed file — this **sidesteps the AD3/G8 schema question (2) by construction** (same as the
  tutorial's runtime `project.yml` generation).
- **Global mode** (default, `cco start config-editor`): mount the personal store **`~/.cco` rw** (it
  carries the P1-**config**: `global/.claude/`, `packs/`, `templates/`, top-level `setup*.sh`/
  `mcp-packages.txt`). Internal buckets (DATA/STATE/CACHE: `tags.yml`, remotes, index, …) are **not**
  mounted — they are internal (P6), edited only via `cco …`.
- **Project mode** (`cco start config-editor --project <name>`, or launched from a cwd that hosts/
  belongs to a configured repo): **additionally** mount that project's **`<repo>/.cco` rw** for editing,
  resolved via the STATE index (project mode reuses the existing cwd-first / by-name resolution).

Rejected alternatives: a dedicated `cco config edit` verb (adds CLI surface; the design §8 deliberately
avoided extra verbs like `cco setup`); keeping it a scaffolded template (no `--template` on `cco init`,
and a committed `~/.cco` mount would violate AD3/G8); dropping config-editor for v1 (a UX regression —
loses the assisted authoring agent the design §7/§10 names).

### D2 — reference mounts via a repeatable `--mount` flag, **read-only by default**

`cco start [project] --mount <src>[:<target>][:ro|:rw]` (repeatable; also on `cco new`) mounts arbitrary
user reference material into the session. **Read-only is the default** (the common case for config-editor
and tutorial reference docs); `:rw` opts into writable. Target defaults to `/workspace/<basename src>`.
It reuses the existing extra-mount compose machinery (the `abs_source<TAB>target<TAB>ro` bridge).

A **persistent per-session config file** (e.g. `~/.cco/config-editor.yml` / `~/.cco/tutorial.yml` with
standing `extra_mounts:`) is a **post-v1 evolution** — recorded, not built now.

### D3 — agentic config edit-protection: narrow `:ro` guardrail on the structural framework config

In a **normal** `cco start` session (not a built-in, no escape hatch), the launcher makes the
**structural framework config read-only inside the container** — the new exposure the decentralized
model introduced (`<repo>/.cco/` now lives inside the rw-mounted code repo):

- For each repo mount whose `<repo>/.cco` exists, add a child **`:ro`** overlay
  `${repo_path}/.cco:/workspace/<name>/.cco:ro` (Docker applies child mounts after the rw parent — the
  proven `packs.md`/`workspace.yml` overlay pattern, here `:ro`-on-rw). This makes `project.yml`,
  `secrets.env`, and the internal `.cco/` metadata read-only to the agent.

The project's **Claude config tree** (`<repo>/.cco/claude` = CLAUDE.md/rules/agents/skills, surfaced at
the `/workspace/.claude` overlay) **stays read-write** — it is the project's native Claude Code config,
authored normally by `/init` and ongoing work (P17, co-authored with the code). So edit-protection
**splits** the committed `.cco/`: **structural framework config (read-only)** vs **project Claude config
(read-write)**.

This is a **filesystem** guardrail: **container-only** (the host IDE edits `~/.cco` and `<repo>/.cco`
freely — P1), **not overridable** by in-session settings, **per-session** (no managed image change, no
`cco build`). The **config-editor is the sanctioned agentic path** for editing `project.yml`/`secrets`
and the global store.

**Escape hatch**: `cco start --enable-config-edit` re-enables rw on `<repo>/.cco` for one normal session,
for a user who consciously wants to edit `project.yml`/`secrets` inline without launching config-editor.
The built-ins (config-editor, tutorial) are exempt by construction (`is_internal`).

Not applied to `cco new` (ephemeral scratch, out of the decentralized config model — ADR-0023 D5);
revisit if a need appears.

> **Decision refinement (2026-06-23, during implementation — maintainer-confirmed).** The first cut
> made the `/workspace/.claude` overlay `:ro` too (so config-editor would be the *only* agentic path for
> **any** config). Code-grounding surfaced a hard conflict: the **managed `init-workspace` skill** (the
> `/init` onboarding flow, baked into the image) **writes `/workspace/.claude/CLAUDE.md`** — a `:ro`
> overlay would break `/init` and all normal project-config authoring for every project. The hooks only
> *read* `/workspace/.claude`; `init-workspace` is the sole baked writer. The maintainer chose the
> **narrow** guardrail above (protect only the structural framework config; keep the Claude config tree
> rw), which closes the genuinely-new exposure (`project.yml`/`secrets` via the repo mount), preserves
> `/init`, and aligns with P17. The `settings.local.json` rw-escape from the first cut is therefore
> unnecessary and dropped.

## Consequences

- **Positive**: one entry model for framework-provided sessions (config-editor ≡ tutorial); AD3/G8
  satisfied by construction (no committed host path); the new involuntary-edit exposure is closed by
  default while the host IDE stays unrestricted; config-editor is the clear agentic edit path; no new
  verb; no managed/`cco build` dependency.
- **Negative / accepted**: a normal session cannot edit its own `.cco/` inline unless it passes
  `--enable-config-edit` or switches to config-editor (intended). `/workspace/.claude:ro` means
  in-container writes to the committed project claude config (and project `settings.json` runtime prefs)
  don't persist; the rw `settings.local.json` child overlay covers the local-settings case, and the
  global `settings.json` stays rw. config-editor adds a second reserved name + an `internal/` subtree to
  maintain (mitigated by mirroring the tutorial code path).
- **Self-development caveat**: all touched files are host-side (`lib/`, `internal/`, `templates/`) — live
  for a **fresh** `cco start` next session, not for the running session; testable via `./bin/test` now.

## Implementation (Phase 3, P3-4)

Four commits on `feat/vault/decentralized-config`, each leaving cco runnable + the suite delta-green
(3 P4–5 baseline failures): (1) this ADR + design §7 / inventory A.1 / roadmap; (2) D2 `--mount`;
(3) D3 guardrail + `--enable-config-edit`; (4) D1 config-editor built-in + content rehome
(`internal/config-editor/`, reserved name, `_setup_internal_config_editor`, dispatch, modes), plus the
minimal `cco project create --template config-editor` → `cco start config-editor` swap in the tutorial
references (the full `internal/tutorial/` rewrite is the P3-5 sweep, inventory A.4).
