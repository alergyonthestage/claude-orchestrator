# Handoff — 2026-08-18

> **Ephemeral.** At most one of these exists per line of work; the previous was deleted before this
> was written. It links **out** to the roadmap, ADRs and designs — nothing links back to it.

## Methodology / where we are

**Phase: Implementation.** [A5](roadmap.md) is **done and host-accepted**; **U3 (= all of
[A8](roadmap.md)) is the next unit**, and it is unblocked.

Three units landed this session on branch `feat/cli/start-warning-gate`:
**U1** (taxonomy + capture buffer + two lints), **U2** (the gate itself), and **U4** (the output
model, which the first host run made necessary). Suite **1683 passed / 7 failed of 1690** — the 7 are
the [known host-only set](roadmap.md), unchanged name for name. Working tree clean, 16 commits ahead
of `develop`.

### Gates still open

| Gate | What unblocks it |
|---|---|
| **Push `feat/cli/start-warning-gate`** (16 commits, never pushed) | host-only — the command is under *How to resume* |
| **[D19] Reclassify every `warn` producer** | one dedicated session; the maintainer asked for it explicitly **before this cycle merges**. See *Tasks* |
| **Merge `feat/cli/start-warning-gate` → `develop`** | D19 done, U3 done, and a human sign-off. ⚠ The branch is **not merged** — the work is reachable from this ref and nothing else |
| **macOS host suite (bash 3.2)** | owed before `0.7.0`; nothing has run the full suite on 3.2 since `v0.6.0` |
| **One undecided UX residue** | see *Open questions* — not blocking, and the current behaviour is defensible |

## How to resume

**1. Push, from the host** — the only owed action that cannot run inside a session:

```
cd /Users/alessandro/Projects/CaveResistance/Software/claude-orchestrator
git push -u origin feat/cli/start-warning-gate
```

**2. Decide the order.** Two things are owed on this branch and they are independent:

- **`/implement U3`** — [A8](roadmap.md)'s three surface fixes. Everything it needs is decided; read
  [design §5](cli/design/design-warning-gate-and-onboarding-prompts.md) (the three fixes) and
  [ADR-0059](cli/decisions/0059-message-classification-and-the-start-warning-gate.md) D12/D13/D14.
  ⚠ **FI-68's field report has its premise INVERTED** — it claims the default is `rw`; the code
  defaults `readonly` to **`true`** (`lib/local-paths.sh:312`) and that default is **not in scope**.
  An implementer taking the report at face value inverts a shipped security default.
- **D19, the reclassification** — a dedicated analysis session, described in *Tasks*.

Either order works. U3 is the smaller, fully-specified one.

**3. Do not re-derive the TTY contract.** U3 touches the same prompts the gate lives beside.
`_cco_have_tty` (`lib/utils.sh`) is the single interactivity spelling, enforced by
`test_invariant_tty_gate_single_spelling`. A raw `/dev/tty` probe hangs the suite silently.

## Tasks

The [roadmap](roadmap.md) is the single source of truth for status; this list points at it.

- [ ] **Push `feat/cli/start-warning-gate`** — host-only (command above)
- [ ] **[U3](roadmap.md) — A8's three surface fixes.** `--writable` (D12) + a `changelog.yml` entry +
      a line in [`cli.md`](../users/reference/cli.md); the clone destination (D13); the reuse tokens
      (D14). Verified by T12–T13 of [design §6](cli/design/design-warning-gate-and-onboarding-prompts.md)
- [ ] **[D19](roadmap.md) — reclassify every `warn` producer** before the cycle merges. Run §3.2's
      decision tree over **every** producer reachable from `cco start` / `cco new`, enumerating them
      by **running the command**, never by reading a list. The §3.3 audit covered **12 of the ~36
      files that call `warn`**. Two questions it must answer: are ADR-0008's *non-blocking reminders*
      (`lib/reminders.sh`) meant to gate, and does `lib/llms.sh` belong at the `warn` level
- [ ] **Merge to `develop`** once U3 and D19 are done — the human review point
- [ ] **[A1](roadmap.md)** — `cco save`, project-config versioning helper (needs a short design)
- [ ] **[A2](roadmap.md)** — per-project custom Docker image ([FI-49](improvements.md); short design)
- [ ] **[A3](roadmap.md)** — cross-scope collision warning ([FI-32](improvements.md)) + three open decisions
- [ ] **[A6](roadmap.md)** — `.claude/worktrees` in the functional-write floor ([FI-56](improvements.md))
- [ ] **[A7](roadmap.md)** — the A4 review residue ([FI-62](improvements.md) … [FI-66](improvements.md))
- [ ] **FI-58 leftovers** — ADR-0058's **D3**, **D7** and **D8-as-amended** are unbuilt. ⚠ D8 touches a
      **baked** file (`config/hooks/subagent-context.sh`), so whichever unit takes it also takes a
      `cco build` in its acceptance lane
- [ ] **macOS host suite (bash 3.2)** — last full run `1626 / 0` on the `v0.6.0` tree; **owed again**
      before the `0.7.0` release

## Context

### Decided this session

- **[ADR-0059 Amendment A1](cli/decisions/0059-message-classification-and-the-start-warning-gate.md#amendments)**
  (D16…D19 + §A2), ruled by the maintainer on the evidence of the first host run. Read the ADR, not
  this line. In one sentence each: aggregate the loop producers (D16); group the list by an area
  **derived** from the producing file (D17); print each warning **exactly once** (D18); the
  agent-teams *widened* notice becomes a `note` (§A2); the full reclassification is scheduled (D19).
- **[ADR-0058 A3](integration/agent-teams/decisions/0058-teammate-coordination-tools.md#amendments)**
  — the forward annotation §A2 requires. A2's central claim is recorded as **discharged**: the
  warning it shipped deliberately unread *was read*, at the gate, on 2026-08-18.
- **Repainting the terminal was considered and rejected** for the double-print problem, with reasons
  in D18. Do not re-open it.

### Open questions needing a human

- 📝 **An unrecognised answer at the gate starts the session** (only `a`/`A` aborts). D10 decided bare
  Enter and `[S/a]`; it did not decide what a stray `n` does. Starting is D10's own reasoning applied
  consistently — *confiscating a session the user asked for is the worse error* — but a re-prompt
  loop is a one-line change and a UX call. **Not blocking.**
- 📝 **[Open decision #7](roadmap.md)** — should `cco clean` sweep `$TMPDIR/cco-warn.*`? The design
  claimed `cco clean --tmp` already did; it does not, and the claim is corrected in
  [design §4.2](cli/design/design-warning-gate-and-onboarding-prompts.md). Adding the sweep is a
  user-visible change to that verb, so it was not folded in silently.
- The five older ones are in the roadmap's [Open decisions](roadmap.md).

### 🔑 Non-obvious things the next session would otherwise rediscover

- 🔑 **Deferral is conditional on the append succeeding, and that is the invariant.** `warn` reads
  `_cco_warn_capture_append`'s status: buffer unwritable → it prints immediately, exactly as before.
  Without that one status check, a broken capture would destroy the messages the mechanism exists to
  deliver. Do not "simplify" it into an unconditional defer.
- 🔑 **The area is DERIVED from `${BASH_SOURCE[1]}`**, read inside `warn`'s own frame, and it is
  correct inside a command substitution too (measured). The file→area table in `lib/colors.sh` is a
  maintained list and is admissible **only because** a missing file costs a *label* (falls to
  `other`), never the warning. A *gating* list would cost the guarantee — which is why there is none.
- 🔑 **T3's driver is not what the design first named.** D4 removes every `warn` from
  `_prompt_for_path`, so the ⭐ subshell test drives `$(_parse_bool …)` via `_effective_extra_mounts`
  instead. D5 is untouched. Measured: against a shell-array buffer that one test fails while every
  other test in the file passes. [design §6.1](cli/design/design-warning-gate-and-onboarding-prompts.md).
- 🔑 **The gate's placement is asserted STATICALLY, and that is the honest choice** — under
  `CCO_NONINTERACTIVE=1` a misplaced gate and a correct one are indistinguishable, because neither
  prompts. All three placement oracles were measured against the wrong implementation they name.
  ⚠ The line-locator **skips comment lines**: `_start_launch`'s own comment names `docker compose
  run` several lines before the call, and without that a correct order read as a violation.
- 🔑 **A pty makes the prompt testable by hand**:
  `printf 'a\n' | script -qec <driver-script> /dev/null`. Deliberately **not** in the suite — BSD
  `script` takes different arguments, and a pty test invites the capture-hang class.
- 🔑 **The in-container bash-3.2 lane loses STDOUT** (the docker socket proxy): only the **exit code**
  comes back, and the container name must start with `cc-claude-orchestrator-`. Encode each verdict
  in a distinct exit code **and** plant a hostile file in the same run, or it is a green check that
  measured nothing.
- ⚠ **A negative control was rescued from a silent false pass** this session:
  `test_cross_tree_no_collision_no_warn` grepped for the absence of `"collides with pack"`, a string
  D16 reworded. It was green while matching text the code can no longer emit. When a message changes,
  grep the suite for the old wording.
- 📝 `cco start` and `cco new` are **host-only in a session**, so the gate cannot be exercised end to
  end from in-container. What can: source the lib modules and drive the capture, the renderer and the
  lints directly.
- 📝 **No unit touches a baked file**, so **no `cco build`** is in the acceptance lane.
- 📝 **The FI-25 mask (`access: {claude: all}` in `.cco/project.yml`) is ON**, deliberately. Masked
  in-container figures are the `…/7` ones. Pin `--claude-access` explicitly for any A4-style
  measurement in this project.

## Reference documents

- [roadmap.md](roadmap.md) — the living SSOT for status and priorities; A5 carries the U1…U4 table
- [improvements.md](improvements.md) — the `FI-*` tracker
- [ADR-0059](cli/decisions/0059-message-classification-and-the-start-warning-gate.md) — message
  classification and the start warning gate: D1…D15 **+ Amendment A1 (D16…D19)** *(A1 produced this session)*
- [design-warning-gate-and-onboarding-prompts.md](cli/design/design-warning-gate-and-onboarding-prompts.md)
  — mechanism, classification table, test plan; **§4.5** the output model as built, **§6.1** T3's
  driver, **§6.2** what the suite cannot reach + the passed host checks, **§6.3** what the live run found
- [ADR-0058](integration/agent-teams/decisions/0058-teammate-coordination-tools.md) — **A3** is the
  forward annotation added this session
- [ADR-0047](configuration/agent-cco-access/decisions/0047-config-access-enforcement.md) — INV-S1 is
  why the capture buffer is not in STATE
- [ADR-0027](configuration/decentralized-config/decisions/0027-config-editor-builtin-and-edit-protection.md)
  — its **D2** is the precedent U3's `--writable` restores symmetry with
