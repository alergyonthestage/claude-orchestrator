# Handoff — verify S1's `Cp=rw` arm, then start S2

> **Ephemeral.** Delete this file before writing the next handoff. It links out only.
> Written 2026-07-28, end of cycle-1.2 **S1**.
>
> ✅ **The probe half of this handoff is CONSUMED (2026-07-28).** The `Cp=rw` arm passed across a
> real restart, and two of §7's three "not observed" items closed with it; the output is in the
> runbook's acceptance log (§7, second block) and **S1 is accepted**. What remains live below is
> only *"Then: S2"* and the open items. Do not re-run the probe from this file.

## Where things stand

Branch **`fix/release/cycle-1.2`** off `develop` (which is level with `origin/develop`).
**14 commits, nothing pushed.** Suite **1551 passed / 9 failed of 1560**.

S1 (lane L3 — **R-D** + **R-F**) is implemented, probed and reviewed:
[ADR-0055](environment/decisions/0055-claude-runtime-state-and-mountpoint-ancestry.md) ·
runbook [`fix-design-v3.1/00-plan.md`](configuration/agent-cco-access/e2e-review/fix-design-v3.1/00-plan.md)
(§3 is S1, §7 holds the acceptance log) · [roadmap](roadmap.md) §B2-next lane L3.

**The 9 failures are environmental, not regressions.** Seven are the long-standing host-only set;
the other two (`test_update_new_file_added`, `test_update_dry_run`) write into
`defaults/global/.claude/rules/`, which is tracked *and* mounted `:ro` whenever `Cr=ro`. They pass
only when the `.claude` trees are writable — which is why the number recorded earlier in the cycle
(1549/7) was wrong: it was measured with `access: {claude: all}` active. **Any suite figure from a
self-dev session must state whether that block was on.**

## The one thing to verify

`/review-implementation` found that under **`Cp=rw` *and* composing** (i.e. any project that adopts a
pack, which is the everyday shape here), a workflow Claude Code saved landed in the CACHE view — and
`cco start` rebuilds that view with `rm -rf`, so the save was **destroyed at the next start**, not
merely session-local. Fixed in `aa97b3b` by materialising `workflows/` in the committed tree and
binding it back rw.

**That fix landed after the container probe was recorded** (`c8549fa`), so it is the only unprobed
arm. The probe itself ran at `Cp=ro` and none of its assertions are invalidated — those code paths
are untouched.

### No rebuild needed

`cco start` runs on the **host** from the checkout, and `aa97b3b` only changes `lib/cmd-start.sh` —
host-side compose generation. The `Dockerfile` half (`d550da8`) is already in the built image
(`cco whoami` → `image built from: fix/release/cycle-1.2@9ee07c2`).

### Why the probe needs `claude_access: all`, when the point of S1 was the opposite

Worth stating plainly, because it reads backwards at first. S1 has two arms:

- **`Cp=ro`** (the default) — the agent **could not save at all**: `/workspace/.claude/workflows/` was
  `:ro`. That is R-F, it is fixed by the STATE overlay, and **the probe already confirmed it.**
- **`Cp=rw`** — the agent could always save; the defect was *where the save landed*. With a pack
  adopted, the parent is the CACHE view, which `cco start` rebuilds with `rm -rf`, so the file was
  **destroyed at the next start**. That is the review finding, fixed by `aa97b3b`, unprobed.

So the raised access level is not something the fix requires — it is simply the only configuration in
which the unverified code path runs.

**The `access: {claude: all}` block is restored in `.cco/project.yml`**, so the next session is
already `Cp=rw` and no CLI flag is needed. Note the side effect: daily sessions no longer exercise the
default lane, and `test_update_new_file_added` / `test_update_dry_run` will pass again — so suite
figures taken from them are the masked ones.

### The probe — who runs what

**The session agent runs every check below.** The human is needed for exactly one thing: `cco start` /
the restart, because container-spawning verbs are refused in-session by design (the privilege
boundary), not out of convenience.

Agent, at the start of the session:

```bash
# 1. The save target must be the COMMITTED tree, rw — not the STATE overlay, and
#    not absent (absent IS the bug: the view would swallow the save).
grep '/workspace/.claude/workflows' /proc/self/mountinfo
#    expect a source under <repo>/.cco/claude/workflows and no 'ro,' flag
# 2. The directory exists in the repo
ls -ld /workspace/claude-orchestrator/.cco/claude/workflows
# 3. Leave a marker, and confirm git sees it as a new untracked file —
#    that is what "shared via git" means in changelog #52
echo '// probe' > /workspace/.claude/workflows/probe.js
```

Then **ask the human to restart the session** — that restart *is* the test, because the old behaviour
destroyed the file at exactly that moment. On the way back in, the agent checks `probe.js` survived
and deletes it.

### Two blind spots worth closing in the same sitting

Both are recorded in §7 of the runbook as *not observed*, and both are cheap now:

- **Cross-restart persistence of a non-`-workspace` key.** Start a subagent or teammate from inside
  `/workspace/claude-orchestrator`, restart, and confirm its key under `~/.claude/projects/` survived.
  The first probe only proved the key could be *created*.
- **D7 composing with no packs at all.** Needs a project that references none; only a unit test covers
  that arm today.

### After the probe

Paste the output into the acceptance log in §7 of the runbook and flip S1's row. If anything fails,
the fix belongs in this branch before S2 — S1 is not accepted until this arm is green.

## Then: S2

**S2 is design-only and ends at a human gate.** It must precede S3 and S4, which implement its ADR.
Brief in §4 of the runbook. One ADR covering both halves of the availability model, because they meet
in the same renderer: `project show`'s `[unresolved]` marker answers *"the index did not tell me a
path"* and prints it as *"no path is bound"*.

Read first: `consolidated-review-v3.1.md` §3/§4/§6 · `invariant-gap-audit.md` §2 · ADR-0043 ·
ADR-0047 §INV-S6 · `lib/access-scope.sh` · `lib/index.sh:104-180`.

⚠ The runbook warns that the W4 report's diagnosis of **R-B is wrong** and says why — packs *are*
wired into the scope layer; the real cause is that at `G=none` the store is not mounted, so the
enumeration loop never iterates. **You cannot count what you cannot enumerate.**

## Open items this session deliberately did not close

- **[FI-37](roadmap-backlog.md)** — the repo lane (`<repo>/.claude`, axis `Cr`) has no workflow-save
  path. INV-FLOOR was scoped to say so rather than left promising more than the code keeps; the
  usability gap is real and has three options weighed in the backlog entry.
- **[FI-38](roadmap-backlog.md)** — workflows-overlay hygiene: a stub outliving its committed entry,
  and a save/commit collision resolved silently.
- **Host-side**: `git push` of this branch, and the merge into `develop`, are yours (FI-20 — merges
  touching `.cco` are host-only).
