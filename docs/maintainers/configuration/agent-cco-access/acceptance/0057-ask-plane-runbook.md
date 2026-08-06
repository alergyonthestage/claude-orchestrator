# Acceptance runbook — ADR-0057, the `ask` enforcement plane (A4)

**Purpose**: run the six post-implementation checks in
[ADR-0057 § Verification](../decisions/0057-ask-enforcement-plane-and-resource-classes.md).
**Status when written**: A4 implemented on `feat/access/claude-md-axis` (`b324c0e` … `5eeafdf`),
suite 1626/7 of 1633 with zero regressions, **acceptance not started**.

> **Why a runbook at all.** Suite-green is *not* acceptance for this lane: mount-time and
> permission-time behaviour are invisible to the hermetic suite by construction (RC-17, fourth
> recurrence — the dry-run compose tests assert emitted YAML and never execute it). Everything
> below either executes a real container or asks a human to answer a real dialog.

---

## 0. Two things to get right before the first command

### 0.1 `cco build` is NOT a prerequisite (correcting the ADR)

ADR-0057's Consequences say *"Requires `cco build`"*. **Measured 2026-08-05: it does not.**
`git diff develop..HEAD` touches no image-baked file — `Dockerfile`, `config/`, `defaults/` and
`proxy/` are all untouched. Both planes are produced **at start time, host-side, by `./bin/cco`**:
mount composition in `_start_generate_compose`, and the permissions overlay in
`_emit_managed_settings_overlay`, whose content is read from the repo's own
`defaults/managed/managed-settings.json`.

One consequence survives, and it is why every command below says `./bin/cco`: the `cco` on the
container's `PATH` is the **image-baked** build and does not contain this work. Inside a session,
always call `/workspace/claude-orchestrator/bin/cco`.

A rebuild is harmless and removes any doubt about which code is running. It is optional here.

### 0.2 ⚠ The FI-25 mask makes checks 1–3 measure nothing

`claude-orchestrator/.cco/project.yml` commits `access: {claude: all}` (the FI-25 self-dev
workaround). Under it every tree resolves `rw`, so `max()` absorbs `ask`, **no permission rule is
emitted at all**, and `/workspace/.claude/CLAUDE.md` is writable for a reason that has nothing to do
with A4. Checks 1–3 would then pass while proving nothing — the "green check that measured nothing"
failure this project has already paid for twice in one cycle.

**Every command below therefore passes `--claude-access` explicitly.** The axes are stated not to
change the model but to pin the shape independently of what the project file happens to say.
`repo=ro,current=ro,global=ro,others=ro` is exactly what a normal `read-project` session derives.

---

## 1. What is delegated, and what needs you

| # | ADR check | Where it runs | Who |
|---|---|---|---|
| 1 | `/workspace/.claude/CLAUDE.md` is mounted `rw` | live container | **you** start it, then S1 (agent) reads `/proc/self/mountinfo` |
| 2 | a nested `<repo>/**/CLAUDE.md` prompts; a sibling `.md` does not | live container | **you** — a permission dialog is answered by a human, by definition |
| 3 | `<repo>/.cco/claude/rules/*` refused at OS level, no prompt | live container | S1 (agent) — an `EROFS` needs no human |
| 4 | `--claude-access none`: no prompt, no write, every class | live container | **you** start it, then S2 (agent) |
| 5 | config-editor: no prompt on any class of its target | live container | **you** start it, then S3 (agent) |
| 6 | `cco whoami` reports the matrix, both dimensions | live container | S1 (agent) |

**Pre-flight (already done in-session, no container needed)**: the emitted compose and the generated
overlay were verified for four session shapes by dry-run — see §5. That covers *what cco decides*.
This runbook covers *what the kernel and Claude Code then do about it*, which is the part no dry-run
can reach.

---

## 2. Host session A — the default shape (checks 1, 2, 3, 6)

Run on the **host**, from the repo root:

```bash
cd /Users/alessandro/Projects/CaveResistance/Software/claude-orchestrator
./bin/cco start claude-orchestrator \
    --claude-access repo=ro,current=ro,global=ro,others=ro
```

Expect on stderr, before the session opens — this is itself the first signal:

```
Access:  claude=repo=ro,current=ro,global=ro,others=ro,entries.claude_md=ask cco=read-project host-paths=true
```

If `claude=` reads `all`, the mask won this round: stop, and re-read §0.2.

### 2.1 Paste this to the session's agent (checks 1, 3, 6)

> Run these three and report each result verbatim, as fact. Do not fix anything.
>
> ```bash
> # 1 — the CLAUDE.md mount must be rw, inside a .claude that is ro
> grep -E '/workspace/\.claude(/CLAUDE\.md)? ' /proc/self/mountinfo | sed 's/.*rw,/rw,/;s/.*ro,/ro,/' 
> grep '/workspace/.claude/CLAUDE.md' /proc/self/mountinfo
>
> # 3 — the rules tree must refuse at OS level, with NO dialog
> echo x >> /workspace/.claude/rules/*.md ; echo "exit=$?"
>
> # 6 — both dimensions reported
> /workspace/claude-orchestrator/bin/cco whoami
> ```
>
> For check 1 I need the mount **flags**, not just the line: `rw` on
> `/workspace/.claude/CLAUDE.md` and `ro` on `/workspace/.claude`.
> For check 3 report whether a permission dialog appeared **before** the error. It must not: this is
> the mount plane, and the mount plane never prompts.
> For check 6 report whether the output carries a `claude entries:` line and a
> `Resolved cells that differ from their tree` block naming `CLAUDE.md`.

**Check 1 passes** when `/workspace/.claude` is `ro` and `/workspace/.claude/CLAUDE.md` is `rw`.
Both halves matter: the `rw` alone would also be produced by the mask.

**Check 3 passes** when the write fails with a read-only-filesystem error and **no dialog appeared**.

**Check 6 passes** when `whoami` prints `claude entries: claude_md=ask …` plus the differing-cells
block listing `repo CLAUDE.md ask` and `current CLAUDE.md ask`.

### 2.2 Check 2 — yours, because it is a dialog

In the same session, ask the agent to make these two edits, one at a time:

1. `echo "note" >> /workspace/claude-orchestrator/docs/CLAUDE.md` — using the **Edit tool**, not Bash
   (⚠ see the trap below).
2. the same on a sibling that is *not* a `CLAUDE.md`, e.g. `docs/README.md`.

| Expected | |
|---|---|
| edit 1 | a permission dialog appears. **Answer no** — then confirm the file is unchanged (`git diff`). |
| edit 2 | **no dialog**, the edit just happens. |

⚠ **The trap that makes this check lie.** The rule is `Edit(//workspace/**/CLAUDE.md)`. It covers the
built-in modifying tools and the file commands Claude Code recognises in Bash (`sed -i`, `echo >`,
`printf >`) — but **`dd`, `truncate` and any interpreter pass straight through** (measured, FI-48).
If you drive the edit through one of those, no dialog is *supposed* to appear, and a silent success
proves nothing. Drive it through the Edit tool.

⚠ **An unanswered dialog blocks forever** — no timeout, no self-resolution (measured, P4). That is
the designed behaviour, not a hang.

---

## 3. Host session B — locked (check 4)

```bash
./bin/cco start claude-orchestrator --claude-access none
```

Paste to the session's agent:

> ```bash
> ls -l /etc/claude-code/managed-settings.json
> grep -c 'workspace/\*\*/CLAUDE.md' /etc/claude-code/managed-settings.json || echo "no rule (expected)"
> grep '/workspace/.claude' /proc/self/mountinfo
> echo x >> /workspace/.claude/CLAUDE.md ; echo "exit=$?"
> ```
> Report each verbatim. Then try to edit `/workspace/.claude/CLAUDE.md` **through the Edit tool** and
> say whether a dialog appeared and whether the write succeeded.

**Check 4 passes** when: no `ask` rule is present, `/workspace/.claude` and its `CLAUDE.md` are both
`ro`, the write fails at OS level, and **no dialog** appears. `none` is the declared-autonomy preset —
the whole point is zero prompts.

---

## 4. Host session C — config-editor (check 5)

```bash
./bin/cco start config-editor --project claude-orchestrator
```

Paste to the session's agent:

> ```bash
> ls /etc/claude-code/managed-settings.json
> grep -c 'CLAUDE.md' /etc/claude-code/managed-settings.json || echo "no rule"
> /workspace/claude-orchestrator/bin/cco whoami
> ```
> Then edit the target project's `CLAUDE.md` **and** one of its `rules/*.md`, through the Edit tool,
> and report whether either prompted.

**Check 5 passes** when neither prompts. config-editor derives `Cp=rw` for its target, so by D3's
`max()` every class resolves `rw` there and `ask` never appears — its whole purpose is deliberate
authoring, and a prompt on every file would be pure friction.

⚠ A dialog *may* legitimately appear for a `CLAUDE.md` inside a **mounted code repo** (the `repo`
tree, which config-editor mounts to read code, not to author config). That is not check 5 — check 5
is about the *target project's* config tree. Report it separately if you see it.

---

## 5. Pre-flight results (in-session, 2026-08-06)

Six session shapes were driven through `cco start --dry-run --dump` on a scratch project (unmasked,
carrying a `.cco/claude/CLAUDE.md`, `rules/`, `agents/`, `skills/` and a repo with its own
`.claude/CLAUDE.md`), and the emitted compose + generated overlay were read verbatim. This settles
what cco **decides**; §§2–4 still have to settle what the kernel and Claude Code then **do**.

| Shape | `/workspace/.claude` | its `CLAUDE.md` | its `rules` | `~/.claude/CLAUDE.md` | overlay |
|---|---|---|---|---|---|
| **A** default `(ro,ro,ro,ro)` | `:ro` | **rw** | `:ro` | `:ro` | yes |
| **B** `none` | `:ro` | `:ro` | `:ro` | `:ro` | **no** |
| **C** `all` | rw | rw | rw | rw | **no** |
| **E** default + `entries.rules=ask` | `:ro` | **rw** | **rw** | `:ro` | yes |
| **F** `current=rw` | **rw** | rw | rw | `:ro` | yes ⚠ |
| **D** config-editor `--project` | rw (built-in tree) | rw | — | `:ro` | yes ⚠ |

Emitted `permissions.ask`, verbatim:

- **A**, **D**, **F** — `["Edit(//workspace/**/CLAUDE.md)"]`
- **E** — `["Edit(//workspace/**/.claude/rules/**)","Edit(//workspace/**/CLAUDE.md)","Edit(//workspace/.claude/rules/**)"]`
- **B**, **C** — no overlay generated, no bind emitted; the baked file stands untouched

In every generated overlay the baked content survived the substitution — the `session-context.sh`
hook and the `Read(~/.ssh/*)` deny are both present — and **no `Write(` path rule** was emitted
anywhere (that syntax is accepted by Claude Code and never consulted; FI-48 already paid for it).

Also confirmed in shape A: the repo tree behaves the same way — `<repo>/.claude` binds `:ro` with
`<repo>/.claude/CLAUDE.md` punched through it rw. And in **A** and **B** alike the global tree's
`CLAUDE.md` stays `:ro`, which is D5's clamp working on the default path.

### 🔴 What the pre-flight found — read before running §§2–4

Shapes **F** and **D** are marked ⚠ because the rule **out-reaches the matrix that produced it**:
`/workspace/.claude` is mounted `rw`, and the same session emits a glob that gates it. This is
[FI-52](../../../improvements.md), a conflict between ADR-0057's own D3/D5 and D8 — not an
implementation slip.

**Consequence for this runbook: check 5 is expected to FAIL as written.** Run it anyway and record
what you see; do not "fix" it in the session. Checks 1–4 and 6 are unaffected.

---

## 6. Recording the outcome

- All six pass → mark A4 accepted on the [roadmap](../../../roadmap.md), merge
  `feat/access/claude-md-axis` into `develop` (host-side: the merge writes the working tree and
  `.cco` is `:ro` at the default access level — use `--cco-access edit-project`), and push.
- Any check fails → **do not** merge. Record which check, its verbatim output, and whether it failed
  or merely *measured nothing* — those are different outcomes and only one of them is a defect.
