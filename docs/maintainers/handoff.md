# Handoff — 2026-08-13 (late)

> **Ephemeral.** At most one of these exists; the previous was deleted before this was written. It
> links **out** to the roadmap, ADRs and designs — nothing links back to it.

## Methodology / where we are

**Design and Plan are both DONE and both gates are passed.** The maintainer approved the design on
2026-08-13 and asked for the implementation to start in the next session.

**Phase for the next session: Implementation — and it starts at U1.** No gate is pending. Everything
U1 needs is decided; nothing in it is a judgement call left open.

The work is **A5 + A8** of [Block A → `0.7.0`](roadmap.md), designed jointly because they share one
interactive surface and one TTY contract.

- Branch **`feat/cli/start-warning-gate`**, 2 commits, **unpushed**. `develop` is level with
  `origin/develop` at `c93ea38` and owes the remote nothing. Working tree clean.
- Nothing is half-done. The two commits are the design artefact and the roadmap plan.

## How to resume

**1. Push, from the host** — the only owed action that cannot run in a session:

```
cd /Users/alessandro/Projects/CaveResistance/Software/claude-orchestrator
git push -u origin feat/cli/start-warning-gate
```

**2. Read the design before opening any editor** —
[design-warning-gate-and-onboarding-prompts.md](cli/design/design-warning-gate-and-onboarding-prompts.md).
Two sections are the build instructions: **§3.3** (the classification table — every site, with its
verdict) and **§4** (the mechanism). [ADR-0059](cli/decisions/0059-message-classification-and-the-start-warning-gate.md)
holds the *why* for anything that looks arbitrary. Do **not** start from `lib/cmd-start.sh` — U1 does
not touch it.

**3. Run `/implement U1`.** U1 is `lib/colors.sh` (the `note()` emitter + the capture buffer), the
reclassifications listed in design §3.3, and the two `INV-WG` lints in `tests/test_invariants.sh`.
It changes **nothing a user sees** — that is deliberate, and it is what makes U1 safe to land first.

**4. Respect the order U1 → U2 → U3.** Both edges are load-bearing and neither is taste:
- **U1 before U2** — the gate must not ship while a message that should not gate still can.
- **U1 before U3** — they both edit `lib/local-paths.sh:445,450`. U3 first means doing it twice.

**5. The oracle to build first is T3.** ⭐ *A `warn` emitted from inside `$( )` must reach the
buffer.* It is the one test that discriminates the shipped design from the obvious wrong one (a shell
array), and it must be driven **through `_prompt_for_path`**, not a synthetic subshell — a synthetic
one would pass against an implementation that fails in the real call path. The full 13-test plan is
design §6.

## Tasks

The [roadmap](roadmap.md) is the single source of truth for status; this list points at it.

- [ ] **Push `feat/cli/start-warning-gate`** — host-only (command block above)
- [ ] **[U1](roadmap.md) — capture + taxonomy** (A5). `note()`, the file-backed buffer, the
      reclassifications, the two lints. Verified by T1–T3, T7, T9, T11
- [ ] **[U2](roadmap.md) — the gate** (A5). The prompt in `_start_launch` + `cco new`. Verified by
      T4–T6, T8, T10 **and the live check**: a session whose agents keep no return channel must stop
      and show [ADR-0058 A2](integration/agent-teams/decisions/0058-teammate-coordination-tools.md#amendments)'s
      warning — the message shipped deliberately unread, one release early, for exactly this moment
- [ ] **[U3](roadmap.md) — the three surface fixes** (A8). `--writable` (+ `changelog.yml` + a line in
      [`cli.md`](../users/reference/cli.md)), the clone destination, the reuse tokens. Verified by
      T12–T13
- [ ] **[A1](roadmap.md)** — `cco save`, project-config versioning helper (needs a short design)
- [ ] **[A2](roadmap.md)** — per-project custom Docker image ([FI-49](improvements.md); short design)
- [ ] **[A3](roadmap.md)** — cross-scope collision warning ([FI-32](improvements.md)) + three open decisions
- [ ] **[A6](roadmap.md)** — `.claude/worktrees` in the functional-write floor ([FI-56](improvements.md))
- [ ] **[A7](roadmap.md)** — the A4 review residue ([FI-62](improvements.md) … [FI-66](improvements.md))
- [ ] **FI-58 leftovers** — ADR-0058's **D3**, **D7** and **D8-as-amended** are unbuilt. ⚠ D8 touches a
      **baked** file (`config/hooks/subagent-context.sh`), so whichever unit takes it also takes a
      `cco build` in its acceptance lane
- [ ] **macOS host suite (bash 3.2)** — last full run `1626 / 0` on the `v0.6.0` tree; **owed again**
      before the `0.7.0` release, since nothing has re-measured 3.2 since

Two items that had only ever lived in an ephemeral handoff were **moved into the roadmap this
session**, so they can no longer be lost: the [upstream documentation defect](roadmap.md) (the
`llms-full.txt:543` claim, measured false three times) and the [`acceptance/` taxonomy
question](roadmap.md) (now open decision #6).

## Context

### Decided this session

- **[ADR-0059](cli/decisions/0059-message-classification-and-the-start-warning-gate.md)** — D1…D15.
  Read the ADR, not this line. The three the maintainer ruled personally are **D9** (the gate covers
  `cco new` too), **D10** (bare Enter starts — `[S/a]`) and **D12** (`--writable` is added;
  `--readonly` stays as an explicit affirmation).
- **The one judgement call in the classification table was flagged and approved as written**:
  `lib/paths.sh:638` (*dev-sandbox active*) becomes a `note`, not a gating `warn`. Decided — do not
  re-open it because it looks odd.

### 🔑 Non-obvious things the next session would otherwise rediscover

- 🔑 **The capture buffer cannot be a shell array, and this is measured.** `_prompt_for_path` and
  `_resolve_disambiguate` are invoked inside `$( )` (`lib/local-paths.sh:474`, `:497`), so their
  `warn`s run in a **subshell** and an array append dies with it. The array version works everywhere
  *except* the interactive surface A8 is fixing, which is what makes it dangerous rather than merely
  wrong. Same class as the `die`-inside-`$( )` defect (FI-62).
- 🔑 **The buffer may not live in STATE/DATA/CACHE.** ADR-0047's **INV-S1** forbids code outside
  `lib/store.sh` from mutating *or predicating* a confined path, and a warning buffer does not justify
  a `store-op` crossing. `${TMPDIR:-/tmp}` with an `mktemp` **template** (`lib/sync-meta.sh:117` is the
  precedent — the bare `mktemp` form is not portable to BSD).
- ⚠ **`cco new` installs its own `EXIT` trap** (`lib/cmd-new.sh:75`), which **replaces** the sentinel
  trap armed at `bin/cco:14`. Buffer cleanup must be explicit, not built on an `EXIT` trap alone.
- 🔑 **`lib/secrets.sh:102` warns AFTER every other step of `cco start`** — it runs inside
  `_start_launch`. That single fact fixes the gate's placement (D7): a gate at the end of `cmd_start`
  would silently miss malformed `secrets.env` lines.
- 🔑 **`--writable` closes an asymmetry, it does not invent a capability.** `--mount <src>:rw` has
  expressed exactly this since ADR-0027 D2 (`_parse_user_mount_spec`). cco had two spellings of one
  concept and one of them could not say half of it.
- ⚠ **FI-68's original field report had its premise INVERTED** (*"the default is rw"*). The code
  defaults `readonly` to **`true`** (`lib/local-paths.sh:312`) and ADR-0049 §7 reasons from it. An
  implementer taking the report at face value would invert a shipped security default. The
  maintainer's own restatement, which is the narrow and correct one, is quoted in
  [FI-68](improvements.md) and in the roadmap's A8 entry.
- 📝 **`cco start` is host-only in a session**, so the prompt cannot be exercised end to end from
  in-container. What *can* be: source the lib modules and call the capture helpers and the lints
  directly — the pattern used to confirm the six roles before FI-58's live run.
- 📝 **No unit touches a baked file**, so **no `cco build`** enters the acceptance lane.
- 📝 **The FI-25 mask (`access: {claude: all}` in `.cco/project.yml`) is ON**, deliberately. Masked
  in-container figures are the `…/7` ones. Pin `--claude-access` explicitly for any A4-style
  measurement in this project.
- 📝 Three cosmetic defects are folded into U1 and are already in the table, so they need no
  rediscovery: `warn "⚠ …"` renders a **double** badge (`cmd-start.sh:3134`, `update-merge.sh:151`),
  and two conditions are each emitted as multiple `warn`s (`cmd-start.sh:1697-1699`, `:3223-3224`).

### Open questions needing a human

None block U1, U2 or U3. The six standing ones are listed in the roadmap's
[Open decisions](roadmap.md) — #6 (*ratify or retire the `acceptance/` docs leaf*) was added this
session.

## Reference documents

- [roadmap.md](roadmap.md) — the living SSOT for status and priorities; A5 carries the U1/U2/U3 table
- [improvements.md](improvements.md) — the `FI-*` tracker (`FI-1 … FI-71`); FI-55/68/69/70 are 🟡 Designed
- [ADR-0059](cli/decisions/0059-message-classification-and-the-start-warning-gate.md) — message
  classification and the start warning gate, D1…D15 **(produced this session)**
- [design-warning-gate-and-onboarding-prompts.md](cli/design/design-warning-gate-and-onboarding-prompts.md)
  — mechanism, classification table, test plan **(produced this session)**
- [ADR-0058](integration/agent-teams/decisions/0058-teammate-coordination-tools.md) — its A2 amendment
  is the warning U2's live check must surface
- [ADR-0047](configuration/agent-cco-access/decisions/0047-config-access-enforcement.md) — the
  privilege boundary; INV-S1 is why the buffer is not in STATE
- [ADR-0027](configuration/decentralized-config/decisions/0027-config-editor-builtin-and-edit-protection.md)
  — its **D2** (*reference mounts via a repeatable `--mount` flag, read-only by default*) is the
  precedent D12 restores symmetry with. ⚠ The title is about the config-editor built-in; D2 lives
  inside it anyway, which is why it is easy to miss
