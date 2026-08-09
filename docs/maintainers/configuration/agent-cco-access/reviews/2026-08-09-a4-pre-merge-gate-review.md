# Pre-merge gate review — A4 / ADR-0057, `feat/access/claude-md-axis`

**Historical record.** An independent `/review-implementation` pass over the whole A4 branch
(31 commits, `5924dab…62db1f0`, `develop..HEAD`), run as the **merge gate** into `develop` on
2026-08-09. It re-measures rather than re-reads: the suite was executed, the two fixes of the
[2026-08-08 implementation review](2026-08-08-a4-ask-plane-implementation-review.md) were re-verified
against the emitted compose, and every claim below was produced by running something.

Reference documents: [ADR-0057](../decisions/0057-ask-enforcement-plane-and-resource-classes.md)
(incl. Amendment A1), the living [design §4bis.1 + INV-P](../design.md),
[`docs/users/reference/cli.md`](../../../../users/reference/cli.md), and the
[acceptance results](../acceptance/0057-acceptance-results.md).

## Verdict

**Approve the merge into `develop`, with one REVIEW NEEDED raised as
[FI-67](../../../improvements.md) and gated before the `0.7.0` release.**

Nothing was fixed in place: no objective defect was found that is not already tracked. The one new
finding is a *decision the maintainer has never made*, so by the golden rule it is escalated rather
than patched — and it changes no code, only what three living documents may claim.

```mermaid
flowchart TD
  M["resolved matrix<br/>(tree × class)"] --> ME["mount emitter"]
  M --> PE["permissions emitter"]
  PE --> A["cell = ask ⇒ one rule"]
  PE --> R["cell = ro ⇒ NOTHING"]
  ME --> T1["`.claude` trees<br/>:ro is a real boundary"]
  ME --> T2["&lt;repo&gt;/**/CLAUDE.md<br/>unbounded — mount cannot reach"]
  R --> G["FI-67: ro on T2 is<br/>unenforceable as implemented"]
  T2 --> G
```

## Verification performed

| What | How | Result |
|---|---|---|
| Suite | `bin/test`, in-container, FI-25 mask ON | **1631 passed · 7 failed · 1638** — the `Results:` line is present, and the 7 are the known host-only set **name for name** (6 `test_as_*` + `test_paths_symlink_safe_tool_root`, [FI-19](../../../improvements.md)). Matches the 2026-08-08 figure exactly. |
| bash 3.2 parse | `bash:3.2` via the Docker socket, `bash -n` on the 5 changed shell files + `tests/helpers.sh` | all parse. **Negative control fired** (a planted heredoc-in-`$( )` returned rc 2), so the check measured something. |
| Fix 1 (`entries` reach) | `--dry-run --dump`, preset `repo` and `entries.claude_md=rw` | `~/.cco/.claude/CLAUDE.md` stays `:ro` in both. Holds. |
| Fix 2 (fail-closed rc) | the branch's own regression test, plus reading the call site | rc 3 = "no gate", every other non-zero reaches `_cco_exit`. Holds. |
| The FI-52 notice | `--cco-access edit-project` | fires, naming `current`; silent on a default session and on `none`. |
| The one-flag exit | `--claude-access entries.claude_md=rw` | no rule emitted, no prompt, global tree untouched. Behaves as documented. |
| `_claude_matrix_get "$m" <tree> '*'` | direct call | returns the **unclassified** row, not the first row. The `*` is safe because the RHS of `==` is **quoted** — a real hazard, correctly avoided. |

## Fixed in place

**None.** See the verdict: the single new finding is a decision, not a defect.

## REVIEW NEEDED

### `claude_access: none` does not lock `<repo>/**/CLAUDE.md` — [FI-67](../../../improvements.md)

**What was measured.** With `--claude-access none` on a project carrying `CLAUDE.md` at its repo root
and at `sub/`: no overlay file is generated, no `managed-settings.json` bind appears in the compose,
and `/workspace/<repo>` is bound with **no `:ro`**. Both files are therefore silently writable.

**Why the code is nonetheless faithful to the ADR.** D8 puts `<repo>/**/CLAUDE.md` on the
**permissions plane only** (the set is unbounded; enumeration cannot win). The permissions emitter's
sole input is `_claude_matrix_asks` — it emits for `ask` and nothing for `ro`. The ADR never decides
that `ro` should emit a `deny`. So `ro` on that one surface is unenforceable *as designed*, and the
implementation did not diverge; the decision has a hole in it.

**Why it must not merge silently.** A4's headline is that it closes the classification gap — *"one
class of file, one regime, wherever it lives"* — and three living documents now state that closure
without qualification:

- `cli.md`'s guarantee block: *"Prose governance (`CLAUDE.md`, `rules/`, `agents/`, `skills/`) is
  modifiable only through an explicit in-session human approval."*
- `cli.md`, `templates/project/base/project.yml`, `changelog.yml` #62: *"`none` (locked, zero
  prompts)"* and *"Every `CLAUDE.md` inside your repos — root and nested — … **It now prompts**."*
- The roadmap, the handoff and acceptance **check 4** all carry *"`none` is genuinely locked"*.

⚠ **Check 4 could not have caught this.** Its transcript measures `/workspace/.claude/CLAUDE.md` —
the one tree where the *mount* plane reaches, and therefore the one place `none` really is locked.
The repo-native surface that D8 was written for never entered the probe. This is the same shape as
the defect the 2026-08-08 review found: *the acceptance run measured the configuration the gap does
not live in.* Third recurrence of that class in this cycle; worth naming as such.

**Options are recorded in [FI-67](../../../improvements.md)** — emit a `deny` (a gate, not a
boundary: `dd`/interpreters still pass), reword the three claims to what holds, or both. All three
touch a user-perceivable guarantee, so all three are the maintainer's call.

## Remaining findings

### minor

- **INV-P's `REDERIVE` arm is blind to the class dimension.** The lint pattern is `claude_c[rpgo]` —
  the four *tree* axes. `claude_emd`/`claude_eru`/`claude_eag`/`claude_esk` are raw Axis-B inputs by
  the identical argument and are unguarded. The live tree is clean either way, so this is coverage,
  not a hole — and widening the pattern also flags the legitimate `CCO_CLAUDE_ENTRIES=` transport,
  which would need the exemption `CCO_CLAUDE_TRIPLE` already has. Recorded as **FI-63 item 3**,
  because it belongs to the same *"what the lint guards vs. what §5 publishes"* reconciliation.
- **`_claude_triple_preset` is fragile under `set -u` for a short tuple.** It forwards
  `_claude_matrix ${1:-} … ${8:-}` unquoted, so a caller passing a pre-joined string of fewer than
  eight fields leaves `_claude_matrix`'s `$5`…`$8` unbound and aborts the process rather than
  returning 1. No such caller exists today (every call site passes eight), which is why the suite is
  green. The comment above it advertises the two-shape flexibility without naming this edge.

### nit

- **`_emit_class_overlays`'s comment describes an unreachable direction.** It says a `:ro` child
  *"tightens one entry of a rw tree"*, but `max()` guarantees a class can never resolve below its
  tree, so that branch cannot fire. Harmless, and the comment reads as if it can.
- **ADR vs. changelog on rebuild** — unchanged from the 2026-08-08 review (`Requires cco build` vs.
  `No rebuild needed`). The changelog is right; the ADR line is design-time history. Still no action.

## Good practices worth repeating

- **The prior review's two fixes hold under independent re-measurement**, and both regression tests
  discriminate: the reach test carries a positive control (preset `repo` still grants the local
  trees) and the fail-closed test drives the CLI rather than the emitter, because the defect lived in
  the *call shape*. Neither would pass on a deleted assertion.
- **The residue was tracked before the branch was offered for merge.** FI-62…FI-66 were filed with
  their own analysis, their status honest (`latent, not live`; `a decision, not a defect`), and the
  roadmap entry states the suite figure, the mask caveat and *"do not run checks 1–3 on this project
  as it stands"*. A reviewer arriving cold could reconstruct the state without asking anyone.
- **`_claude_matrix_get` quotes the RHS of `==`.** A `*` sentinel compared against an unquoted
  pattern would have silently returned the first row of the tree — i.e. `claude_md`'s cell as the
  unclassified fallback, mounting the whole B2 tree `rw` in a default session. The quoting is
  correct, and it is the kind of one-character correctness that is invisible until it is wrong.
- **The FI-52 notice is tested for staying quiet, not only for firing.** Three silent shapes
  (default, `none`, no `ask` anywhere) are asserted alongside the two that fire. A notice that cried
  wolf would have been worse than none, and the test says so in its own comment.

## Follow-up

Uncommitted at the time of writing, for `/commit` to group:

1. `docs(access): record the A4 pre-merge gate review` — this file.
2. `docs(improvements): track FI-67, and FI-63's third item` — `docs/maintainers/improvements.md`.

No code, test or template file was modified by this review.
