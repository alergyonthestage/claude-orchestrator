# Handoff — **`v0.6.0` is released; cycle-1.2 is closed. Next is cycle-2, and it starts with an analysis.**

> **Ephemeral.** Delete this file before writing the next handoff. It links out only.
> Written 2026-08-04. Supersedes the handoff of 2026-08-03 (*"the release is BLOCKED"*) — that block
> is lifted: FI-46 is fixed, the host suite completed, and the release shipped.
> Status SSOT: [roadmap](roadmap.md).

## Where we are

Phase: **between cycles.** Cycle-1.2 is finished and released; cycle-2 has a fixed subject and has
not started.

- ✅ **`v0.6.0` published** (2026-08-04) — tagged from `main`, CI published to npm via OIDC.
- ✅ **All six gates G0…G6 are done.** The gates runbook is complete; nothing in it is pending.
- ⚠ **`develop` is 6 commits ahead of `origin/develop`** — post-release work (the `main` reconcile,
  the INV-B32 scope fix, these records). **Push from the Mac.**

**No gate and no decision is pending on my side.** What is pending is the maintainer's three open
calls (below) and the start of cycle-2.

## How to resume

1. **Push `develop`.** Nothing else is owed operationally.
2. **Start cycle-2 with the analysis, not the design** — the subject and its input are already
   written on the [roadmap](roadmap.md) (*"⏭ CYCLE-2 — config multiplicity, divergence awareness &
   mount topology"*). Start from
   [`analysis/config-mount-topology.md`](configuration/agent-cco-access/analysis/config-mount-topology.md)
   §3.3 and §8: four blockers and six open questions, already ground in the code.
   🔑 **The subject is wider than the mount topology, and the topology is downstream of it.** The
   prior question is that a session cannot *ask* how many config copies a project has or whether they
   diverge: `sync-meta` never crosses INV-STATE, so `_sync_is_divergent` always answers false and
   every owned member reports `synced`. The question is not badly answered — it is unaskable.
3. **The three open decisions** below are cycle-2 intake, not blockers.

## Open for the maintainer — none blocking

Each is recorded in full on the [roadmap](roadmap.md) / [backlog](improvements.md); this is the
index.

1. **180 latent bash-3.2 fixtures in `tests/`** — argument-position `"$(cat <<YAML` sites that parse
   today and abort the whole host suite the day one gains an apostrophe. Options: leave the two-arm
   INV-B32 as shipped · refactor in cycle-2 and tighten to one arm · make the **bash-3.2 parse sweep
   a gate**. ⚠ The sweep answers *"should the host suite be a gate?"* more cheaply but **not the same
   way**: it proves the suite is *readable* on 3.2, never that it *passes*.
2. **`cco init` has no `$HOME` guard** — it scaffolds `$PWD/.cco`, and in a home directory that is the
   personal store's own path. On a fresh machine the outcome is a confusing `refusing to clobber`,
   not corruption. A guard is a code change; deliberately not taken.
3. **`cco pack internalize` is documented twice** (§3.23 unified, §3.27 dedicated). The divergence is
   fixed (§3.27 was missing `--as`); merging the sections in a shipped reference is editorial.

## Context — what this cycle proved, beyond the release

- 🔑 **The container is NOT blind to bash 3.2.** The recorded premise was false: the Docker socket
  reaches the public `bash:3.2` image, so a real parse oracle exists in-session —
  `docker run --rm --name cc-<project>-b32 -v <host-repo>:/src bash:3.2 bash -n <file>`. ⚠ Two
  constraints: the proxy demands the `cc-<project>-` name prefix, and it **swallows container
  stdout** — read results from exit codes or a file written into the mounted repo. The narrower claim
  that survives is the one the cover rests on: the *suite's* interpreter is bash 5.2, so a
  behavioural regression test proves nothing.
- 🔑 **A green check that measured nothing is the cycle's signature failure, and it recurred twice.**
  The host log with `0 failed` and no `Results:` line was an abort. My own first subcommand-coverage
  check reported "no gaps" **because its extraction returned nothing**. **Prove a check's input is
  non-empty before believing its PASS.**
- 🔑 **A named list is a lower bound** — third instance. INV-B32 itself did not scan `scripts/`,
  where `scripts/release.sh` runs on the maintainer's macOS bash 3.2. Fixed post-tag; the tree was
  clean, so it was a guard gap, not a defect.
- ⚠ **The host and the container share one working tree.** A `git checkout` in-session pulled the
  fix out from under the maintainer's running host suite and produced a failure that was an artefact,
  not a datum. **Never switch branches while something is running on the host.**
- ⚠ **`git push` without `--follow-tags` leaves the tag behind**, and then `release.yml` never fires
  while `pages.yml` does. **The release workflow not firing is the signal that the tag never left.**
- ⚠ **The `develop → main` merge is host-only when its `.cco/` diff is non-empty** — a merge writes
  the working tree, and `.cco` is `:ro` at the default level. The fix is the designed knob, not a
  workaround: `--cco-access edit-project` mounts the current project's `.cco` rw.
- 📝 **The mask is now committed** (`access: {claude: all}` in `.cco/project.yml`, with its own expiry
  note pointing at FI-25). **Every in-container suite figure from now on is masked**: expect `…/7`,
  never `…/9`. The unmasked baseline for this tree is **1616/9 of 1625**.

## Reference documents

- [Roadmap](roadmap.md) — G0…G6 all ✅ · `0.6.0` released · **cycle-2 subject and inputs** ·
  [backlog](improvements.md) — FI-40/42/43 deferred to cycle-2, FI-46 resolved
- [Gates runbook](configuration/agent-cco-access/e2e-review/fix-design-v3.1/08-gates-to-release.md) —
  complete; keep as the template for the next release (it generalises)
- [Config mount topology analysis](configuration/agent-cco-access/analysis/config-mount-topology.md) —
  **cycle-2 starts here**, §3.3 and §8
- [G2 audit report](cli/reviews/2026-07-31-cli-surface-audit.md) and the living-docs sweep record on
  the roadmap — what the documentation surface has already been checked against
