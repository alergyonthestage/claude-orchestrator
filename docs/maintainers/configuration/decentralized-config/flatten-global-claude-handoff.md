# Handoff — Flatten `~/.cco/global/.claude/` → `~/.cco/.claude/` (PRE-MERGE)

**Status**: Self-contained launcher for a **pre-merge** structural change. NOT started.
Decided 2026-06-26; handoff written 2026-06-27. Runs in its own session after maintainer
go-ahead. Branch `feat/vault/decentralized-config`, commits **LOCAL** (push from Mac).

> **One-line goal.** Drop the `global/` wrapper from the personal store: the global
> (user) Claude config moves from `~/.cco/global/.claude/` to **`~/.cco/.claude/`**.
> `~/.cco` is already the global config scope, so the extra `global/` level is a
> vault-era vestige and is applied inconsistently (only `.claude/` lives under it).

> **Why PRE-merge (the maintainer's reason).** Fold this into the **single**
> decentralized-config migration so every user gets the flat layout in ONE coherent
> migration at v1 — avoid shipping `~/.cco/global/.claude` now and forcing a **second**
> `mv … → ~/.cco/.claude` on users later. v1 has not shipped, so there is exactly one
> migration window; use it.

---

## 0. TL;DR — what this session does

1. Write **ADR-0028** (supersedes the `~/.cco/global/.claude` layout from ADR-0024 / ADR-0026 / design §2).
2. Rewrite the **living design** docs to `~/.cco/.claude/`.
3. Change the **implementation** at every `~/.cco/global/.claude` reference (readers + writers).
4. Add the **migration** (fresh + legacy-vault + already-on-`global/` users all land at `~/.cco/.claude`, idempotent).
5. Fix **shipped-behavior docs** + **stale references** left in related docs.
6. Update **tests/fixtures**; suite green; dogfood a real migrate.

Scope is a **rename of the user-store destination only**. See §3 — the repo source
`defaults/global/.claude/` does **not** change (it is the shipped default tree, copied
*into* the new dest).

---

## 1. Reading order

1. `../../foundation/design/guiding-principles.md` (**P1–P18**) — P2 (destination taxonomy), P18 (one config home; `~/.cco/projects/` future).
2. **This file.**
3. `decisions/0024-repo-multi-project-and-config-home.md` (the layout it refines) + `decisions/0026-cco-init-global-and-project-scaffold.md` (init global-ensure; the heaviest reference site).
4. `design.md` §2 (layout) + §12 / the RD notes on the future `~/.cco/projects/<name>/`.
5. `.claude/rules/documentation-lifecycle.md` (history vs living: ADRs forward-annotated, design rewritten) + `.claude/rules/workflow.md` + `.claude/rules/update-system.md` (migration rules).
6. The shipped code (§4) and the existing migration set `migrations/global/` (next free id = **015**).

**Precedence on conflict**: guiding-principles → ADRs (incl. the new 0028) → design → shipped docs.

---

## 2. The decision to record — ADR-0028

Write `decisions/0028-flatten-global-config-home.md` (status: accepted, date 2026-06-27).

- **Context**: `~/.cco` is the personal (global, user) config scope. Within it, `.claude/`
  was nested under `global/` (a carry-over from the central-vault layout
  `user-config/global/` vs `user-config/projects/`). After decentralization, per-project
  config lives in `<repo>/.cco/`, so `~/.cco` holds *only* global resources — yet the
  `global/` namespace is applied to `.claude/` alone (setup.sh / setup-build.sh /
  mcp-packages.txt / languages / packs/ / templates/ are already top-level; update
  base/meta live in STATE). The wrapper is redundant and misleading.
- **Decision**: flatten to `~/.cco/.claude/`. The future solo-adopter per-project
  centralization (Case-C, P18, ADR-0023 D4) becomes `~/.cco/projects/<name>/` — a clean
  sibling of `~/.cco/.claude/`, preserving the global-vs-per-project contrast without a
  redundant `global/` level for the global case.
- **Alternatives considered**: (a) keep `global/` and also move setup/mcp/languages under
  it for consistency — rejected (keeps a level the design doesn't need; `~/.cco` is already
  the scope); (b) defer to the `~/.cco/projects/` Case-C design — rejected for **timing**
  (must ship in the single v1 migration, else a second `mv` later).
- **Consequences**: breaking layout change; one idempotent migration; all readers/writers
  and docs updated; `defaults/global/.claude` source name unchanged (see §3 / §10-D1).
- **Supersedes**: the `~/.cco/global/.claude` placement in ADR-0024 and ADR-0026.
  **Forward-annotate** ADR-0024 and ADR-0026 (history — do not rewrite their bodies; add a
  back-pointer to ADR-0028).

---

## 3. CRITICAL distinction — what changes vs what does NOT

| Thing | Path | Change? |
|---|---|---|
| **User store destination** | `~/.cco/global/.claude/` | **→ `~/.cco/.claude/`** (this whole task) |
| **Repo source (shipped default)** | `defaults/global/.claude/` | **UNCHANGED** — it is copied *into* the new dest. (Optional cosmetic rename of the `defaults/global/` dir is a separate decision — see §10 D1; default = keep.) |
| **Container mount target** | `→ ~/.claude` in container | unchanged target; only the **host source** path changes |
| Setup/mcp/languages/packs/templates | `~/.cco/{setup.sh,setup-build.sh,mcp-packages.txt,languages,packs/,templates/}` | already top-level — **unchanged** |
| Update base/meta | STATE (`~/.local/state/cco/global/update/...`) | unchanged |

Every code/doc edit must touch the **dest** (`$GLOBAL_DIR/.claude` = `~/.cco/global/.claude`)
and leave `$DEFAULTS_DIR/global/.claude` (the source) alone.

---

## 4. Implementation checklist (code) — exhaustive, code-ground each (lines drift)

### 4.1 The variable

- `bin/cco:49` `GLOBAL_DIR="${CCO_GLOBAL_DIR:-$HOME/.cco/global}"` + comment `bin/cco:44`.
  Decision: **retire `GLOBAL_DIR`** and replace `$GLOBAL_DIR/.claude` everywhere with the
  flat global-claude dir. Recommended: add a resolver `_cco_global_claude_dir()` in
  `paths.sh` returning `$(_cco_config_dir)/.claude`, and use it (keeps one source of truth;
  avoids `GLOBAL_DIR == CONFIG_DIR` redundancy). Keep `CCO_GLOBAL_DIR` as an honored
  override only if tests still need it (see §7).

### 4.2 Readers of `$GLOBAL_DIR/.claude` (dest) — repoint to `~/.cco/.claude`

| File:line | Usage |
|---|---|
| `lib/cmd-start.sh:315` | `[[ -d "$GLOBAL_DIR/.claude" ]]` global-config branch |
| `lib/cmd-start.sh:322,324,345,346,348` | `$config_dir/global/.claude` checks + init-workspace-in-global warning text |
| `lib/cmd-start.sh:664` | `$config_global/.claude/mcp.json` |
| `lib/cmd-new.sh:75 (comment),136` | `$config_global/.claude/mcp.json` |
| `lib/utils.sh:72(comment),76` | `check_global`: `[[ ! -d "$GLOBAL_DIR/.claude" ]]` |
| `lib/secrets.sh:11(comment),136,156` | `global_dir="$GLOBAL_DIR"`; copies `settings.json` to `$global_dir/.claude/` |
| `lib/update.sh:90,155,170,208,217` | `installed_dir="$GLOBAL_DIR/.claude"`; policy transitions; reseed loop |
| `lib/update-hash-io.sh:223` | `_installed_dir="$GLOBAL_DIR/.claude"` |
| `lib/cmd-clean.sh:6(comment),111,114` | cleans `.bak`/`.new` under `$GLOBAL_DIR` (the global `.claude` tree) |
| `lib/cmd-update.sh:6(comment),140(comment)` | comments referencing `~/.cco/global` |
| `lib/cmd-build.sh:9` | comment "NOT under ~/.cco/global" — **becomes moot** after flatten; update it |
| `config/entrypoint.sh:114` | comment "global/.claude/mcp.json" (container reads mounted `~/.claude`; comment only) |
| `lib/update-merge.sh:264` | `$DEFAULTS_DIR/global/.claude/...` — **SOURCE, do NOT change** |

### 4.3 Writers of the dest — write to `~/.cco/.claude`

| File:line | Usage |
|---|---|
| `lib/cmd-init.sh:5,49,119,121 (comments)` | doc/comments: "~/.cco/global" |
| `lib/cmd-init.sh:126` | `gdir="$cfg/global"` → drop; write `.claude` to `$cfg/.claude` |
| `lib/cmd-init.sh:160-161` | `cp -r "$DEFAULTS_DIR/global/.claude" "$gdir/.claude"` → dest `$cfg/.claude` (source unchanged) |
| `lib/cmd-init.sh:200` | base source still `$DEFAULTS_DIR/global/.claude` (unchanged); base dir is STATE (unchanged) |
| `lib/migrate.sh:190-192,212-221` | `_cco_populate_global_from`: legacy `$src/global/.claude` → write to `$cfg/.claude` (NOT `$cfg/global/.claude`) — **the key migration write** |
| `lib/migrate.sh:243` | `legacy_meta="$src/global/.claude/.cco/meta"` (reads legacy source — unchanged) |
| `lib/migrate.sh:71-72,301,323,328,331,362` | idempotency/presence checks + messages on `$cfg/global/.claude` → `$cfg/.claude` |

### 4.4 The personal-store allowlist (NOT the repo .gitignore)

- `lib/cmd-config.sh:32` `_CONFIG_ALLOWLIST=( .gitignore packs templates global/.claude … )` → `.claude`.
- `lib/cmd-config.sh:52-53` the written `.gitignore` lines `!global/.claude/` + `!global/.claude/**` → `!.claude/` + `!.claude/**`.
  (Repo-root `.gitignore:5 /global/` and `:18 global/secrets.env` are **unrelated** dev-artifact ignores — leave.)

---

## 5. The migration (the heart of "one coherent migration")

`migrations/global/015_flatten_global_claude.sh` (id 015 — current max is 014; 008 is
already skipped). `MIGRATION_ID=15`, idempotent `migrate()`:

- If `~/.cco/global/.claude` exists and `~/.cco/.claude` does not → `mv` it; then
  `rmdir ~/.cco/global` if empty. If `~/.cco/.claude` already exists → no-op (return 0).
- Be defensive about a half-state (`.claude.tmp`, both present) — prefer the non-`global/`
  one or merge conservatively; never clobber a populated `~/.cco/.claude`.

Coordinate with the **two other entry points** so a user never needs a second move:
- **Fresh** (`cco init`, §4.3): writes straight to `~/.cco/.claude`.
- **Legacy vault** (`cco init --migrate` → `migrate.sh _cco_populate_global_from`, §4.3):
  restores legacy `global/.claude` straight to `~/.cco/.claude`.
- **Eager global** (`cco update`, ADR-0025): runs migration 015 for users who already have
  `~/.cco/global/.claude` from a pre-flatten dev build.

Keep the `global-migrated` marker idempotency gate (marker flag, not directory presence —
`migrate.sh:70-72`, `cmd-update.sh:140`); update the presence *checks* that look at
`$cfg/global/.claude` to `$cfg/.claude`.

**No changelog entry** (this is a structural move handled by a migration, per
`.claude/rules/update-system.md` — changelog is for additive features). Confirm the
whole-refactor migration story still rides correctly (memory: changelog #14).

---

## 6. Living design docs to rewrite (in place, no banners)

| Doc | refs | Note |
|---|---|---|
| `decisions/` **ADR-0028** | NEW | the decision (§2) |
| `design.md` §2 layout + mount + `.gitignore` allowlist | 3 | `~/.cco/.claude/`; show `projects/<name>/` as the future per-project sibling |
| `configuration/file-destinations/design/design-file-destinations.md` | check | CONFIG-bucket `~/.cco` member list: `global/.claude` → `.claude` |
| `configuration/scope-hierarchy/design/design-scope-hierarchy.md` | check | the User-level row host path |
| repo root `CLAUDE.md` | 13,19,29,103,107,131,159,174 | **dest** `~/.cco/global/.claude` → `~/.cco/.claude`; **leave** `defaults/global/.claude` source mentions |
| `maintainers/README.md`, `maintainers/configuration/README.md` | check | any layout mention |

## 7. Shipped-behavior (user) docs — repoint dest

All LIVING; mechanical `~/.cco/global/.claude` → `~/.cco/.claude`:
- `users/foundation/reference/context-hierarchy.md` (**21** — heaviest; the 4-tier tables)
- `users/environment/guides/custom-environment.md` (16)
- `users/reference/cli.md` (13)
- `users/integration/guides/subagents.md` (4) · `agent-teams.md` (2)
- `users/configuration/guides/project-setup.md` (3)
- `users/foundation/guides/installation.md` (2) · `concepts.md` (2) · `users/troubleshooting.md` (2)

## 8. History docs — forward-annotate only (do NOT rewrite)

ADRs/reviews keep their text (they record what was decided then). Add a one-line forward
pointer to ADR-0028 where a reader could be misled by the old layout:
- `decisions/0024-…` (2), `decisions/0026-…` (**15** — the init-global ADR), `0023`, `0027`.
- `foundation/adr/adr-0003/0006/0007/0008` (mention `~/.cco/global/.claude`) — annotate the layout line only.
- `reviews/*` and `roadmap-history.md` — frozen; **leave** (no annotation needed).
- decentralized-config living set that is *history-ish* (`resource-coherence-inventory.md`,
  `analysis-roadmap.md`, `spec.md` FRs): update the FR/inventory line if it states the
  layout as current; otherwise annotate.

## 9. Stale references left in related docs (the explicit ask)

After the rename these become stale and must be caught (a `grep -rn '\.cco/global' docs/`
should return only `archive/`, `roadmap-history.md`, and forward-annotated history):
- the `cmd-build.sh:9` comment ("NOT under ~/.cco/global") — now moot, reword.
- `pre-merge-fix-handoff.md` (1) and `documentation-reorganization-plan.md` (1) — transient;
  update or note as superseded.
- the roadmap **"Pre-merge to-do"** entry → flip to done + point at ADR-0028.
- re-run the repo-wide link/path checks from the docs reorg
  (`scratchpad` linkcheck pattern) to confirm no dangling `global/` paths in living docs.

## 10. Tests / fixtures

- `tests/helpers.sh:34-37,53,116-118`: `CCO_GLOBAL_DIR="$tmpdir/home/.cco/global"` and
  `setup_global_from_defaults` (copies to `$CCO_GLOBAL_DIR/.claude`). Decide (§10 D2): keep
  `CCO_GLOBAL_DIR` pointing at the flat `~/.cco/.claude`'s parent, or retire it and point
  fixtures at `$HOME/.cco/.claude`. Whatever the prod code reads must match.
- `tests/test_clean.sh` (~14 sites `$CCO_GLOBAL_DIR/.claude/...bak`), `tests/test_config.sh`
  (3 `$HOME/.cco/global/.claude` + the committed-file assertion `global/.claude/CLAUDE.md`),
  `tests/test_build.sh:25-28` (the `global/` **decoy** — keep as a legacy decoy or update
  to assert the flat layout).
- **Add** a migration test: legacy `~/.cco/global/.claude` → `~/.cco/.claude` (015,
  idempotent, no-op when already flat).
- Gate: `CCO_ALLOW_HOST_RESOLVE=1 ./bin/test` green (current baseline **908/0**).

## 11. Open decisions for the session (resolve with maintainer)

- **D1 — rename `defaults/global/` source dir too?** Default: **keep** (`defaults/global/`
  is a fine name for "the global defaults source"; dest naming ≠ source naming). Only
  rename if the maintainer wants full symmetry (then it is a tracked-tool-code move, not a
  user migration).
- **D2 — `GLOBAL_DIR` / `CCO_GLOBAL_DIR`**: retire entirely (recommended) vs keep
  `CCO_GLOBAL_DIR` as a test/override seam. Affects helpers.sh + any override docs.

## 12. Method

- Workflow phases (analysis already done = this handoff; design = ADR-0028; then implement).
  Atomic LOCAL commits per logical unit (ADR+design / code+migration / docs / tests).
- **Code-ground every site** (re-grep; the line numbers above will have drifted).
- Green per step (`./bin/test`). Final: `grep -rn '\.cco/global' bin lib config docs tests`
  returns only intentional residue (source `defaults/global`, `archive/`, frozen history).
- **Dogfood**: on a real install, put content at `~/.cco/global/.claude`, run `cco update`,
  confirm it lands at `~/.cco/.claude` once and `cco start` still loads it.

---

## 13. Reference paths

- Decision to record: `decisions/0028-flatten-global-config-home.md` (NEW)
- Superseded: `decisions/0024-…`, `decisions/0026-…`; design `design.md` §2
- Governing law: `../../foundation/design/guiding-principles.md` (P2, P18)
- Migration set: `migrations/global/` (next id 015); engine `lib/migrate.sh`, `lib/cmd-update.sh`
- Roadmap entry: `../../roadmap.md` → "Pre-merge to-do — flatten …"
- Rules: `.claude/rules/{workflow,update-system,documentation-lifecycle,git-workflow}.md`

---

*Generated with Claude Code*
