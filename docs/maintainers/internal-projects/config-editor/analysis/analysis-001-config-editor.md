# Config-Editor Project — Analysis

> **Status**: accepted (2026-06-23)

**Scope**: Built-in, agentic configuration-editing session for claude-orchestrator
**Prerequisite reading**: [ADR-0027](../../../configuration/decentralized-config/decisions/0027-config-editor-builtin-and-edit-protection.md) · sibling [design](../design/design-config-editor.md) · the [tutorial analysis](../../tutorial/analysis/analysis-001-tutorial.md) (contrast)

> This is an append-only analysis record. Later decisions are forward-annotated,
> not rewritten (see `.claude/rules/documentation-lifecycle.md`).

---

## 1. Problem Statement

The tutorial (`cco start tutorial`) is a deliberately **read-only** teacher: it
mounts the personal store `~/.cco` read-only and the framework docs read-only,
explains concepts, and instructs the user to run `cco …` commands on the host.
It intentionally cannot modify configuration.

That leaves a gap. Users frequently want an *agentic, hands-on* partner to
actually **create and edit** configuration — author a knowledge pack, scaffold a
template, refine global rules/skills/agents, or tidy a project's committed
`<repo>/.cco/` — rather than only being told how. Before this work the only path
for agent-assisted authoring was either:

- the tutorial with its `~/.cco` mount flipped to read-write (an ad-hoc,
  undocumented `project.yml` edit), or
- a scaffolded `config-editor` **template** instantiated with
  `cco project create --template config-editor`.

Both paths were removed or invalidated by the decentralized-config refactor:
`cco project create` and `cco init --template` were deleted (ADR-0026), and a
committed `project.yml` may never carry a real host path such as `~/.cco`
(AD3/G8). A first-class, **built-in** editing session was needed.

### 1.1 Why a built-in (vs a scaffolded project)

| Property | Built-in (chosen) | Scaffolded template |
|---|---|---|
| Always current with the framework | Yes — refreshed from `internal/config-editor/` every start | No — drifts, needs update tracking |
| Committed host path for `~/.cco` | None — injected at runtime | Would violate AD3/G8 |
| Entry verb | `cco start config-editor` (reserved name) | needs `--template`, deleted in ADR-0026 |
| Appears in `cco list` | No (framework-internal) | Yes (user project) |

The **tutorial is the precedent**: it is already a reserved name materialized at
runtime from `internal/tutorial/`, never scaffolded or committed. Config-editor
reuses that exact code path.

### 1.2 Contrast with the tutorial

| Aspect | tutorial | config-editor |
|---|---|---|
| Purpose | Teach / explain / onboard | Create / edit configuration |
| `~/.cco` mount | **read-only** | **read-write** |
| Posture | Teacher, no autonomous writes | Configuration assistant, writes with approval |
| Curriculum | 14 modules, `/tutorial` skill | none — task-driven |
| Skills | `/tutorial`, `/setup-project`, `/setup-pack` | `/setup-project`, `/setup-pack` |
| Behavior rule | `tutorial-behavior.md` | `config-safety.md` |
| Edit-protection exemption | yes (`is_internal`) | yes (`is_internal`) |

### 1.3 Non-goals

- **Not a code-development session**: it edits configuration, not application code.
  Code work happens in normal `cco start <project>` sessions.
- **Not a `cco` runner**: the `cco` CLI is host-only and cannot run inside the
  container (same constraint as the tutorial). The session edits files; the user
  runs `cco config save` / `cco pack validate` / etc. on the host.
- **Not a replacement for the host IDE**: the host filesystem stays fully editable;
  this is one more authoring surface, not the only one.

---

## 2. Requirements

| # | Requirement |
|---|---|
| R1 | Launchable as a reserved built-in: `cco start config-editor`, no scaffolding, no entry in `cco list`. |
| R2 | Read-write access to the personal store `~/.cco` (global `.claude/`, `packs/`, `templates/`, top-level `setup*.sh` / `mcp-packages.txt`). |
| R3 | Read-only access to the framework documentation for accurate, current guidance. |
| R4 | Optional **project mode**: also mount a chosen project's committed `<repo>/.cco/` read-write for editing. |
| R5 | No real host path written into any committed file (AD3/G8) — host paths injected at runtime only. |
| R6 | Assisted authoring via wizards for packs and projects (`/setup-pack`, `/setup-project`). |
| R7 | Safety posture: explain before changing, confirm destructive ops, never write real secrets, surface the exact host `cco` command to activate changes. |
| R8 | Exempt from the agentic edit-protection guardrail (it is the *sanctioned* editing path). |

---

## 3. Constraints

### 3.1 Read-write `~/.cco`, but internal buckets excluded

Editing the personal store is the whole point, so `~/.cco` is mounted **rw**.
However, cco-internal, machine-local data — the STATE index, `tags.yml`, the
remotes registry, caches, and transcripts — lives **outside** `~/.cco` in hidden
XDG buckets (STATE/CACHE/DATA) and is **not** mounted. It is managed only via
`cco …` and must never be hand-edited (P6 — internal state centralizes). This
keeps the rw surface to genuinely user-owned config.

### 3.2 Edit-protection per ADR-0027 D3

The decentralized model places a project's `<repo>/.cco/` **inside** the user's
code repo, which a *normal* `cco start` session mounts read-write. That created a
new exposure: a code-working agent could involuntarily mutate `project.yml`,
`secrets.env`, or `.cco/` metadata. ADR-0027 D3 closes it with a narrow,
container-only `:ro` overlay on the structural framework config in normal
sessions.

The constraint for config-editor: it must be **exempt** from that guardrail so it
can actually edit configuration. Grounded in `lib/cmd-start.sh` — the overlay is
suppressed when `is_internal` is true (or the explicit `--enable-config-edit`
escape hatch is passed). Config-editor sets `is_internal=true`, so its `~/.cco`
and any project-mode `<repo>/.cco` stay rw by construction.

### 3.3 `cco` CLI is host-only

Identical to the tutorial: `bin/cco` resolves host paths and generates
`docker-compose.yml`; it cannot execute inside the container. The session writes
files; the user activates them with host commands (`cco config save`, `cco config
push`, `cco pack validate`, `cco start`, …). The CLAUDE.md and `config-safety.md`
rule both restate this.

### 3.4 No `manifest.yml` — structure-based sharing (ADR-0012)

The personal store has no central manifest. Packs and templates are discovered by
directory structure, and sharing happens through a dedicated **sharing repo**
(`cco pack publish` / `cco pack install`, `cco template publish` / `cco template
install`) — never by publishing the personal store itself. The session's guidance
must reflect this model.

---

## 4. Options Considered

| # | Option | Verdict |
|---|---|---|
| O1 | A dedicated `cco config edit` verb | Rejected — adds CLI surface the design §8 deliberately avoided. |
| O2 | Keep a scaffolded `config-editor` template | Rejected — no `--template` on `cco init` (ADR-0026); a committed `~/.cco` mount violates AD3/G8. |
| O3 | Drop config-editor for v1 | Rejected — UX regression; loses the assisted authoring agent named in design §7/§10. |
| O4 | Flip the tutorial's `~/.cco` mount to rw on demand | Rejected — overloads the read-only teacher; conflates teaching with editing; undocumented `project.yml` surgery. |
| **O5** | **Built-in session (the tutorial model), rw `~/.cco`, two modes** | **Chosen** — see Decision. |

---

## 5. Decision

Implement config-editor as a **framework-internal, non-scaffolded built-in**,
mirroring the tutorial code path (ADR-0027 D1):

1. **Reserved name** `config-editor` added to `RESERVED_PROJECT_NAMES`
   (`lib/utils.sh`). `cco start config-editor` launches the built-in, blocked only
   if a real project claims the name (same guard as the tutorial).
2. **Runtime materialization** by `_setup_internal_config_editor`
   (`lib/cmd-start.sh`): content refreshed from `internal/config-editor/.claude`
   every start; `project.yml` **generated at runtime**, never committed.
3. **Two modes**:
   - **Global** (default, `cco start config-editor`): mount `~/.cco` rw +
     framework docs ro.
   - **Project** (`cco start config-editor --project <name>`, or launched from a
     cwd that hosts/belongs to a configured repo): additionally mount that
     project's `<repo>/.cco` rw, resolved via the STATE index.
4. **Host paths injected at runtime** through an in-process session mount override
   (not the persistent index), so AD3/G8 hold and the user's index is not polluted
   (review H4).
5. **Exempt from edit-protection** via `is_internal=true`.

This is the only path that satisfies R1–R8 without new CLI surface, without an
update-tracked template, and without committing a host path.

See the [design](../design/design-config-editor.md) for the realized mount
structure, generated `project.yml`, behavior rules, skills, and session flow.

---

## 6. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Agent writes a real secret into a committed file | High | `config-safety.md`: never write secret values; only `*.example` skeletons are committed; `secrets.env` is gitignored and host-edited. |
| Destructive edit (overwrite/delete) without consent | Medium | Behavior rule: explain first, show the diff before overwriting, require explicit confirmation for delete. |
| User edits internal state expecting it to take effect | Medium | Internal buckets are not mounted; doc states they are managed only via `cco …`. |
| Changes not persisted/versioned | Low | Session reminds the user to run `cco config save` (and `cco config push`) on the host after edits. |
| Reserved-name collision with a real project | Low | Launch is blocked with a clear rename instruction (mirrors the tutorial guard). |

---

## 7. Dependencies

- The tutorial built-in code path (`_setup_internal_*`, reserved-name handling) —
  reused, not reinvented.
- ADR-0027 (built-in model + edit-protection), ADR-0026 (`cco init` single entry,
  `cco project create` deleted), ADR-0012 (no manifest), ADR-0008/0010
  (`~/.cco` personal store, authoring = direct `~/.cco` edit).
- The STATE index resolution (`_resolve_unit_dir_for_project`,
  `_resolve_find_unit_dir`) for project mode.
