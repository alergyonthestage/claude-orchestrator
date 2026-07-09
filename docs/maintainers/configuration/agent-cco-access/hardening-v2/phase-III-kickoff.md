# Phase III kickoff — per-command fixes + built-in presets (Session 2)

> **Session-resume handoff.** Start here to run **S2 = Phase III + Phase IV** of hardening-v2
> in a fresh, dedicated-context session. S1 (Phase I model `(G,Pc,Po)` + Phase II privilege
> boundary) is **done + dogfooded on the Mac**; this session builds the per-command gating and
> the built-in-preset flips on top. **All bash — in-session verifiable via the suite; no image
> rebuild** (except possibly a baked preset default in Phase IV).
>
> **Master plan**: [`implementation-handoff.md`](implementation-handoff.md) (read §1 operating
> constraints + §5 Phase III + IV). **Contract/oracle**:
> [A1 command-scope matrix](../e2e-review/analysis/A1-command-scope-matrix.md) (the per-verb table
> + B1–B6) and [ADR-0046 §7](../decisions/0046-unified-cco-access-model.md) (read-visibility +
> write-authority tables). **Presets**:
> [ADR-0044](../decisions/0044-internal-builtin-presets-and-config-editor-scope.md) §2/§3.

---

## 1. Starting state (as of 2026-07-09)

- **Branch**: `feat/config-access/e2e-review` (continue here; **NOT pushed** — push both branches
  from the Mac). Latest work = the Phase II commits + doc-status updates.
- **Suite baseline**: `bash bin/test` → **1174 passed, 0 failed**. Never regress this.
- **S1 done**: Phase I `(G,Pc,Po)` model (commits `ec56f9f`→`274723e`); Phase II privilege
  boundary (`3d77c8d`→`81f191d` + dogfood fix `98de9b1`). The session access is the triple
  `(G,Pc,Po)`; the internal store (index/DATA/CACHE) is confined behind the `cco-svc` mode-0700
  root and reached only via the setuid helper, which re-execs store-touching verbs as
  **`cco __store <verb>`** elevated (the TRAMPOLINE — see below).
- **Pending from S1 (not this session)**: the maintainer check-in on the boundary (ADR-0047 §8
  Test B) and the helper-variant decision (`bash -p` vs setuid-root full-drop). These do not
  block Phase III (bash-only, per-command logic).

### The trampoline you are building on (read before touching the shim)

In a container-operator session, `bin/cco` classifies store-touching verbs
(`_cco_verb_touches_store`) and, for those, the outer (claude) cco `exec`s the setuid helper →
`cco __store <verb>` runs **elevated (cco-svc)**, and **`__store` RE-RUNS `_cco_operator_shim`
as the AUTHORITATIVE gate** using the `(G,Pc,Po)` triple the helper injected from the trusted
`:ro` descriptor `/etc/cco/session-access` (never the agent-mutable env). So: **your Phase III
gate changes in `_cco_operator_shim` run twice** — once in the outer claude cco (early UX check,
forgeable env) and once in the elevated `__store` (authoritative, trusted triple). Keep the gate
logic pure and env-driven so both give the same answer; the trusted one wins. Verbs you add to
gating that touch the store must also be in `_cco_verb_touches_store` (bin/cco) so they elevate.

## 2. What Phase III must do (A1 matrix — implementation-handoff §5 Phase III)

Atomic units (one commit each, suggested):

1. **Shim gate-by-resource-area.** Replace any remaining hardcoded level literals in
   `_cco_operator_shim` (`bin/cco`) with the target→axis derivation (A1 §3), keyed off the triple
   (`_cco_triple_write_satisfies` / the per-axis read gate already exist from Phase I). The
   environment-host class stays refused with the host hint.
2. **B5 — `tag add/remove` gated by the TAGGED resource's axis** (A1 §4.1): project(current)→`Pc=rw`,
   project(other)→`Po=rw`, pack/template→`G=rw`. Resolve kind + ownership **at the gate** (today
   inside `cmd_tag`, `lib/tags.sh`); make the ownership predicate **config-editor-aware** (current =
   `PROJECT_NAME` for normal sessions, the `CCO_CONFIG_TARGETS` set for config-editor — extend
   `_env_current_project`, `lib/access-scope.sh`). The DATA write already rides the helper (elevated).
   NOTE: `tag` is already in `_cco_verb_touches_store`; the gate currently uses `global` — replace
   with the per-target axis.
3. **`path list` scoping** (A1 §4.3): scope output like `list project` (current + referenced; host
   paths gated by `show_host_paths`); `path set` stays host-only. `path` (with `list`) is already in
   the trampoline classifier; add the OUTPUT scoping in the lister (`lib/paths.sh` / `lib/local-paths.sh`).
4. **B6 hint invariant** (A1 §4.2): after the refactor, assert **no silent exit-2** — every refusal
   states host-only or above-scope (naming the axis); exit-1 = unknown/error. Audit + a test.
5. **`whoami+`** (A1 §4.5): render the resolved **`(G,Pc,Po)` triple** per axis + the granular form
   + a **privilege-boundary note** (now that the boundary exists, `lib/cmd-whoami.sh`). `whoami` is
   env-only (NOT store-touching — do not add it to the trampoline classifier).

**Tests**: extend `test_operator_shim.sh` (gate-by-area, B6 no-silent-exit-2, path-list scoping),
`test_tag.sh` (B5 per-target: edit-project tags current project ✓; edit-global tags pack ✓ but other
project ✗; edit-all ✓), a `path list` scoping case, `test_whoami` for the triple render.

## 3. What Phase IV must do (ADR-0044 — implementation-handoff §5 Phase IV)

1. **tutorial → `read-all`** (`claude=none, cco=read-all, show_host_paths=on`); `--cco-access`
   available but discouraged (document).
2. **config-editor → min-privilege** (`_start_resolve_access` + `_start_collect_config_editor_targets`,
   `lib/cmd-start.sh`): cwd-in-project → `edit-project` (cwd project's `.cco` + `~/.cco`); outside a
   project → `edit-global` (`~/.cco` only); `--all`/`--cco-access edit-all` → `edit-all` (every
   project). Preserve `--project`/`--repo` targeting + the *started ≠ cwd* asymmetry (D9).

**Tests**: `test_start_decentralized.sh` / `test_access_resolution.sh` for the preset resolution +
the config-editor cwd-vs-`--all` matrix. **May need a rebuild** only if a baked preset default
changes (verify).

## 4. Critical constraints (read before touching code)

- **In-session verifiable.** Phase III is pure bash; the suite (`bin/test`, baseline **1174/0**) is
  the feedback loop. Phase IV is bash unless a baked default changes. No boundary rebuild needed.
- **Design-driven testing** (workflow rule): test against the **A1 matrix + ADR-0046 §7 tables**, not
  the implementation. When a test fails, question the code first — UNLESS the failure is a deliberate
  contract change (then update the test + say so in the commit, as Phase II did for the mount asserts).
- **Language**: respond in Italian; code/comments/docs in English. Atomic conventional commits on
  `feat/config-access/e2e-review`; push both branches from the Mac.
- **Shipped-behaviour docs** (repo `CLAUDE.md`, `cli.md`, guides) are the **DOC5 cutover = Phase VI
  (S3)** — do NOT rewrite them here. Living design docs are already reconciled.
- **Do NOT fix B-DF1 here unless asked** (in-container `cco project show` repo-resolution — backlog
  §"Dogfood-found bugs"); it is a separate pre-merge bug, may be folded into S3 or a dedicated fix.

## 5. Code baselines to load

- `bin/cco` `_cco_operator_shim` (the gate) + `_cco_verb_touches_store` (the trampoline classifier)
- `lib/access-scope.sh` — `_cco_triple_write_satisfies`, `_env_in_scope`, `_env_current_project`,
  `_env_require_visible` (make ownership config-editor-aware for B5)
- `lib/tags.sh` — `cmd_tag`, `_tags_detect_kind` (B5 gate + ownership)
- `lib/cmd-whoami.sh` — the render (whoami+ triple + boundary note)
- `lib/paths.sh` / `lib/local-paths.sh` — `path list` scoping
- `lib/cmd-start.sh` — `_start_resolve_access`, `_start_collect_config_editor_targets` (Phase IV presets)

## 6. After S2 (Phase III + IV)

→ **S3** (Phase V running registry ADR-0045 + B1–B4; Phase VI migrations + changelog + **DOC5
shipped-doc cutover** + `cco build`) → **e2e v2** (acceptance). See
[`implementation-handoff.md`](implementation-handoff.md) §4/§5. Flip the backlog/roadmap rows as
each phase lands.
