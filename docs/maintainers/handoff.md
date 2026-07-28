# Handoff — verify S1's `Cp=rw` arm, then start S2

> **Ephemeral.** Delete this file before writing the next handoff. It links out only.
> Written 2026-07-28, end of cycle-1.2 **S1**.

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

### What actually needs rebuilding

**Nothing, most likely.** `cco start` runs on the **host** from your checkout, and `aa97b3b` only
changes `lib/cmd-start.sh` — host-side compose generation. The `Dockerfile` half (`d550da8`) is
already in the image you built (`cco whoami` → `image built from: fix/release/cycle-1.2@9ee07c2`).

⚠ **The real precondition is that the `cco` you invoke on the Mac is this branch's**, not a separately
installed copy — the npm-vs-checkout mixing that has confused two earlier sessions. Confirm before
reading anything into the result.

### The probe

Start on this branch with the access level raised explicitly (the `access:` block in
`.cco/project.yml` is currently commented out, so pass the flag):

```bash
cco start claude-orchestrator --claude-access all
```

Inside the session:

```bash
# 1. The save target must be the COMMITTED tree, rw — not the STATE overlay,
#    and not absent (absent is the bug: the view would swallow the save).
grep '/workspace/.claude/workflows' /proc/self/mountinfo
#    expect a source under <repo>/.cco/claude/workflows and NO 'ro,' flag

# 2. The directory exists in the repo
ls -ld /workspace/claude-orchestrator/.cco/claude/workflows

# 3. Write something there, then exit the session
echo '// probe' > /workspace/.claude/workflows/probe.js
```

Then **restart the session** and check `probe.js` is still there — that is the whole point, since the
old behaviour destroyed it at exactly this moment. `git status` in the repo should also show it as a
new untracked file, which is what "shared via git" means. Delete it afterwards.

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
