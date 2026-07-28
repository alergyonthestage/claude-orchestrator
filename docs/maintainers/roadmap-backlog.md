# Framework Improvements — Analysis & Decisions

> Backlog of framework improvements; see [roadmap.md](roadmap.md) for the live plan.
>
> Raised: 2026-03-14. Collected from field usage observations.
> These items will be revisited individually at design/analysis time before implementation.
>
> **Convention (2026-07-16) — re-verify the bound before designing an item.** A note records the
> symptom as *observed*, plus a suggested direction; neither is a finding. Before designing, re-derive
> the item's real boundary from the code: which call sites/artifacts are actually in scope, which are
> correct-by-design and must not be "fixed", and which **related** defects sit in the same
> neighbourhood — then design and fix them as one boundary-aware change. Rationale: this is how the
> 2026-07-16 triage found that `cco repo rename` needed no change at all (FI-21), that a second
> host-path defect sat inside the very function being fixed (§ e2e `project show`), and that
> FI-21/22/23 are three faces of one index model. A per-symptom fix would have missed all three.

---

## FI-1: Framework Context for the Coding Agent

**Status**: Implemented. Operational context added to `defaults/managed/CLAUDE.md` (Docker environment, workspace layout, agent teams, memory policy).

**Question**: Should the coding agent inside the container know that it's running within claude-orchestrator? For example via managed CLAUDE.md or rules?

**Context**: Currently the managed `CLAUDE.md` (`defaults/managed/CLAUDE.md`) tells the agent *how to behave* (workspace layout, memory policy, agent teams) but does not explain what claude-orchestrator is or how the framework works.

**Analysis**:
- The agent does NOT need to know the framework internals (how `cco` works, config hierarchy, migrations) — it should use the workspace, not manage the framework.
- The agent SHOULD know key operational details: ports are mapped to host, `docker compose` creates sibling containers on `cc-<project>` network, `/etc/claude-code/` files are managed and non-modifiable, `/init-workspace` exists for project initialization, `cco` is a host-side CLI not available inside the container.
- The current managed CLAUDE.md already covers most of this. Missing: explicit mention that `cco` is host-only, Docker network naming convention.

**Decision**: Small additions to the existing managed CLAUDE.md. No separate knowledge pack or documentation needed — minimal operational context is sufficient.

**Effort**: Low (text additions to `defaults/managed/CLAUDE.md`).

---

## FI-2: `/init-workspace` on Empty Projects

**Status**: Implemented (2026-03-19). Adaptive flow added to init-workspace: detects empty workspaces and guides user through 3 detail levels (idea → decisions → specs).

**Question**: When `/init-workspace` runs on an empty, unconfigured project, the agent doesn't know what to include. Should it ask the user clarification questions (project description, architecture, goals) before generating the CLAUDE.md? Or should init-workspace be suggested only after a first analysis phase?

**Context**: The current skill (`defaults/managed/.claude/skills/init-workspace/SKILL.md`) proceeds silently with automatic discovery. It is explicitly instructed to "proceed without confirmation" if the file is empty/missing. On an empty workspace (no repos, no manifests), it generates a nearly empty CLAUDE.md with placeholder sections.

**Analysis**:
- **Option A — Ask questions first**: Before writing, the skill asks "Describe what you want to build" and uses the answer to populate Overview and Architecture. More useful for greenfield projects.
- **Option B — Suggest init after first analysis**: The user first describes their goals (via `/analyze` or conversation), then invokes `/init-workspace` which already has context from the conversation. More aligned with the phased workflow.

**Decision**: Option B is more pragmatic and coherent with the structured workflow. The skill should add a check: if no repos are found and no `workspace.yml` descriptions exist, ask the user for a brief project description before generating.

**Effort**: Low (conditional logic addition to SKILL.md).

---

## FI-3: Default Ports and Chrome DevTools Port Management

**Status**: Implemented. Template default changed to `ports: []` with example comments. Chrome DevTools port management unchanged (already correct).

**Question**: The default `project.yml` template includes `ports: ["3000:3000", "8080:8080"]`. Is this correct? Should the default be empty? How should the Chrome DevTools port be managed — automatically by the framework or manually by the user? What about port conflicts?

**Context**:
- Template: `templates/project/base/project.yml` has ports 3000 and 8080 by default.
- Browser config: `enabled: false`, `cdp_port: 9222`, `mode: host`.
- `_resolve_browser_port()` in `lib/cmd-chrome.sh` already handles port conflict auto-resolution.

**Analysis**:
- **Default ports**: 3000/8080 are reasonable web dev defaults but violate "secure by default" — an empty `ports: []` with a comment explaining how to add them is cleaner. Unused ports don't cause conflicts but add noise.
- **Chrome DevTools port**: Already managed automatically by the framework. Chrome runs on the host (`mode: host`), not in the container. The CDP port (9222) is used directly on the host and does not appear in `docker.ports`. Port conflict resolution via `_resolve_browser_port()` handles edge cases.
- **User vs DevTools conflicts**: No architectural conflict — `docker.ports` maps container ports to host, while CDP is host-to-host. The only conflict would be if a user maps port 9222 inside the container AND uses Chrome DevTools — an edge case manageable via documentation.
- **Security**: All defaults are safe. Ports map to localhost only (Docker default). Browser is `enabled: false` by default. Docker socket proxy filters API calls.

**Decision**: Change template default to `ports: []` with a comment listing common examples. Chrome DevTools port management is already correct — no changes needed.

**Effort**: Low (template edit + one-line migration if needed for existing projects — actually no migration needed since ports are user-owned and additive).

---

## FI-4: Per-Project LLM Model Configuration

**Status**: Not implemented — planned as quick win (priority 2, effort medium-low). No `model:` field in `project.yml` or `--model` integration in entrypoint yet.

**Question**: Could it be useful to set a default LLM model globally and a different default per project, per agent, or per workflow phase?

**Context**:
- Currently no mechanism exists to configure the model from the framework. The model is decided by Claude Code at launch time.
- Subagents already support per-agent model via YAML frontmatter (`model: claude-3-5-haiku` in analyst, `model: claude-3-5-sonnet` in reviewer).
- `claude --model <name>` is the CLI flag.

**Analysis**:
- **Per project** (new): Add `model:` field in `project.yml`, passed to `claude` at launch via `--model` in the entrypoint. Most concrete use case: simple projects on haiku, complex projects on opus.
- **Per agent**: Already supported natively via agent frontmatter. No changes needed.
- **Per phase**: Not practical. Phases are conceptual (user workflow), not framework-managed entities. The user can change model manually during a session.
- **Global default**: Equivalent to setting `CLAUDE_MODEL` env var or a default in settings. Lower priority — the per-project level is more useful.

**Decision**: Implement per-project `model:` in `project.yml` only. Global default is a simple env var. Per-agent is already covered. Per-phase is not worth the complexity.

**Effort**: Medium (project.yml schema, entrypoint integration, documentation).

---

## FI-5: Human Workflow Guide and Review Best Practices

**Status**: Implemented (2026-03-19). Guides written (2026-03-16), defaults aligned with guides (2026-03-19). Scope revised: branch protection docs dropped (out of cco scope — user configures via GitHub if needed). Instead, defaults aligned to guide recommendations: CLAUDE.md rewritten, workflow.md expanded, diagrams.md→documentation.md, template cleaned up.

**Question**: Should the documentation or tutorial include guidance on which tasks remain human responsibilities, the recommended development flow, common problems and workarounds?

**Original observations from field usage**:
> - Verificare sempre in dettaglio tutti gli artifact intermedi tra fasi. Il riferimento sono i documenti di analisi e design creati.
> - Dopo ogni ciclo di implementazione far fare una o più review automatiche (da uno o più agents) a Claude per:
>   - Review allineamento dell'implementazione al design e caccia di bug critici
>   - Review della docs: nessuna docs stale, tutti i riferimenti e concetti sono aggiornati al nuovo design
>   - Review dei test. Verifica che i test hanno coverage sufficiente e sono completi
> - Da eseguire sempre prima di considerare una feature chiusa e completa. Spesso la seconda review trova errori di implementazione o fix necessari che durante l'implementazione sono sfuggiti al modello.
> - Ovviamente l'umano deve sempre controllare e dirigere le scelte principali e la qualità del codice, di sicurezza, di conformità e scelte architetturali.
> - Possono essere spesso utili anche delle review e analisi di refactor possibili o ottimizzazioni dell'architettura.
> - Template project può consigliare all'utente di seguire queste fasi e direttive.
> - **Human in the loop + review automatiche migliorano drasticamente la qualità dei risultati ed evitano l'accumularsi di bug ed errori.** Ogni ciclo di sviluppo deve essere concluso con testing automatizzato + test e verifica umana.
>
> Git flow recommendations:
> - Definire un flusso git preciso e convenzioni di nomenclatura branch e direzione dei commit.
> - Includere nelle rules commit automatici dall'agent.
> - I punti di review non sono i commit, ma i merge da branch feature o fix al branch develop o main. Questo sembra essere il compromesso migliore.
> - Configurare ruleset git per PR obbligatorie per forzare la review umana e impedire merge automatici del modello — non solo tramite rules ma meccanicamente (GitHub branch protection).

**Context**: `docs/user-guides/structured-agentic-development.md` already covers team discipline, two-layer review (agent + human), and workflow phases with approval gates. Default rules in `defaults/global/.claude/rules/` cover git practices and workflow phases. The `/review` skill and `reviewer` agent exist.

**Analysis**: The conceptual framework exists, but a **practical operational guide** is missing. What's needed:
1. **`docs/user-guides/development-workflow.md`** — step-by-step guide with:
   - Checklist per phase (what to do, what to verify)
   - Recommended review pattern: implementation → design alignment review → docs review → test review
   - Common problems and workarounds (e.g., "model forgets constraints during long implementation")
   - Precise git flow: branch naming, when to commit, when to merge, mandatory PR rules
2. **Template integration** — the base project template could reference these best practices in the generated CLAUDE.md or suggest them post-`cco project create`.
3. **GitHub branch protection** — document how to configure rulesets to mechanically enforce human review on merges to develop/main, not just via soft rules.

**Decision**: Create the practical guide. The core message: human-in-the-loop + automated multi-pass reviews drastically improve output quality and prevent bug accumulation.

**Effort**: Medium (documentation writing, template updates).

---

## FI-6: Read-Only Mounts for User-Owned `.claude/` Config

**Status**: Implemented. Deny rules added to `defaults/managed/managed-settings.json` preventing agent writes to `.claude/rules/*`, `.claude/agents/*`, `.claude/skills/*` at project level.

**Question**: Currently `.claude/` rules, agents, and other user-defined files can be modified by the agent inside the container. Should these be mounted read-only to prevent unintended modifications?

**Original observation**: The agent was observed modifying user-defined rules and config files during a session. The only project that should legitimately modify these is the tutorial project (which explicitly mounts `user-config` in rw).

**Context — current mount modes**:
| Resource | Mount mode | Reason |
|---|---|---|
| Global settings, CLAUDE.md, rules, agents, skills | `:ro` | User-owned, never modified |
| Project `.claude/` | `:rw` | `/init-workspace` writes CLAUDE.md and workspace.yml |
| Pack resources (knowledge, rules, agents, skills) | `:ro` | Read-only by design (ADR-14) |
| Managed files (`/etc/claude-code/`) | Baked in image, root-owned 644 | Non-modifiable |
| `project.yml` | `:ro` | Config, not modified at runtime |

**Analysis**: The only issue is project `.claude/` being `:rw`. This is needed because `/init-workspace` writes to `.claude/CLAUDE.md` and `.claude/workspace.yml`. But it also allows the agent to modify `.claude/rules/`, `.claude/agents/`, `.claude/skills/`.

**Solutions evaluated**:
1. **Granular mounts**: Mount each subdirectory separately (CLAUDE.md `:rw`, rules/ `:ro`, etc.). More complex compose generation, harder to maintain.
2. **Deny rules in managed-settings.json**: Add deny patterns for write access to `.claude/rules/*`, `.claude/agents/*`, `.claude/skills/*` at project level. Simpler, no mount changes needed. `/init-workspace` only writes CLAUDE.md and workspace.yml, which remain writable.
3. **Soft rule only** (current): `memory-policy.md` says "Do NOT modify user-owned config files without explicit user approval" — but this is not enforced technically.

**Decision**: Option 2 (deny rules in managed-settings.json) is the most elegant. Technical enforcement without mount complexity. Tutorial project can override if needed via its own settings.

**Effort**: Low (deny rule additions to `managed-settings.json`).

---

## FI-7: Publish-Install Sync and Resource Versioning

**Status**: Implemented (2026-03-17) — **but later superseded** by the decentralized-config
refactor. Projects no longer publish/install/update/internalize: a project rides its own
code-repo remote (ADR-0018 D2), and `cco project publish|install|update|internalize` were
removed (`bin/cco` now returns a removal notice). **Needs triage**: confirm which sub-decisions
survive under the new model (e.g. the 3-way merge path lives on in `cco update`; `cco project
internalize` / Case-C is reserved post-v1, ADR-0023 D4). The original FI-7 design doc
([link](../archive/sharing/publish-install-sync-design.md)) appears to have
been removed/archived in a docs reorg (dead link — needs triage alongside the doc review).

**Question**: After `cco project install`, the installed project has no connection to the source Config Repo. If the publisher pushes updates, how does the consumer know? Should there be a `cco project update` flow? What about versioning?

**Analysis & Design**: Full analysis and design completed 2026-03-17. Key decisions:

1. **Unified discovery** — `cco update` becomes the single "what's new?" command covering framework changes, remote publisher updates, and changelog. Actions are type-specific.

2. **Source-aware sync** — `cco update --sync` on installed projects skips opinionated files (managed by publisher chain: Framework → Publisher → Consumer). `--local` flag overrides this for inactive publishers.

3. **3-way merge for project updates** — `cco project update <name>` fetches remote, merges via `_collect_file_changes()` / `_interactive_sync()`. Consumer customizations preserved.

4. **Publish safety** — migration check (blocking), secret scan (blocking), framework alignment (warning), diff review, per-file confirmation, `.cco/publish-ignore`.

5. **Project internalize** — `cco project internalize <name>` disconnects from remote permanently.

6. **Version metadata** — optional `version:` field in `.cco/source` for human-readable labels; `commit:` field for precise comparison via `git ls-remote`.

**Docs**: [analysis](../archive/sharing/publish-install-sync-analysis.md) | [design](../archive/sharing/publish-install-sync-design.md) | [user guide](../users/configuration/guides/configuration-management.md)

**Effort**: Medium-High (6 implementation phases defined in design doc).

## FI-8: PromptSubmit Hook + Documentation-First Rule

**Status**: Implemented. See [defaults-alignment-design.md](configuration/rules-and-guidelines/design/design-defaults-alignment.md) §2.2, §2.3.

**Problem**: Rules loaded at session start lose effective weight as conversation grows or after compaction. The agent frequently forgets key behavioral rules — particularly git practices and commit discipline.

**Solution**:

1. **UserPromptSubmit hook** (`config/hooks/prompt-submit.sh`) — managed hook injecting a concise per-prompt reminder. Follows the Content Principle: reminds the agent to check its configured rules rather than hardcoding specific rule content. Works regardless of how the user has customized their rules.

2. **Documentation-first rule** (`defaults/managed/.claude/rules/documentation-first.md`) — managed rule requiring the agent to check existing docs, design documents, ADRs, and prior analysis before starting new work. Prevents proposing solutions that contradict or duplicate existing design decisions.

3. **Defaults review** (8c-8e) — global rules, global CLAUDE.md, and managed CLAUDE.md reviewed against user guides. No changes needed — FI-5 alignment was already complete.

**Design principle**: The hook and rule are managed (framework behavior), not opinionated defaults. They govern *how to use existing artifacts*, not *which artifacts to create*. The hook references user-configured rules rather than encoding specific conventions.

**Effort**: Low.

---

## FI-9: Migration UX gaps surfaced by the v0.4.0 release

**Status**: Open (raised 2026-06-30 during the npm-packaging analysis). To be addressed in the
`cco update` responsibility refactor — see
[`engineering/opinionated-extraction-and-update-refactor-handoff.md`](engineering/opinionated-extraction-and-update-refactor-handoff.md) §6.

**Context**: Running cco after the v0.4.0 decentralized-config migration exposed three UX gaps in the
migration / update flow.

**Items**:
1. **No rebuild reminder after migration.** When `cco <cmd>` triggers the preventive vault backup and
   advises `cco update` + `cco init --migrate`, nothing tells the user that a **fresh `cco build`
   (`--no-cache`?) is required before `cco start`** — a new release needs a new image, but this is
   surfaced nowhere. Add the hint; evaluate whether the migration should auto-trigger the rebuild.
2. **`cco update` as first command — backup symmetry.** Clarify whether `cco update` run as the very
   first command performs the **preventive backup of the old centralized vault** like every other cco
   command (it should, symmetrically), or intentionally skips it.
3. **Re-build coupling.** Decide whether the decentralized-config migration **triggers the rebuild**
   itself, or stays separate with an explicit user hint.

**Analysis**: All three point toward the future **`cco update` orchestrator** (detect install method →
run engine update + migrations, one command). Keep them together with that refactor.

**Effort**: Low–Medium (hints now; full orchestration with the update refactor).

## FI-10: Is managed `permissions.deny` enforced under `--dangerously-skip-permissions`?

**Status**: Open (raised 2026-06-30 during the `settings.json` decomposition for npm packaging —
ADR-0037 D10). Security investigation; does **not** block packaging.

**Context**: cco always launches `claude --dangerously-skip-permissions` (`config/entrypoint.sh:261,267`),
which bypasses the permission-prompt gate. The framework relies on managed `permissions.deny`
(`defaults/managed/managed-settings.json` — `Read(~/.ssh/*)`, `Read(~/.claude.json)`) as a security
backstop. Official Claude Code docs list `allowManagedPermissionRulesOnly` and
`permissions.disableBypassPermissionsMode` as the controls that make *only* managed rules apply and
disable bypass mode — and **cco sets neither**.

**Question**: Under bypassPermissions, are managed `deny` rules still enforced, or are they decorative?
- If enforced → no action; document the guarantee.
- If not → either add `allowManagedPermissionRulesOnly` / `disableBypassPermissionsMode` (but that would
  re-enable prompting, conflicting with the zero-friction model), **or** accept that **Docker-is-the-sandbox**
  is the real boundary and downgrade the `deny` to informational (the container already isolates host
  secrets; `~/.ssh` is not mounted).

**Verify**: read the official permissions/bypass docs precisely, then test in a live container
(attempt a denied `Read` under skip-permissions).

**Effort**: Low (investigation + doc/test); fix scope depends on the finding.

## FI-11: Top-level `cco --version` / `-v` (and `--help` / `-h`)

**Status**: ✅ Done (2026-06-30). Implemented exactly as scoped below: `--version`/`-v`
prints `package.json` `version` (`_cco_print_version` in `bin/cco`), `--help`/`-h` aliases
`usage()`, both handled before the dispatch and the J0 bootstrap (no side effects).
Tests in `tests/test_version.sh`; changelog #27. Ships in the next release (`0.5.2`).

**Context**: now that `cco` ships as an npm CLI, users expect `cco --version` to print the version
and `cco --help`/`-h` to show usage — both are near-universal CLI conventions. The dispatcher
(`bin/cco`) currently has **neither**: bare `cco` and `cco help` print usage (`usage()`, dispatch
line ~282), and `cco <command> --help`/`-h` work per-subcommand, but a top-level `--version`/`-v` or
`--help`/`-h` falls through to the `*)` arm → `die "Unknown command: …"` (line ~283). Surfaced when
`cco --version` errored during the post-release smoke test (the version had to be read from
`npm ls -g` instead).

**Proposed scope**:
- `cco --version` / `-v` → print the version. Source of truth = `package.json` `version` (read with
  the already-required `jq` from the resolved package root). Keeps the single source of truth
  (ADR-0037 D7) — no hardcoded string to drift.
- `cco --help` / `-h` (top-level, no subcommand) → call `usage()` (alias of `cco help`).
- Handle these **before** the command dispatch so they work with no other args.

**Type & tracking**: additive user-visible feature → `changelog.yml` entry; add a small dispatch test
(`cco --version` matches `package.json`, `cco --help` prints usage). No migration, no template change.

**Effort**: Low.

## FI-12: Retire `cco stop` — stop belongs to session exit

**Status**: 📝 Note — to analyze (surfaced 2026-07-14 during the resource-naming work).

**Context**: `cco stop [project]` is effectively unused. A session already terminates the
normal way: the user runs `/exit` in Claude and, once the last tmux pane exits, the `cco`
process (the `docker compose run --rm` foreground) ends and the container is removed. Nobody
runs `cco stop`. Worse, its detection is unreliable: with a session actually running, an
external `cco stop <project>` reports `No running session for '<project>'` and the project
keeps running — the lookup does not find the live session (likely because identity is the
compose `cco.project` label on a `run --rm`-discarded container, not a container name — see
the session-identity note in the access-model work).

**Direction to evaluate**: remove `cco stop` and assign stop responsibility entirely to the
`/exit` + tmux-exit path (which is already what happens). Before removing, verify no
teardown step (network `cc-<project>`, generated compose/overlay cleanup, running-registry
marker per ADR-0045) depends on `cco stop` being called — if so, re-home that teardown onto
the entrypoint/exit path or the `cco start` reconcile backstop. If a detection fix is cheaper
than removal, at minimum make the running-session lookup label-based so it stops matching by
container name.

**Type & tracking**: verb removal → breaking CLI surface change (deprecation + changelog);
possibly a migration only if teardown responsibilities move. **Effort**: Low–Med.

## FI-13: `cco deinit` — explicit, symmetric de-initialization

**Status**: 📝 Note — to analyze (surfaced 2026-07-14).

**Context**: there is no verb that is the clean inverse of `cco init` with an explicit
"de-initialize this project" intent. `cco forget` already performs the underlying action
(remove internal references to a project; `--purge` also removes `<repo>/.cco`), but its
intent/scope differs: `forget` is **not cwd-based** (takes a project name), and without
`--purge` it leaves `<repo>/.cco` in place. So the operation exists but the UX/verb for
"undo my init here" is missing — asymmetric with `init`.

**Direction to evaluate**: a `cco deinit` (cwd-based) that resolves the current repo's
project and wraps `forget --purge` (with the standard preview + confirm), giving init a clear
symmetric counterpart. Decide whether `deinit` should be a thin alias/wrapper or whether
`forget` itself grows a cwd-first form; keep one canonical implementation. Relates to the
resource-naming/lifecycle consistency theme.

**Type & tracking**: additive verb (or `forget` cwd-first form) → changelog; no schema
change. **Effort**: Low.

## FI-14: Unified credential/secret vault for agent access

**Status**: 📝 Note — major future feature, to analyze (surfaced 2026-07-14).

**Context**: today secrets reach a session only via the per-repo `secrets.env` (host-edited,
masked from every config mount) and `GITHUB_TOKEN`/`gh` for git+GitHub. There is no unified,
explicit management of credentials, keys, or passwords that agents (or cco-integrated tools)
may need — e.g. gh tokens, repo-access keys, or logins for portals/sites an agent drives in a
browser.

**Direction to evaluate**: a dedicated, access-controlled vault that unifies management of
secrets of various kinds for agent/tool use, integrated with the existing access model
(`cco_access`/`claude_access`, the setuid privilege boundary of ADR-0047, and the secret-file
masking already in place). Most important near-term use: repo + `gh` access. Design guidance
to capture: recommend **dedicated per-agent accounts** for external platforms so audit trails
stay faithful and permissions stay granular per access/operation. Cross-reference the archived
`docs/archive/vault/` design material (the old centralized-vault direction) for prior art —
this is a different, agent-credential-oriented scope, not that vault.

**Type & tracking**: large, multi-ADR feature; security-sensitive → requires its own analysis
+ design tree before any code. **Effort**: High.

## FI-15: Resource locking for concurrent sessions sharing a repo

**Status**: 📝 Note — to analyze (surfaced 2026-07-14). **Related**: Sprint 10 — Git worktree
isolation (#6) in `roadmap.md`.

**Context**: two different projects that reference the **same** repo (the supported
one-repo-multiple-projects model) can both be launched with `cco start` — the operation is
permitted with no guard. Their agents then potentially write the same files in the same host
repo/mount, risking concurrent-edit conflicts and corruption, with nothing protecting them.
The planned worktree isolation (Sprint 10) is the mechanism that would let multiple sessions
safely share a repo (each on its own `cco/<project>` worktree/branch), but until it lands the
shared-repo case is unprotected.

**Direction to evaluate**: a resource-locking mechanism over the host directories/repos/mounts
a started project holds — e.g. an advisory lock (tied to the ADR-0045 running-registry) that,
on `cco start`, detects another live session already holding an overlapping repo/mount and
either refuses, warns, or requires worktree isolation. Frame worktrees (Sprint 10) as the
**enabler** for safe concurrent sharing and the lock as the **guard** for the un-isolated case.
Needs proper analysis, evaluation, and design — captured here as a note to keep in mind.

**Type & tracking**: safety/correctness feature; couples with Sprint 10 → design together.
**Effort**: Med–High.

## FI-16: Fail-loud state guards for mixed cco versions

**Status**: ✅ Done (2026-07-23, [ADR-0052](configuration/decentralized-config/decisions/0052-index-integrity-version-gate-and-reconcile.md) — index-integrity cluster). A single host-only
version gate in `_cco_first_run` (`_cco_version_gate`, `lib/migrate.sh`) now `die`s on ANY command
when the on-disk index (`version:`) or global `.cco/meta` (`schema_version`) is newer than this
binary supports — the max index version is the declared `CCO_INDEX_VERSION` constant, the schema
bound is the self-maintaining `_latest_schema_version global`. The gate never trusts a version it
could not cleanly read (probes by opening, dies honestly on unreadable/truncated/malformed). The
`_cco_in_container` `==0` gap is closed. Tests: `tests/test_version_gate.sh`; changelog #48; the
developer sandbox (ADR-0052 §7, `--dev-sandbox`) is the dev-side mitigation that makes the hard
`die` costless. The three new defects the 2026-07-22 e2e incident surfaced are resolved with it:
**N1** (migration 017's "new-wins `rm -f`" data loss) and **N2** (the hot path never reconciled the
legacy index location) → the non-destructive merge reconcile + residue absorption of ADR-0052 §2/§3
(`_index_reconcile_legacy_location`, called from both `_cco_first_run` and 017); **N3** (`q`/Exit did
not abort `cco start`) → rc=2 now propagates through `_resolve_unit` (ADR-0052 §6). Broad
structural validation of the OTHER unversioned readers (tags, remotes) stays open under
[FI-22](#fi-22-internal-state-validation-doctor-and-repair).

**Status history**: 📝 Note — to analyze (surfaced 2026-07-15 while fixing the ADR-0049 §5 start bug).

**Context**: two cco installs on one machine share a single config store, and a newer one can
leave state an older one silently misreads. Observed: `./bin/cco` (dev, ADR-0051) upgraded the
machine-local index to `version: 2` on its first write; the npm-released `0.5.2` — which predates
per-project scoping and looks for the flat `paths:` section — then found no bindings and prompted
to re-clone a repo that was present all along. The index migration itself is sound (`lib/index.sh`
reads v1 as global-flat and upgrades on the first host write); the defect is that the **downgrade
degrades illegibly**, into a misleading prompt rather than a clear refusal.

The maintainer's framing (2026-07-15): the breaking changes were deliberate and correct (pre-1.0,
~2 users, unified config + access model wanted fast) — the lesson is not "break less" but
**fail loud at the boundaries where one version reads another's state**. Fixing the `0.5.2` symptom
is not worth it: that code is published and the edge case dies at release. Fix the root.

**Second sighting (2026-07-16)** — the same incident recurred on the host and widened the symptom
set, confirming the note is worth acting on. Running the **npm-released `cco`** against a
dev-written store: `cco path list` reported *"the path index is empty"* (v1 reader, flat `paths:`,
against a v2 `project_paths:` index), and `cco resolve` then offered to re-clone a repo that was
present all along. Worse than the misread: `cco resolve` / `cco path set` are **index writers** — an
old binary that misreads v2 as "empty" can write **v1-format records back into a v2 file**, mixing
formats in place (the corruption feared in [FI-22](#fi-22-internal-state-validation-doctor-and-repair)).
The maintainer's framing stands: fix the root, not the published `0.5.2` symptom.

**Direction to evaluate** (a **global, schema-driven gate** — explicitly NOT a per-command guard;
the stated requirement is that no command can be "forgotten"):
- **The choke point already exists.** `_cco_first_run "$cmd"` (`bin/cco:521`) runs **before every
  dispatch**, host-side only, idempotent — the natural home for one gate covering the whole surface.
- **The max supported version is already derivable.** `_latest_schema_version <scope>`
  (`lib/update-meta.sh`) computes the max by scanning the binary's **own `migrations/<scope>/`**.
  A gate written as `on-disk > latest → die` therefore **self-maintains**: adding a migration bumps
  the bound automatically, with no constant to remember to update. (Verify at design: `migrations/`
  covers `global`/`project`; the **index** version is a separate hardcoded `2` in
  `_index_ensure_file` — it needs its own declared bound, and it is the artifact that actually broke.)
- **The gap is one-directional.** Only `current < latest` exists today (`lib/cmd-start.sh:858`,
  "Updates available. Run 'cco update'"). The reverse — disk **newer** than the binary — has no
  check anywhere, so the old binary proceeds silently. That asymmetry is the whole defect.
- **Which artifacts need a bound**: today only `.cco/meta` (`schema_version`) and the index
  (`version:`) carry one at all. Tags/remotes/running-registry/source records are **unversioned**
  (see FI-22) — decide at design whether the gate needs them stamped, or whether refusing on the
  two versioned artifacts is sufficient to stop the session before anything else is written.
- **CLI↔image version handshake** at `cco start` — the host cco and the image's `/opt/cco` can
  diverge (exactly the 2026-07-15 case: npm cco + dev-built image), today with no signal.
- **Dev-side mitigation** (no code, available today): keep the npm cco off `PATH` while developing
  (`npm link`/alias) so the mixed-version state cannot arise in the first place.
- Note `_cco_in_container` has a related gap: the `CCO_IN_CONTAINER` override honours `==1` but
  never `==0`, so there is no escape hatch to force host semantics.

**Re-verify the bound before design** (per the 2026-07-16 triage convention): confirm the write-side
inventory — *every* index/store writer reachable from an old binary, not just `resolve`/`path set` —
and check whether the gate belongs **before** `_cco_first_run`'s own bootstrap/self-heal steps
(`_cco_flatten_global_claude` etc. already mutate state at that point, so a gate placed after them
would fire too late). Decide read-only verbs' fate too: a hard `die` on `cco list` may be worse than
a warn, but a `die` on any writer is the point of the exercise.

**Type & tracking**: additive guards → changelog; no schema change. **Effort**: Low.
**Priority**: high among the FI notes — it is the root cause that makes FI-22's corruption class
possible, and it is cheap. Not gating the access/CLI e2e review (that runs a single binary — the one
baked into the image — so the mixed-version scenario cannot arise there).

## FI-17: config-editor should mount the target project's repos read-only

**Status**: 📝 Note — to analyze (raised by the maintainer 2026-07-15).

**Context**: `cco start config-editor` mounts config only. But editing a project's rules/config
well needs the project's **context**: its repos and extra_mounts, read-only. The precedent is the
personal store — `~/.cco` is mounted `ro` precisely so decisions are informed rather than blind;
the same argument applies to the repos the rules govern. Today the config-editor edits rules for
code it cannot see.

**Direction to evaluate**: in config-editor **project mode** (cwd-in-project or `--project <name>`),
mount the target's repos/extra_mounts `:ro` by default. Touches ADR-0044 §3 (min-privilege by mode)
and the ADR-0048 WS-A refinement — the `--repo <name>` flag already adds one repo, so decide whether
this becomes the default or stays opt-in, and whether extra_mounts follow. Weigh against the
min-privilege default the preset is built on.

**Type & tracking**: default-behaviour change in a built-in preset → changelog; ADR-0044 annotation.
**Effort**: Low–Med.

## FI-18: Decouple CLAUDE.md from rules/agents/skills in claude_access

**Status**: 📝 Note — to analyze (raised by the maintainer 2026-07-15; explicitly post-e2e).

**Context**: Axis B (`claude_access`, ADR-0049) governs each `.claude` **tree** as a unit: CLAUDE.md,
`rules/`, `agents/`, and `skills/` share one `ro`/`rw` decision per tree. A finer split may be
wanted: let a session author **CLAUDE.md** (project narrative/context, routinely updated as work
progresses) while `rules/`, `agents/`, and `skills/` stay read-only (governance the agent should not
rewrite for itself). Today the two intents can only be had together.

**Direction to evaluate**: whether the axis granularity should grow a per-resource dimension, or
whether a `settings.local.json`-style **functional-write floor** (ADR-0049 §5) is the better shape —
i.e. a narrow always-writable carve-out rather than a new axis. Consider the cost: Axis B is already
a 4-tuple `(Cr,Cp,Cg,Co)`, and multiplying it by resource class risks an unusable surface. Weigh
against P2 discordance and the concordant-default model before committing.

**Type & tracking**: access-model extension → ADR + changelog. **Effort**: Med.

## FI-19: Host-only suite tests should skip, not fail, under the privilege boundary

**Status**: 📝 Note — to analyze (surfaced 2026-07-15 while fixing the ADR-0049 §5 start bug).

**Context**: the suite reports a permanent **7 failures when run inside a cco session** — 6 in
`tests/test_access_scope.sh` (`test_as_*`) and `test_paths_symlink_safe_tool_root`. They are **not a
code defect**: the ADR-0047 privilege boundary is live in-session (`cco-svc-helper` setuid 4750,
`~/.cache/cco` unreadable to the agent), and the 6 `test_as_*` tests explicitly set
`CCO_CONTAINER_OPERATOR=1`, so `cco list` re-enters via the setuid helper — which by design ignores
env (`CCO_STATE_HOME` & co.) and reads the real internal store. The tests' redirected fixture store is
therefore invisible and the real environment shows up instead. `test_paths` fails on `mkdir ~/.cache/cco`
→ Permission denied, same boundary. Ironically these tests accidentally prove the boundary cannot be
bypassed by environment. On the host they are expected to pass (1308/0 — worth confirming once).

**Why it matters**: a standing 7-failure baseline trains everyone to read failures as noise. That is
the same habit that let the ADR-0049 §5 start bug ship green.

**Direction to evaluate**: detect the boundary (`-u /usr/local/bin/cco-svc-helper`, or `~/.cache/cco`
unreadable) and **skip with a reason** instead of failing. The harness has no `skip_test()` helper
today — add one, keeping the suite hermetic (it mocks docker throughout; no daemon dependency).
Refuted while diagnosing, do not retry: a `CCO_IN_CONTAINER=0` escape hatch, and unsetting the
inherited session env — neither fixes any of the 7.

**Type & tracking**: test-harness change only; no user-facing surface. **Effort**: Low.

## FI-20: git operations vs the `:ro` `.cco` overlay — partial checkout footgun

**Status**: 📝 Note — to analyze (hit live 2026-07-15 while merging the start-bug fix in-session).

**Context**: the Axis-A1 edit-protection overlay mounts `<repo>/.cco` `:ro` at `read-project`. Git
is not exempt: **any branch operation whose diff touches `.cco` fails**, because git must write the
worktree file and hits `EROFS`. This is **correct by design** — if git could write `.cco`, an agent
could bypass the structural-config boundary by committing and checking out — but it has consequences
nobody has written down:

- A branch carrying a committed `.cco` change (e.g. a migration's own output, as migration 015
  produced here) **cannot be merged or checked out from a normal session**.
- Worse, git applies checkouts **partially**: `git checkout develop` switched branches and updated
  every other file, failing only on `.cco/.gitignore`. The result was a worktree silently sitting on
  the wrong branch **without the fix that had just been made** — a subsequent `cco start` would have
  reintroduced the very bug being fixed. The `Aborting` message came from the follow-on merge, not
  the checkout, so the failure read as "nothing happened" when in fact the tree had moved.
- Recovery is non-obvious: `git checkout <branch>` refuses (local changes), `git stash`/`git checkout
  -- <path>` also need to write `.cco`. What works: `git add .cco/<file>` to align the index with the
  (already-correct) worktree content, so the next checkout needs no write.

**Direction to evaluate**: decide the intended contract and make it legible rather than emergent.
Options, not exclusive — (a) detect the condition at `cco start`/in the shim and **warn** that git
branch ops touching `.cco` will fail at this access level; (b) document the pattern (commit `.cco`
changes host-side, or use `--cco-access edit-project`) in the access docs; (c) consider whether the
overlay should be relaxed for git's own writes — **probably not**, it would reopen the bypass. Note
the interaction is generic: it applies to `secrets.env` and any other `:ro`-masked path too.

**Type & tracking**: UX/safety of the access model; docs + possibly a start-time warning. No schema
change. **Effort**: Low.

## FI-21: Explicit project scope on the host-path surface (post-ADR-0051 completeness)

**Status**: 📝 Note — to analyze (surfaced 2026-07-16, maintainer host session, while renaming a repo;
scope refined by the maintainer the same day — see the principle below).

**Context**: ADR-0051 made repo/extra_mount names **per-project labels for a path** — the same name
may legitimately name *different resources* in different projects. The index primitives and the
rename verbs implement that model correctly, but **the CLI surface around them was never audited for
the ambiguity the model introduces**. The maintainer's question — *"if I rename a `<repo-name>` that
differs across projects, which one moves? if `cco path set` gets a name that exists in several
projects, which path changes?"* — gets three different answers today, and the surface as a whole was
never given a deliberate scope UX:

- **`cco repo|extra-mount rename` — semantics correct; scope UX incomplete.** `lib/cmd-repo.sh` is
  deliberately project-scoped and path-anchored, and the *default* (cwd project) is right: another
  project's same-named-but-different-path binding **is a different resource**, so cross-project
  fan-out must never be the default (D1). It also names the project it acted on. **But "the default
  is correct" is not "the verb is complete"**: there is no way to target another project without
  `cd`-ing into it (`--project <name>`), and no way to re-label a path **everywhere it is
  referenced** (`--all-projects`). Note the latter is *not* in tension with D1 — re-labelling one
  PATH across the projects that reference it is path-anchored by definition, which is exactly what
  D1 makes identity. (An earlier triage pass recorded this as "correct, no action, question closed";
  that was **wrong** — it answered the semantics question and mistook it for the UX one.)
- **`cco path set <name> <path>` — same shape.** Binds in the project hosting the **cwd**; outside any
  project it writes the `unscoped:` bucket. The default is sound and the choice is deterministic
  **and printed** (`path set: [<proj>] <name> -> <abs>`), and the verb is the documented low-level
  escape hatch — but again there is no `--project` to aim it elsewhere.
- **Silent first-match resolution — the outright defect.** `_index_get_path_any <name>` returns the
  **first** binding across all projects with no disambiguation and no notice. `lib/index.sh:533`
  documents 3 such call sites; there are **5**: `cco sync --from` (`cmd-sync.sh:178`), `cco sync
  <target>` (`cmd-sync.sh:200`), `resolve --scan` pass 2 (`cmd-resolve.sh:566`), `cco start --from`
  (`cmd-start.sh:720`), config-editor `--repo` (`cmd-start.sh:613`). With homonyms (`backend`, `web`,
  `assets`) these act on **whichever project is indexed first** — a wrong-target write for `sync`.
  The doc under-counts its own ambiguity sites, which is itself a signal the surface was not swept.

**Proposed guiding principle (maintainer, 2026-07-16 — to ratify at design, NOT yet normative)**.
It governs **read and write alike**, and its point is *deliberate, complete* scope UX rather than
scope-by-accident:

> Every `cco` command that handles the host path of a **per-project-scoped resource** (repo,
> extra_mount) MUST make its project scope **explicit and complete**:
> 1. **Default to the cwd project** — the established cco convention, and the right default.
> 2. **Never be limited to it.** Where another scope is meaningful, offer it explicitly:
>    `--project <name>` to aim at another project, `--all-projects` where acting on every binding of
>    a path is coherent. cwd is a *convenience default*, never a ceiling (the same resolution D-CE1
>    reached for config-editor).
> 3. **Declare the scope, or show everything.** A per-project-scoped output must *say* it is scoped
>    (as `cco path list` does with its `[project]` prefix). A lookup that is generic must return
>    **all** matching bindings — **never the first occurrence while silently hiding the others**.
>    "Scoped" and "generic" are both fine; *undeclared* is not.
> 4. **Filter, don't force.** Give the user a scope filter (e.g. `cco path list --project <name>`)
>    rather than making them read a mixed view — the current list is legible only because it is short.
>
> Rationale: the same UX applies whether the command reads or writes, so the user learns **one** rule
> for the whole surface. Point 3 is the one that turns a UX preference into a correctness rule — it is
> what makes `_index_get_path_any`'s silent first-match a bug rather than a shortcut.

**Suggested direction (verify at design)**: extend the **existing** ADR-0051 D4 machinery
(`_index_bindings_for_name`, `_resolve_reuse_menu`, `_resolve_disambiguate`, + the git-origin/url
divergence signal) from the add-time surface to the read/edit/consume surface, rather than inventing a
second mechanism. Interactive prompts need a non-interactive twin (`sync`/`start` must stay
scriptable, and cco's own convention is "widen via explicit flags, not prompts" — D-CE1), which is why
the flags in point 2 and the prompt are the *same* decision seen from two contexts. Naming to settle
at design: `--all-projects` vs a `--project` that repeats; and whether path listing becomes a `cco
list` kind (`cco list path --project …`, the maintainer's phrasing) or stays `cco path list
--project …`.

**Re-verify the bound before design**: re-derive the call-site list from the code (do not trust the 5
above, nor the stale `index.sh:533` header — that under-count *is* the failure mode). Then classify
every site on **two** axes, not one: (a) *genuinely cross-project* (config-editor `--repo` is
intentionally so) vs *ambiguous by omission*; and (b) **read vs write** — a wrong-target *read*
degrades, a wrong-target *write* (`sync`) corrupts, so they may deserve different answers (prompt /
flag / fail-loud refusal). Sweep the **whole** kind, not just the verbs named here: any verb taking a
repo/extra_mount name is in scope. Check `_index_get_path`'s `unscoped:` fallback in the same pass —
see [FI-23](#fi-23-extra_mount-legacy-bindings-land-in-the-unscoped-bucket-adr-0051-migration-residue),
which is the same model leaking from the other end, and would otherwise re-introduce a cross-project
default underneath any flag added here.

**Type & tracking**: UX + correctness on the naming surface → changelog; no schema change expected
(flags + lookups only). If ratified, the principle belongs in a **living design doc**, not only in
this note — the natural home is the naming design tree, cross-referenced from
[design-cli-environment-awareness](cli/design/design-cli-environment-awareness.md) (which owns the
*other* host-path axis: host-vs-container, §4c). Keep the two axes distinct — *which project does this
path belong to* and *does this path exist in this environment* are different questions that happen to
share the word "path". **Effort**: Med.
**Not gating the access/CLI e2e review** — the e2e handoff §9 explicitly defers "broader naming
semantics (per-project scoping ADR-0051, disambiguation prompts)" to a separate naming track. This
note **is** that track.

## FI-22: Internal-state validation, doctor and repair

**Status**: 🟡 Partially done (2026-07-23, [ADR-0052 §5](configuration/decentralized-config/decisions/0052-index-integrity-version-gate-and-reconcile.md) — index-integrity cluster). The
**index-focused doctor** landed: `cco config validate` now collects malformed/unparseable index
records into a separate `_CV_MALFORMED` set, reports them under their own heading with remediation
advice, and NEVER auto-prunes them (the user decides format repair); only genuine orphans are pruned,
keeping the ADR-0021 two-phase sync-class confirm. This generalises the `cco path list` flag-on-read
precedent to `config validate`. Tests: `tests/test_config_validate.sh`; changelog #48. **Still open
(this note stays):** broad structural/format validation of the OTHER unversioned lenient readers —
the **tags** and **remotes** registries — is explicitly out of scope for the index-integrity cluster
(ADR-0052 §5) and remains to analyze here. The root-cause misread that made corruption look like
"empty" is closed upstream by [FI-16](#fi-16-fail-loud-state-guards-for-mixed-cco-versions).

**Status history**: 📝 Note — to analyze (surfaced 2026-07-16, maintainer question following the FI-16 incident).

**Context**: if an internal file is written by a wrong/older cco or hand-edited, records can end up
malformed or **mixed-format** (e.g. an un-scoped v1 repo path inside a v2 per-project index). The
question was whether cco has validation / warning / doctor / sanitisation for this, or whether it is
left to "conventions" that each writer must follow. Conventions are the wrong answer for exactly the
FI-16 reason: they are what gets forgotten.

**What already exists** (so this is an *extension*, not a new subsystem):
- **`cco config validate [--fix]`** (`lib/cmd-config.sh:300`) already has the right shape:
  orphan-sanitisation, **detect-only by default**, `--fix` preview-first + confirmed, never
  automatic. Its prune aggressiveness is already calibrated by bucket sync-class (ADR-0021 Dec.5):
  STATE/CACHE are machine-local + rebuildable via `cco resolve --scan`; **DATA is synced, so a wrong
  prune propagates across machines** and needs a second explicit confirmation. That reasoning is the
  hard part and it is already settled — reuse it, do not re-litigate it.
- Self-heal precedents: the ADR-0045 running-registry reconcile backstop (silent prune of stale
  markers at `cco start`) and the transparent index v1→v2 migration (ADR-0051 D6).
- Per-resource validators exist for **user-facing** config: `cco project|pack|template validate`.

**The actual gap**: the **internal** artifacts have no integrity story. Readers are uniformly
*lenient* — `lib/index.sh` (awk section extraction, `_peel_tab`), `lib/tags.sh` (`_tags_get` bracket
regex), `lib/cmd-remote.sh` (`IFS='=' read`) all **skip or silently misparse** a malformed record
rather than flag it, so corruption reads as "empty" (precisely the FI-16 symptom). And only
`.cco/meta` + the index carry a version at all: **tags, remotes, tokens, running markers and source
records are unversioned**, so nothing can even detect that they were written by another generation.

**Direction to evaluate**:
- **Fix the source first.** Much of this class is closed upstream by the [FI-16](#fi-16-fail-loud-state-guards-for-mixed-cco-versions)
  gate — refusing the old binary prevents the corruption instead of detecting it afterwards.
  Sequence FI-16 **before** this note and re-scope what is left.
- **Extend `cco config validate`** with structural/format checks (does each record parse? is any
  record in a foreign format? is the file's version within the supported bound?) rather than adding a
  `cco doctor` verb — a second entry point for the same job would split the surface. Whether a
  `doctor` **alias** is warranted is a naming question, decidable later.
- **Decide the read-time contract**: strict-fail vs warn-once vs lenient-skip on a malformed record.
  Today's silent-skip is the reason a corrupt index looks empty; at minimum a malformed record should
  be *visible*. Note `cco path list` already flags malformed (non-absolute) entries — a local
  precedent to generalise from.

**Re-verify the bound before design**: inventory each internal artifact as **regenerable**
(index → `resolve --scan`; llms → re-download) vs **irreplaceable** (tags, tokens) — repair strategy
follows from that split, and the ADR-0021 sync-class reasoning already encodes half of it. Confirm
what FI-16 leaves unfixed before sizing.

**Type & tracking**: extends an existing verb → changelog; possibly version stamps on unversioned
artifacts (schema-touching → migration). **Effort**: Med (Low if FI-16 lands first).
**Not gating** the e2e review.

## FI-23: extra_mount legacy bindings land in the `unscoped:` bucket (ADR-0051 migration residue)

**Status**: ✅ Done (2026-07-23, [ADR-0052 §4](configuration/decentralized-config/decisions/0052-index-integrity-version-gate-and-reconcile.md) — index-integrity cluster). The v1→v2
migration now re-homes each extra_mount under the project whose `project.yml` declares it (via
`yml_get_mount_coords`, host-only), leaving `unscoped:` for genuine project-less `cco path set` pins
only — restoring ADR-0051 D2. Residue already on disk is re-homed by a dedicated `fi23_rehome` lane
in `cco config validate --fix` (a MOVE under the declaring project, distinct from the orphan-prune
lane). Tests: `tests/test_resolve.sh` / `test_migrate_completeness.sh`; changelog #48.

**Status history**: 📝 Note — to analyze (found 2026-07-16 by code inspection while triaging FI-21; **live on
the maintainer's machine**).

**Context**: the v1→v2 index migration (`lib/index.sh:97`) re-homes a flat `paths:` name under every
project that lists it **in the `projects:` membership**. But membership is written by
`_index_set_project_repos`, fed from `yml_get_repo_coords` (`cmd-resolve.sh:330`/`537`, `cmd-init.sh`,
`cmd-join.sh`) — i.e. **repos only, never extra_mounts**. So every legacy extra_mount matches no
membership and is migrated into the `unscoped:` bucket, where `_index_get_path` (`lib/index.sh:523`)
consults it as a **fallback for any project**.

**Why it matters**: that fallback is a de-facto **global default layer for extra_mounts** — the exact
construct **ADR-0051 D2 explicitly rejected** ("no global-default layer … a global default is
meaningless for generic labels"). And it lands precisely on the generic names the ADR was written for:
the maintainer's live index shows `assets`, `mock`, `reference`, `project-docs`,
`cave-api-framework` sitting unscoped. Observable symptom: the messy mixed `cco path list` view
(prefixed `[project] name` rows *and* bare rows) that prompted the maintainer's "path list is a bit
of a mess" remark — the format is not the cause, the residue is.

**Severity is low, and why**: a project's own `project_paths` binding **wins** over the unscoped
fallback, so the residue is a stale record, not a wrong resolution. But it is a **completeness gap in
a just-shipped migration**, and it keeps a rejected mechanism reachable.

> **Correction (2026-07-20, RC-4).** The residue does **not** self-heal. `_resolve_entry_index`
> (`lib/local-paths.sh`) returns early when `_index_get_path` already answers — and that INCLUDES the
> unscoped fallback — so a legacy extra_mount resolving through `unscoped:` is never re-homed by
> `cco resolve`; `cco resolve --scan` re-homes host *repos* only (and duplicates rather than moves),
> extra_mounts by neither pass. The earlier "self-healing — `cco resolve` re-binds per project"
> wording was inaccurate. RC-4 does not clean the residue; it makes `cco path list` scope it correctly
> in its presence (a claimed unscoped row a current project resolves through stays visible as that
> project's binding; anything else rides `Po`). See `docs/maintainers/configuration/agent-cco-access/e2e-review/fix-design-v2/06-path-list-scoping.md` §5.5.

**Direction to evaluate**: decide whether the fallback is (a) an intentional escape hatch for the
project-less `cco path set` pin — which is how `index.sh:512-517` describes it, and that use is
legitimate — or (b) an unintended global default once *migrated* mounts land there. If the split is
real, the fix is in the **migration**, not the fallback: re-home a legacy extra_mount under the
projects whose `project.yml` actually references it (the coordinate reader for mounts already exists
alongside `yml_get_repo_coords`), leaving `unscoped:` for genuine project-less pins only. Pair with a
prune path for residue already on disk (`cco config validate --fix` is the natural home — FI-22).

**Re-verify the bound before design**: confirm whether membership *should* include extra_mounts at all
(it is named `_index_set_project_repos` and `cco join` reasons about repos — widening it may have
callers' semantics attached), and check whether `_index_get_path_any` (FI-21) plus this fallback
overlap into the same cross-project resolution question. FI-21, FI-22 and this note all touch the
index model — **scope them together before designing any one of them**.

**Type & tracking**: migration completeness → likely a follow-up migration + changelog.
**Effort**: Low–Med. **Not gating** the e2e review (project bindings win; RC-4 scopes the display — see the 2026-07-20 correction above, the residue does not self-heal).

---

## FI-24: The false-success class outside the cycle-1.1 boundary

**Status**: Audited 2026-07-21, not designed. Full report:
[`engineering/analysis/false-success-class-audit.md`](engineering/analysis/false-success-class-audit.md).

**Symptom**: a state-mutating call whose failure status is not propagated, followed by an
unconditional success announcement — the user sees `✓ <done>` and exit 0 while the mutation did not
happen, or half happened.

**Why the codebase is exposed to it**: `bin/cco` dispatches every verb as `cmd_foo "$@" ||
_cco_rc=$?`, and a `||` context **disables errexit for the whole call tree**. Explicit `||` / `if !`
propagation is the only mechanism that works, at every link.

**Boundary already claimed elsewhere — do not duplicate**: the `_index_*` writers, the three
failure-incapable primitives (`_remote_token_set`, `_remote_token_remove`, `_yaml_rename_list_ref`)
and the rename `project.yml` half are **cycle-1.1 stage S2b**
(`configuration/agent-cco-access/e2e-review/fix-design-v3/00-plan.md` §3b). Everything routed
through `lib/store.sh` is correct by architecture and out of scope.

**What FI-24 holds** — three clusters, each worth its own boundary pass:

1. **The update engine** (`update-merge.sh`, `update-sync.sh`, `update.sh`, `update-meta.sh`,
   `update-hash-io.sh`). No file-mutating call in the engine has its status checked — not one
   `|| die`, `|| warn` or `if !` guards any `cp`, `mv`, `mkdir`, `sed -i` or `>`. Two second-order
   effects make this the highest-consequence cluster: (a) `_resolve_with_merge`'s post-condition
   greps the *target* for conflict markers, so a failed `cp` leaves the user's unmarked original and
   the check asserts the opposite of the truth; (b) the run then advances `.cco/base/`, so the next
   `cco update` classifies the file `USER_MODIFIED` and filters it out — **the update is
   permanently and silently suppressed**. The corrupted config is committed/pushed while the base
   state that would reveal it is machine-local and never synced.

2. **`pack` / `template publish`** (`cmd-pack.sh:1315-1345`, `cmd-template.sh:1096`). `git commit`
   is bare and the `|| die` sits on `push` — so a failed commit leaves HEAD unmoved, `push` exits 0
   ("Everything up-to-date") and the guard is structurally unreachable. `_record_pack_base` then
   records the never-pushed tree as the merge ancestor, so every subsequent publish sees
   `ours == base`, takes theirs, and silently drops the user's change. Also `rm -rf "$theirs_dir"`
   followed by a bare `cp -R`, which on failure stages **deletion of the whole remote pack tree**.

3. **Local-destructive / backup-believed-to-exist**: bare `tar czf` announced as a completed export
   (`cmd-pack.sh:738`, `cmd-project-export-import.sh:128`), `rm -rf` + bare `cp -R` in
   install/import (`cmd-pack.sh:827/837/847`, `cmd-template.sh:585/600`,
   `cmd-project-export-import.sh:195`), `cco forget --purge`, `secrets.sh:155`, `migrate.sh:179`.

**Re-verify the bound before designing** (backlog convention): the audit lists ~20 sites
"considered and dismissed" with reasons — several look like the class and are not (deliberate
`|| true` on optional cleanup, tail-called redirects whose status does propagate, read-only
verdicts). Two items are explicitly **unresolved statically** and need a runtime check first:
whether `git merge-file` can exit 0 with a truncated output on a full `/tmp`, and
`_generate_project_cco_meta`'s status masking (`update-meta.sh:185-202`).

**Type & tracking**: correctness hardening; likely an invariant/lint (a mutation helper whose tail
statement cannot return non-zero) plus per-cluster fixes. **Effort**: Med–High (three clusters).
**Not gating** the e2e review or cycle 1.1 — but cluster 1 overlaps workstream **F** (the `cco
update` responsibility refactor), so scope them together.

## FI-25: the nested-`.claude` `:ro` clamp catches cco's OWN shipped `.claude` payload (self-dev)

**Status**: 📝 Note — to analyze (hit live 2026-07-21 while landing cycle-1.1 S5, which needed a
one-line edit to a managed rule and could not make it from inside a cco session).

**Context**: `_find_nested_config_dirs` (`lib/cmd-start.sh:507`) sweeps `find -type d -name .claude`
to maxdepth 6 under every repo, and each hit gets a `:ro` overlay when `claude_access` does not
grant rw (the ADR-0049 default). **For a normal project this is exactly right** — a monorepo's
`packages/x/.claude` *is* an authoring tree Claude Code discovers natively, so a root-only overlay
would leak; the function's own comment argues this well.

**But cco's own repo ships `.claude` directories as PRODUCT PAYLOAD, not authoring trees.** Measured
in a live session (`/proc/self/mountinfo`), the repo is `rw` while these are all `:ro`:

| Path | What it actually is |
|---|---|
| `defaults/managed/.claude/` | rules baked into the image at `/etc/claude-code/` — tool source |
| `defaults/global/.claude/` | the defaults copied to `~/.cco/.claude/` on `cco init` — tool source |
| `templates/project/base/.claude/` | a template's payload |
| `internal/{tutorial,config-editor}/.claude/` | built-in preset payload |

A name-based sweep cannot tell "an authoring tree this session will load" from "a directory of files
this tool ships to users". In cco's repo the two have the same shape and opposite roles — and
`defaults/` is classified as **tracked tool code** by the root `CLAUDE.md`.

**Consequence**: cco cannot self-develop its own managed rules, global defaults, or template payload
from inside a cco session — which contradicts the self-development model `/workspace/.claude/
CLAUDE.md` explicitly adopts. It is not hypothetical: S5 had to hand the maintainer a patch to apply
on the host (plan §6.-1), and the same will recur on every future change to `defaults/` or
`templates/`. Note the failure is at least **loud** (`EROFS`), not silent.

**Direction to evaluate** — options, not exclusive:
- **(a)** exclude the tool's own payload roots from the sweep when the repo IS the cco source repo
  (detectable: `defaults/managed/` + `bin/cco` present). Narrow, but a special case keyed on
  self-identification.
- **(b)** exclude by position rather than identity: never clamp a `.claude` under a directory that
  is itself template/preset payload (`defaults/`, `templates/`, `internal/`). Generalises to any
  project that *ships* config trees, not just cco.
- **(c)** accept it and make it legible — document that self-dev of `defaults/**/.claude` is
  host-side, and have `cco start` say so when it clamps a path under `defaults/`/`templates/`.
- **(d)** let `--claude-access all` cover it (it already would) and document that as the self-dev
  workflow. Cheapest; cost is that self-dev then runs with every authoring tree writable, which is
  broader than the need.
- **(e)** **explicit per-path override in config** (maintainer proposal, 2026-07-22). A declared
  list in `project.yml → access.claude.exclude: [<path>, …]` (paths freed from the default clamp),
  or the richer `access.claude.overrides: {<path>: <policy>}` (assign a per-path claude policy, e.g.
  `rw`). Unlike (a)/(b), the author *states* which nested `.claude` trees are shipped payload rather
  than the tool inferring it from self-identification or position — so it generalises to ANY project
  that ships config trees, not only cco, and composes with an equivalent map in `~/.cco/access.yml`
  for a cross-project default. **Fail-safe is preserved**: only listed paths are freed, an unlisted
  `.claude` stays clamped by default — satisfying the ⚠ below. Cost: a new (additive) `project.yml`
  schema surface + a lookup the B1 overlay loop (`cmd-start.sh:1807`) consults before emitting the
  `:ro` overlay for a swept path (`_find_nested_config_dirs` stays a pure finder; the override is
  applied at the mount-decision site). This is the only option that is a **user-facing feature**
  rather than an internal special-case — (a)/(b)/(c)/(d) remain valid as its zero-config default
  behaviour. In cco's own repo the list would be `defaults/`, `templates/`, `internal/` (the
  payload roots of the table above).

⚠ **Do not "fix" this by narrowing the sweep generally** — the monorepo case it exists for is real,
and the clamp is fail-safe. Whatever lands must keep an unrecognised `.claude` clamped by default.

**Type & tracking**: access-model UX + self-development workflow; no schema change. Interacts with
FI-20 (the same "a `:ro` overlay is correct but its consequences are unwritten" shape). **Effort**:
Low–Med. **Not gating** cycle-1.1 — but it makes S9's doc sweep partly host-side, so note it there.

---

## FI-26: `repo`/`extra-mount rename` resolves its unit from cwd, so it only runs from the HOSTING repo

**Status**: 📝 Note — to analyze (found 2026-07-21 by code inspection while landing cycle-1.1 S8's
V3-03; the ambiguity arm V3-03 added sits directly on top of this and deliberately does not fix it).

**Context**: `_rename_index_keyed` (`lib/cmd-repo.sh`) resolves the project it is about to rewrite
with `_resolve_find_unit_dir` — a walk up from cwd looking for `<dir>/.cco/project.yml`. `$unit` is
then load-bearing twice more: `_mount_declared_target "$unit/.cco/project.yml"` and the §3.5
fail-closed pre-flight `_rename_assert_writable "$unit/.cco"`.

**The consequence**: a project's committed config lives in ONE repo (the hosting one), so in a
session that walk succeeds **only from the hosting repo's mount**. From any other member repo — and
from the WORKDIR root — it fails, and it fails for BOTH forms:

- bare `cco repo rename <new>` — now correctly diagnosed as ambiguous at the WORKDIR root (S8/V3-03),
  but from a non-hosting member dir it still answers the generic "run from inside a project repo",
  which is false: the user *is* inside one.
- `cco repo rename <old> <new>` — the fully-specified form, which has no ambiguity at all, dies with
  advice to "pass `<old> <new>`" — which the user just did. This is the sharper half.

V3-03's guard was scoped to the WORKDIR root because that is what D-M9's Q-6 governs, and its message
deliberately avoids advising the 2-arg form for exactly this reason.

**Why it is not a one-liner**: the fix is to resolve `$unit` from the SESSION's project rather than
from cwd — the hosting repo's *mount*. `_resolve_unit_dir_for_project` already exists but returns
index HOST paths, which by **INV-F** can never be existence-tested in-container; it would need to
route through `_cco_member_probe_path`, the way B-DF1's class of fixes did. That is a resolution
change touching a fail-closed pre-flight, so it wants its own design pass, not an opportunistic edit.

⚠ **Check the class, not the instance** — B-DF1 and S7 both taught this cycle that these fixes come
in families. `_resolve_find_unit_dir` has **nine** other callers (`cmd-sync.sh`, `cmd-project-add.sh`,
`cmd-project-export-import.sh`, `cmd-project-rename.sh`, `cmd-resolve.sh` ×2, `cmd-start.sh` ×2,
`cmd-project-validate.sh`); `project validate` and `project show` already route around it via
`_project_session_fallback` (S6/R4), which is evidence the gap is known and being closed
piecemeal. Enumerate all of them before designing.

**Type & tracking**: CLI environment-awareness (dual-context correctness); no schema change.
Sibling of FI-21's "explicit project scope on the host-path surface". **Effort**: Med.
**Not gating** cycle-1.1.

## FI-27: `_index_normalize_path` does not canonicalize symlinks or a trailing `/.` (macOS index divergence)

**Status**: ✅ **Design + implementation DONE (2026-07-24)** — ADR-0053 + code + tests, on
`feat/index/path-canonicalization` (off develop; see Resolution). Found during the macOS bash-3.2 /
BSD test-portability sweep. It **gated the e2e v3.1 review** (impl-touching fixes decided *before*
the review); with it closed, the gate lifts.

**Context**: `_index_normalize_path` (`lib/index.sh`) is the single normalizer every value written to
the index `paths:` section flows through. By design (design §3) it is a **pure string** normalizer —
it expands `~`/`$HOME` and rejects non-absolute input, but deliberately does **not** touch the
filesystem. So it neither resolves symlinks nor collapses a trailing `/.`: two spellings of the *same*
directory are stored and compared as distinct keys.

**The consequence**: on macOS the same dir has two names — `/var/folders/…` is a symlink to
`/private/var/…`, and cco resolves the caller cwd with `cd -P … && pwd` → the `/private/var` form,
while a path registered from a raw `mktemp`/coordinate keeps `/var`. The two never match, so by-name
resolve, cwd-first repo/extra-mount rename, `join` member indexing and the AD5 conflict check all
diverge — plus the reconcile "legacy … vs current … differ" warning fires. The test suite hit exactly
this; it is now papered over in the harness by wrapping `mktemp` to canonicalize its output with
`pwd -P` (commit `8317222`; the earlier `TMPDIR`-canonicalization `92bdad0` was a macOS no-op — BSD
`mktemp` ignores a reassigned `TMPDIR`). **A real macOS user is still exposed**: any repo under
`/var`, `/tmp`, or another symlinked prefix — or a path
registered with a trailing `/.` — reproduces it. The live self-dev session path map already shows this
repo registered as `…/claude-orchestrator/.` (trailing `/.`), which is the same class.

**Why it is not a one-liner**: adding `realpath`/`pwd -P` at the write boundary is a filesystem-
touching change on the hot path that *every* path write crosses, and it reverses the deliberate purity
of design §3. The design pass must decide: (a) resolve symlinks + strip trailing `/.` at the write
boundary, vs canonicalize only at the (fewer) compare sites; (b) how to stay correct when the path
does **not exist yet** at write time (a coordinate not yet cloned — `realpath` on a missing path); and
(c) whether a migration is needed to re-key already-divergent bindings in existing indexes.

**Type & tracking**: index-model correctness (macOS symlink / `/.` canonicalization). Part of the
FI-21/22/23 index-model theme; **no schema change** (see Resolution (c)). **Effort**: Med.
Was **gating** the e2e v3.1 review (design + decision), not blocking the shipped test-harness fix.

**Resolution (ADR-0053, 2026-07-24).** The three design questions were answered:
(a) **canonicalize at the write boundary, two-tier** — a pure-string lexical pass folded into
`_index_normalize_path` (collapses `//`, `/./`, trailing `/.`/`/`; `..` left intact) closes the
lexical class at every read/compare site, plus a filesystem-touching `_index_canonicalize_path`
(`cd … && pwd -P`, no `realpath`) at the write boundary + `_resolve_to_abs` resolves symlinks;
(b) **best-effort** — resolve symlinks only when the dir exists, else keep the lexical form (the
hot-path writers always have an existing dir; `path set`/legacy-rehome fall back and self-heal);
(c) **no migration** — lazy self-heal on write + a new `cco config validate` **re-key** lane
(`--fix` rewrites a non-canonical entry to canonical; the `016_normalize-index` precedent stays
pure-string, ADR-0051 D6 keeps the index self-upgrade in-index). Physical resolution is host-only
(INV-CANON, ADR-0047). Suite **1521/7** in-container (+8 new tests; the 7 = pre-existing FI-19
host-only). See ADR-0053, changelog #50; fwd-annotated on ADR-0051 D1 + ADR-0052 §5/§7.

**Follow-on fix (2026-07-26): bash 3.2 replacement escaping.** The Tier-1 lexical loop shipped with
`${p//\/\//\/}` / `${p//\/.\//\/}`, whose replacement `\/` carries a backslash. bash ≥4.3 un-escapes it
to `/`; bash 3.2 (macOS default `/bin/bash`) keeps it literal, so `//`→`\/`, `/./`→`\/`
(`/a//b`→`/a\/b`, `//`→`\`). The in-container review (bash 5) never saw it; the host suite did
(`test_index_normalize_path_lexical_canon`). Fixed by moving the slash sequences into variables so
neither pattern nor replacement carries an escaped `/` (`c9b6d35`, `fix/index/normalize-bash32-replacement`
→ develop). Only those two lines carried the antipattern (`remote.sh:41` escapes only in the pattern →
safe). Host suite now fully green on bash 3.2; no changelog/migration (unreleased code). Lesson: a
backslash in the **replacement** of `${var//pat/rep}` is a bash-3.2 antipattern the in-container suite
cannot catch — use variables.

---

## FI-28: Global pack adoption — declare a pack adopted across projects from the personal store (with filters)

**Status**: 📝 Note — to design (raised 2026-07-26 by the maintainer, from a field question: *"how do
I import a pack globally into `~/.cco` and adopt it in all my projects by default?"*). Not started.

**Context (code-grounded, verified 2026-07-26).** Attaching a pack is **per-project and only
per-project**: a `packs:` entry in `<repo>/.cco/project.yml`, written by hand or by `cco project add
pack <name>` (`lib/cmd-project-add.sh`, cwd-first or `--project`). `_generate_pack_mounts`
(`lib/packs.sh`) reads that list and nothing else, so a pack that is not named in a project's manifest
is invisible to its sessions. There is **no** global/default adoption surface anywhere: no
`defaults.yml`, no `default_packs`, no `~/.cco` file that `cco start` consults for packs. The two
things that come close are both something else:

- `~/.cco/.claude/{CLAUDE.md,rules/,agents/,skills/,settings.json,mcp.json}` — mounted user-level in
  **every** session (`lib/cmd-start.sh`, B3 block). This is the real always-on layer today, but it is
  the `.claude` **authoring** tree, not the pack model: no `knowledge/` mount, no pack identity /
  coordinate / provenance / `cco pack update`, and no per-project opt-in or visibility.
- project **templates** — a `packs:` list in a template gives a default to **new** projects only,
  never retroactively.

**The ask (maintainer, 2026-07-26).** A **global settings surface in `~/.cco`** where a pack can be
declared adopted across projects, optionally **filtered** (tags / attributes / conditions) so it lands
only on a subset. A CLI verb may exist but would be a thin editor of that config — bulk adoption
without touching any repo. A **second mode** materializes the adoption instead: write the `packs:`
reference into every matching project's `project.yml`, which some users will prefer (explicit,
committed, team-visible), also filter-driven.

```mermaid
flowchart TD
  P["pack in ~/.cco/packs/<name>"] --> M1["M1 declarative: ~/.cco adoption rules + filters"]
  P --> M2["M2 materialized: bulk write packs[] into matching project.yml"]
  M1 --> R["cco start resolves: project packs[] UNION adopted-by-rule"]
  M2 --> Y["project.yml carries the ref (normal per-project path)"]
  R --> S["session mounts + session context must state WHY each pack is here"]
  Y --> S
```

**The two modes are not exclusive** (plausibly one verb with a `--mode`/`--materialize` switch), and
each carries a different hazard:

- **M1 — declarative / personal store (maintainer's preferred primary).** Personal, reversible, no
  repo churn, works even for repos you do not own. Hazard: it is **implicit context** — a session
  carries packs the repo does not declare, so a teammate cloning the same repo gets a *different*
  session. That runs against the standing invariant that `<repo>/.cco/project.yml` is the source of
  truth and committed config is machine-agnostic + reproducible. Mitigation is visibility, not
  prohibition: the resolved set and its provenance must surface in the injected session context and in
  `cco project show` (same "hidden ≠ absent" discipline as ADR-0043).
- **M2 — materialized / bulk (the earlier option B).** Explicit, git-visible, reproducible for the
  team. Hazard: a fan-out **write across N repos**, each with its own git state; in-session the
  `<repo>/.cco` overlay is `:ro` (FI-20) and writing other projects' trees is the `Po` axis of the
  ADR-0046/0047 model (`edit-all` or granular today) — so it is host-leaning, non-atomic (cf. the
  E6B-04 pack-rename fan-out half-apply class), and not undoable in one step.

**Design questions**:
1. **Where + what name.** A dedicated `~/.cco/packs.yml`, or a general `~/.cco/defaults.yml` that
   could later host other cross-project defaults (model, ports, llms)? Precedent exists:
   `~/.cco/access.yml` is already a personal-store settings file consulted by `cco start` and sitting
   in a documented precedence chain (CLI > `project.yml` > `~/.cco/access.yml` > preset) — the
   adoption file should join a chain of the same shape.
2. **Filter grammar.** The per-user **tag registry** (DATA, `cco tag add`, `lib/tags.sh`) already tags
   projects/packs/templates and `cco list --tag` already filters on it → tags are the obvious primary
   selector. What else is needed (name globs, path prefixes, "project has repo X", arbitrary
   attributes)? Constraint: declarative and evaluable host-side, never user code execution.
3. **Precedence + opt-out.** Union with the project's own `packs:`? Can a project refuse an adopted
   pack (an explicit exclude list), and does a project-local pack of the same name win (three-layer
   resolution, ADR-0019 D5)?
4. **Provenance/visibility.** The session context must distinguish "declared in project.yml" from
   "adopted by rule R" — otherwise the implicit-context hazard above is unattributable.
5. **Access model.** Which `(G,Pc,Po)` levels may read/write the adoption file (personal store = `G`)
   and which may run M2 (`Po=rw`)? The in-container shim must gate both, and M2 is a candidate
   host-only verb.
6. **Contribution surface.** Which pack kinds a global adoption may contribute — `knowledge/`,
   `rules/`, `agents/`, `skills/` today; `commands/` is missing entirely → **FI-29**.
7. **Change class.** Additive (new optional personal-store file + new verb): code-level default when
   absent + `changelog.yml` entry; no migration unless M2 rewrites manifests.

**Type & tracking**: pack model + personal-store configuration; introduces a **new configuration
precedence axis**, which is ADR-worthy rather than a quiet feature. Related: **FI-29** (`commands/`),
`#9 Pack inheritance / composition` in [roadmap.md](roadmap.md) (same "who composes what" question),
ADR-0019 D5 (three-layer pack resolution), ADR-0032 (pack coordinates), ADR-0043 (scoped visibility /
hidden ≠ absent), ADR-0046/0047 (write axes + boundary), FI-20 (`:ro` `.cco` overlay vs writes).
**Effort**: Med–High (design-first; the implementation of M1 alone is small).

---

## FI-29: `commands/` (slash commands) has no home in the global store or in packs

**Status**: 📝 Note — to analyze (found 2026-07-26 by code inspection while answering FI-28's field
question). Independent of FI-28 but blocks the same use case.

**Context**: a grep over `lib/`, `config/` and `defaults/` finds **no handling of `commands/` at
all**. Two consequences, both asymmetric with how skills/agents/rules are treated:

- The global `.claude` mount is **explicit, entry by entry** (`lib/cmd-start.sh` B3: `settings.json`,
  `CLAUDE.md`, `rules/`, `agents/`, `skills/`, `mcp.json`), so a `~/.cco/.claude/commands/` directory
  would simply never be mounted — it is silently ignored, not an error.
- `pack.yml` declares only `knowledge` / `skills` / `agents` / `rules` (`templates/pack/base/pack.yml`,
  `_generate_pack_mounts` + `_validate_single_pack` in `lib/packs.sh`), so a pack cannot ship slash
  commands either.

Only the **project** tree works today, and only incidentally: `<repo>/.cco/claude/` is mounted whole
at `/workspace/.claude`, so a `commands/` inside it lands exactly where Claude Code looks for project
commands.

**Why it matters**: a "dev framework" distributed as Claude Code slash commands is a common shape (it
was precisely the shape of the directory that raised FI-28). Today such a bundle can only be adopted
per-project by hand, and cannot be packaged as a pack at all.

**Suggested direction** (re-derive the boundary before designing): (a) add `commands/` to the B3
global mount + a `defaults/global/.claude/commands/` scaffold; (b) add `commands:` to the pack schema,
`_generate_pack_mounts` (per-file mounts to `/workspace/.claude/commands/<f>.md`, identical in shape
to the rules/agents lanes), `_validate_single_pack` and `cco pack show`; (c) verify the pack conflict
detectors (`_detect_pack_conflicts`, `_detect_cross_tree_conflicts`) cover the new kind. Additive
(changelog entry); no migration needed — an absent `commands/` reproduces today's behavior.
**Effort**: Low–Med.

---

## FI-30: user-facing install / init / configuration procedures — coherence review

**Status**: 📝 Note — to analyze (raised 2026-07-25/26 by the maintainer; captured here from the
working note `to-verify-guides-docs.md` at the repo root).

**Context**: the top-level README quick start reads

```
npm install -g @claude-orchestrator/cco   # install the CLI
cco init                                   # "seeds your personal ~/.cco store and builds the image"
cco start tutorial
```

which presents `cco init` as a **global bootstrap runnable from anywhere**. In the implemented model
`cco init` is **cwd/repo-based project initialization**; seeding `~/.cco` on first run is a side
effect, not its purpose. As written the quick start is misleading about the very first command a new
user types.

**Scope of the review**: install / init / configuration procedures across the top-level README, the
user guides (installation, project-setup, configuration-management), the tutorial, and the maintainer
docs — checking each is correct, non-misleading, and mutually coherent (user docs vs maintainer docs).
Per the documentation-lifecycle rule these are **shipped-behavior** docs: they must track what works
today, not a target model.

**Adjacent question flagged by the maintainer**: whether the install itself should be unified behind
an npm **post-install hook** ("Unificazione dell'install => hook post install", note in
`workspace-ai.rtf`) — a design question in its own right, to be settled before rewriting the quick
start around it. **Effort**: Low (review) + Med if the post-install unification is taken on.

---

## FI-31: pack/llms child mounts have no mountpoint stub → `cco start` fails on a `:ro` `/workspace/.claude`

**Status**: ✅ **FIXED 2026-07-26** — [ADR-0054](../configuration/decentralized-config/decisions/0054-framework-owned-mountpoints.md)
+ implementation + 9 tests, changelog #51 (see Resolution). Reproduced on the host the same day
(maintainer, project `cave-ensemble` after `cco pack import` + `cco project add pack
core-dev-framework`); it blocked pack adoption at the **default** access level.

**Symptom** (host, `cco start`):

```
Error response from daemon: failed to create task for container: … runc create failed:
error mounting "/host_mnt/Users/…/.cco/packs/core-dev-framework/skills/review-refactoring"
to rootfs at "/workspace/.claude/skills/review-refactoring": create mountpoint … : read-only file system
```

**Root cause (confirmed in code)**: a child bind whose target does not exist inside a `:ro` parent
bind cannot be created — runc must `mkdirat`/`mknod` the mountpoint in the parent's backing tree and
gets `EROFS`. `_generate_pack_mounts` (`lib/packs.sh:171–211`) emits **four** such child binds —
`/workspace/.claude/packs/<pack>` (knowledge), `/workspace/.claude/rules/<f>`,
`/workspace/.claude/agents/<f>`, `/workspace/.claude/skills/<dir>` — and `_generate_llms_mounts`
(`lib/llms.sh:123`) a fifth, `/workspace/.claude/llms/<name>`. **None of them seeds the mountpoint in
the mount source** (`<repo>/.cco/claude/`). The parent B2 mount is `:ro` whenever `claude` `Cp=ro`
(`lib/cmd-start.sh:1582/1637`), which **ADR-0049 made the default** (it reverses P17 — a normal
session no longer authors `.claude`).

**This is the exact class already fixed once**: ADR-0049 §5's `_emit_local_settings_overlay`
(`lib/cmd-start.sh:479`) exists *only* because of it, and its comment states the rule — *"Mountpoint
stub inside the `:ro`-to-be parent … a missing one means a caller bug, and the bind fails loudly."*
The fix was applied to the `settings.local.json` lane and **never extended to the pack/llms lanes**.
See the `start-mount-fix` diagnosis (2026-07-15) for the original analysis of the same shape.

**The design trail says the intent was right and a precondition was dropped.** ADR-0005's
`RD-claude-mount` resolution designed exactly this composition — pack/llms resources as nested `:ro`
binds inside `/workspace/.claude`, ordered parent-before-child — and recorded **F3 as an invariant:
"parent stays rw"**. The nested-overlay mechanism was proven *on that precondition*. **ADR-0049 §2
then made `Cp=ro` the default and never revisited F3.** The consequence was discovered on 2026-07-15
and written down verbatim in ADR-0049 §5's forward annotation — *"Docker/runc cannot create the
mountpoint inside the `:ro` parent … the target must simply pre-exist"* — but the remedy was applied
**only to the `settings.local.json` lane**. The pack/llms overlays are the other consumers of the same
dropped precondition, and nothing carried the fix to them. So the ADRs do **not** disagree about the
intent (pack resources are readable in every session regardless of the `claude` policy — that policy
governs *authoring*, never *visibility*); what is missing is the mechanism that still makes the intent
true after F3 stopped holding.

**Why it surfaced only now**: projects configured **before** ADR-0049 flipped the default ran with
`.claude` writable, so runc silently created the mountpoint dirs inside their committed
`<repo>/.cco/claude/` tree — those stubs persist and mask the bug (claude-orchestrator's own tree
carries exactly this residue: `.cco/claude/llms/{platform-claude,code-claude}/`, auto-created empty
dirs). A **newly adopted** pack has no such residue → first `cco start` after adoption fails.

**Why the suite is green**: the same blind spot recorded for the ADR-0049 §5 bug — tests assert the
**generated compose YAML** (dry-run), and no test starts a real container.

**Directions to weigh at design** (re-derive the boundary first):
- **(a) extend the stub-seeding precedent** — one `_ensure_mountpoint` helper called for every child
  bind under a `:ro` B2/B1 parent (dir stub for `skills/`, `packs/`, `llms/`; empty-file stub for
  `rules/`, `agents/`), reusing the migration-014 `.gitignore` machinery so the stubs do not pollute
  the repo. ⚠ Three traps: an empty-file stub must **never truncate** an existing committed file; a
  `packs/<n>` stub must stay **empty** or `_detect_cross_tree_conflicts` (`lib/packs.sh:106`) fires
  its "framework-reserved" warning on the framework's own stub; and a **file** stub in `rules/` /
  `agents/` is indistinguishable from user content to a static `.gitignore` pattern (the
  `settings.local.json` precedent got away with a single fixed name — here the names come from
  whatever the pack declares). Also note this direction writes framework-derived artifacts into the
  committed tree, which **ADR-0005 F1 explicitly decided against** ("generated files are NOT written
  into `.cco/claude/`; they are produced in a machine-local cache dir and overlaid"): the `settings.local.json`
  seed is already an exception to F1, and this would multiply it across four more lanes.
- **(b) framework-owned parent** — compose `/workspace/.claude` in CACHE (committed-tree entries bound
  in individually at the policy's mode, pack/llms children as today) so the parent's writability
  belongs to the **framework**, not to the policy. This restores F3 by construction, applies F1's own
  rule to mountpoints, leaves zero residue in the repo, and makes pack visibility structurally
  independent of `claude_access`. ⚠ Cost to weigh: a *shared* namespace that must hold files from two
  sources (`rules/`, `agents/`, `skills/`) has to be framework-owned, so a **newly created** file
  written there in-session lands in CACHE rather than the repo (edits to existing files still reach
  the repo through their per-file bind). Bounding the composition to the namespaces a pack actually
  contributes to — or to `Cp=ro` sessions only — keeps that cost off the authoring path.
- **(c) parent `:rw`** — already **rejected** for the settings lane (holes the `ro` guarantee: new
  files become creatable). Today it is the only *workaround* available to users.
- **Test gap**: whichever lands, the regression is invisible to a dry-run assertion — this class needs
  a real-container smoke check (the e2e harness is the natural home).

**Type & tracking**: mount-generation correctness; **user-visible regression on the default path**
(any project at default access adopting a pack that ships skills/rules/agents/knowledge). Feeds the
pending **e2e v3.1** run. Related: ADR-0049 §5, `_emit_local_settings_overlay`, FI-20 (`:ro` overlay
consequences), FI-32. **Effort**: Low–Med (the fix is small; choosing (a) vs (b) is the design call).

**Resolution (ADR-0054, 2026-07-26).** Direction **(b)** — the design question was *who owns the
mountpoint*, and answering "the framework" removes the coupling instead of working around it.
**INV-MP**: cco creates every framework mountpoint host-side, in a tree it owns, never leaving it to
runc and never depending on a policy-governed tree being writable. When (and only when) a session
injects children under `/workspace/.claude`, the parent becomes a mountpoints-only view in CACHE
(`_cco_project_claude_view`, rebuilt per start) mounted **at the policy's mode** (D3 — a rw-by-fiat
parent would fake successful writes), with the committed tree bound back in entry by entry: per file
inside a namespace that received an injection, whole-directory otherwise. The injected set is
**derived from the emitted mount lines**, so FI-29's `commands/` lane will be covered the day it
emits one. ADR-0005 F2 precedence is now explicit (the duplicate committed bind is dropped) and F1
regains the `settings.local.json` lane (its stub moves into the view). One bounded delta, surfaced at
start (D4): in a composing session with `Cp=rw`, a *newly created* file directly under a composed
namespace is session-local. No migration. Suite **1531/7** (+9 tests; 8 revert-checked against
pre-fix `lib/` — the 9th pins the unchanged no-injection path and must pass on both). ⚠ The
mount-time failure itself remains invisible to the hermetic suite (D7, third recurrence) — one e2e
v3.1 probe with a skills-shipping pack at default access is what actually proves it on a host.

**Follow-up the same day — the first implementation was still broken on the host** (`EROFS` on
`settings.json` instead of on a pack skill). Cause: `local view="$1" rel="$2" src="$3"
mp="$view/$rel"` — `local` is a builtin, so every argument is expanded *before* any assignment lands,
and `$view`/`$rel` resolved to the **caller's** identically-named variables (dynamic scope). That is
correct by accident inside the injected-children loop and a silent no-op for every committed entry,
so their mountpoints were never created and the emitted binds had no target. Three things came out of
it: the one-line fix; D7 strengthened from spot checks to a **property** (every emitted child target,
from both halves, must have a mountpoint of the matching shape — the assertion that would have caught
it); and a static lint **INV-LOCAL** (`test_invariant_no_local_self_reference`) closing the language
trap for good, which surfaced two more latent instances (`_config_ensure_gitignore`, `_mig014_rm` —
both accidentally correct today, one caller rename from breaking). Suite **1533/7**.

---

## FI-32: pack↔global collisions are undetected (`_detect_cross_tree_conflicts` only looks at the project tree)

**Status**: 📝 Note — to analyze (found 2026-07-26 while diagnosing FI-31, on the maintainer's real
`core-dev-framework` pack). Silent, not a crash.

**Context**: `_detect_cross_tree_conflicts` (`lib/packs.sh:106`) compares a pack's declared
`rules`/`agents`/`skills` against the **committed project tree** (`<repo>/.cco/claude/`) only.
The **global** store `~/.cco/.claude/{rules,agents,skills}` — mounted user-level into *every* session
(`lib/cmd-start.sh` B3) — is never consulted, and `_detect_pack_conflicts` only compares packs against
each other.

**Consequence**: a pack that ships `rules/workflow.md`, `agents/reviewer.md` or `skills/review/` with
the same names as the user's global defaults produces **two live copies at different scopes** (user
level `~/.claude/…` + project level `/workspace/.claude/…`) with **no warning at all**. This is not
theoretical: the maintainer's `core-dev-framework` duplicates three of the four shipped global rules
(`documentation.md`, `git-practices.md`, `workflow.md`) and overlaps the shipped global skills
(`analyze`, `commit`, `design`, `review*`) and agents (`analyst`, `reviewer`). The agent then reads
two potentially divergent versions of the same rule with no signal about which is authoritative.

**Suggested direction**: extend the detector with a global-tree pass (warn, never block — P14), and
decide the *reporting* question it exposes: cross-scope duplication is legitimate in some cases
(a project deliberately overriding a global rule), so the message must name the scopes and the
resolution order rather than imply an error. Relevant to **FI-28** (a globally adopted pack multiplies
exactly this class). **Effort**: Low.

---

## FI-33: two cco surfaces render the same binding's host path differently

**Status**: 📝 Note — to analyze (found 2026-07-28, e2e v3.1 session W1; cosmetic, no data risk).

**Context**: in one session, before a rename, `cco path list` printed
`…/Software/claude-orchestrator` while `cco project show` printed the same binding as
`…/Software/claude-orchestrator/.` — with a trailing `/.`. `_cco_display_path`
(`lib/paths.sh:395-403`) is a pass-through when `show_host_paths` is on, so the two diverge
**upstream**: `path list` reads the index, while the repo-centric `project show` takes `$repo_path`
from the effective-mount source, which carries the compose bind's `/.` (the same form the injected
session `path_map` shows). After the rename the divergence disappeared — the re-keyed index entry
became the source for both.

**Suggested direction**: ADR-0053 / FI-27-adjacent. The two-tier canonicalization landed at the index
**write** boundary; this is a *display* source that never passes through it. Decide whether the
effective-mount source should be normalized on read, or whether `project show` should read the index
like its sibling. **Effort**: Low.

---

## FI-34: a project-shaped index entry that no reconciliation can see (`projects` vs `project_paths`)

**Status**: 📝 Note — to analyze (found 2026-07-28, e2e v3.1 session W2, at `edit-all` where nothing
is scope-hidden, so the two surfaces genuinely disagree).

**Context**: `proj-b` owns a row in `cco path list` (`[proj-b] proj-c /tmp/cco-scratch/proj-c`) and is
absent from `cco list projects`. Mechanism confirmed at the source: the two surfaces read **different
index sections** — `_index_list_projects` dumps `projects` (`lib/index.sh:1130`), `cco path list`
dumps `project_paths` (`_index_pp_dump_all`, `:774`, used at `:1122`, ADR-0051 D6). An entry with
`project_paths` rows and no `projects` entry is structurally invisible to `_index_list_projects`.

**Consequence**: S7's declared-vs-effective diff is built on exactly that call, so such an entry is
**neither mounted nor announced** — the class S7 exists to close. `cco pack rename`'s fan-out guard
counts unmounted projects from the same source, so its atomicity promise has a hole in the direction
it was built to prevent.

**Suggested direction**: probably scratch residue (`/tmp/cco-scratch/proj-c` is a host scratch path),
but *"a project-shaped index entry no reconciliation can see"* is the item, not the entry. Whether
this instance is residue or a live orphan **cannot be discriminated from inside a container** — it
needs a host `cco config validate`, which is the verb that would normally arbitrate it. Decide
whether `projects` and `project_paths` need a consistency lane in `config validate --fix`.
**Effort**: Low–Med.

---

## FI-35: a binding whose target is a **file** passes every surface unflagged

**Status**: 📝 Note — to analyze (found 2026-07-28, e2e v3.1 session W3; inert in that session because
config-editor never mounts a target's extra_mounts).

**Context**: `cave-web-kit` resolves to `…/shared/cave-web-kit/vite.config.ts` — a **file**, where a
mount source must be a directory. `cco path list` and `cco project show` print it without comment, and
`cco project validate` flags it only for the *unrelated* missing-`url` reason (`reachability=2`); the
**shape** of the binding is never checked.

**Consequence**: no surface distinguishes *"bound to something usable"* from *"bound to nonsense"* —
V1-F2's `[unresolved]` covers **unbound**, not **bound-to-a-file**. Almost certainly a mis-scoped host
`cco path set`, i.e. the host-side index-hygiene class `handoff-v3.md` §9 defers to cycle 2.

**Suggested direction**: add a shape check to the validate lane (a mount source must be a directory),
and decide whether it is a warning or an error. Related to FI-34 (both are index hygiene the container
cannot arbitrate). **Effort**: Low.

---

## FI-36: after a rename the cwd-first `<old>` derivation is stale and misdiagnoses

**Status**: 📝 Note — to analyze (found 2026-07-28, e2e v3.1 session W1; narrow — post-rename,
pre-restart only — and non-destructive).

**Context**: the cwd-first form of `cco repo rename` derives `<old>` from
`_cco_member_name_from_mount`, i.e. the **mount basename** (`lib/paths.sh:411-418`). After a rename
the mount path still carries the *old* label, so the derived `<old>` names something the index no
longer has:

```
$ cco repo rename w1-third-name -y
✗ No repo named 'claude-orchestrator' in project 'claude-orchestrator'. Run
  'cco project show claude-orchestrator' to see its members.
$ cco project show | tail -1
  claude-orchestrator-w1probe (…) — also in: cave-ensemble
```

The message sends the user to a command whose output does **not** contain the name it just said is
missing.

**Suggested direction**: V3-P's info note (*"restart the session for the new name to take effect"*) is
printed on the rename that creates the condition and does its job, so this is the cost of a state the
user was warned about — not a contradiction of it. Cheapest correct fix is probably for the cwd-first
derivation to consult the index rather than the mount basename, or to say *"this session still has the
pre-rename mount"* when the derived name is absent. **Effort**: Low.

---

## FI-37: no working workflow-save path in the repo lane (`<repo>/.claude`, axis `Cr`)

**Found**: 2026-07-28, `/review-implementation` of cycle-1.2 S1. **Severity**: usability, no data
loss. **Effort**: Medium — the fix is a mechanism choice, not a patch.

ADR-0055 D3 gives the cco *project* tree (`/workspace/.claude`) a functional-write floor so
project-scope workflow saves work at any access level. The **repo** tree did not get one, and
**INV-FLOOR is scoped accordingly** (ADR-0055 D2) — deliberately, because a repo's native `.claude/`
is cross-cutting config shared with everyone who clones it, so writing there is closer to authoring
that repository than to this session's runtime state.

The usability gap that remains is real, and it lands on the class D5 exists to serve. Verified on a
live default session:

```
.../claude-orchestrator/.claude   /workspace/claude-orchestrator/.claude          ro
.../local-settings/repo-….json    /workspace/claude-orchestrator/.claude/settings.local.json  rw
```

A subagent, teammate, worktree or background session whose cwd is inside a repo saves to
`<repo>/.claude/workflows/` — the official range is *"the closest existing `.claude/workflows/`
between your working directory and the repository root"*, and `/workspace/.claude/workflows/` sits
**above** that root, so D3's overlay is not a fallback. The save fails whether or not the directory
exists (`:ro` bind either way).

Worse in the nested case: `packages/*/.claude` overlays get **no floor at all**, not even
`settings.local.json` — that overlay is conditioned on `_cl_rel == ".claude"` (`lib/cmd-start.sh`).

**Options** (each was weighed and deferred rather than dismissed):

- **(a) Stub directory in the user's repo + rw bind from STATE.** Extends the precedent already in
  place for `settings.local.json`, which writes a stub into the user's repo. Cost: a visible
  directory appears in a repo the user did not ask cco to modify, plus the gitignore question.
- **(b) A per-repo view in CACHE**, generalizing ADR-0054's mechanism to B1. No residue in the user's
  repo and structurally the same answer B2 already uses. Cost: a substantial mechanism change that
  deserves its own design pass — which is why it is here and not in S1.
- **(c) Leave it**, and say so in the user docs so the failure is expected rather than surprising.

**Related**: ADR-0055 D2/D3 · ADR-0049 §2 (`Cr=ro` by default) · ADR-0024 (the reach argument that
makes the repo tree cross-cutting).

---

## FI-38: hygiene of the workflows STATE overlay (stale stubs, silent collision)

**Found**: 2026-07-28, `/review-implementation` of cycle-1.2 S1. **Severity**: minor, no data loss.
**Effort**: Low each, but both are policy choices rather than bugs — which is why they are here.

Two properties of `_emit_workflows_overlay` (`lib/cmd-start.sh`), the rw overlay ADR-0055 D3 puts at
`/workspace/.claude/workflows` when B2 is `:ro`. Each committed workflow gets a 0-byte mountpoint stub
seeded into STATE so its `:ro` bind has somewhere to land.

**(a) A stub outlives the entry that justified it.** Remove a workflow from the committed tree and its
stub stays in STATE — where STATE is the *rw parent*, so it now reads as a real, empty workflow of the
same name. The CACHE view does not have this problem because it is rebuilt from scratch at every
start; the STATE overlay cannot be, since it holds real user saves. A GC needs a rule for telling a
stale stub from a genuinely empty file the user saved, which is the decision.

**(b) A collision is resolved silently.** If the user saves `X.js` (lands in STATE) and the repo later
commits its own `X.js`, the overlay correctly does not overwrite — and then binds the committed file
`:ro` on top, so the user's version is invisible and unwritable with no notice. The exact precedent
for saying so exists: `lib/packs.sh:133-143` warns *"collides with pack … the pack ':ro' overlay
wins"*. ⚠ Implementation note for whoever takes this: the function runs inside `$( )` and its stdout
**is** compose YAML, so any notice must go to stderr or be emitted by the caller — printing it from
inside would corrupt the generated file.

**Related**: ADR-0055 D3 · ADR-0005 F2 (pack overlay wins) · [FI-37](#fi-37-no-working-workflow-save-path-in-the-repo-lane-repoclaude-axis-cr).
