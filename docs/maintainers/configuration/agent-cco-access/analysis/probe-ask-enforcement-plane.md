# Measurement — the `ask` enforcement plane under cco's launch conditions

**Historical record.** Run by the maintainer on the macOS host, **2026-08-05**, against a
purpose-built `claude-orchestrator:latest`. These four probes were the **preconditions** of
[ADR-0057](../decisions/0057-ask-enforcement-plane-and-resource-classes.md) — a negative P1 or P3
would have changed its D9 — and all four passed. Do not re-derive; cite.

The protocol lived at `scratchpad/probe-ask-plane/RUNBOOK.md` and is re-homed here because
`scratchpad/` is gitignored, and that is exactly how three pack-line inputs were nearly lost in the
previous cycle.

## Why these four, and not a suite run

Mount-time and permission-time behaviour are **invisible to the hermetic suite by construction** — the
dry-run compose tests assert emitted YAML and never execute it (RC-17, fourth recurrence). Everything
below therefore had to be measured in a real container, on the real image, under cco's own launch
conditions: `--dangerously-skip-permissions`, tmux TUI, managed settings baked at `/etc/claude-code/`.

Prior art this builds on, not repeated here: [FI-48](../../../improvements.md) measured on 2026-08-04
that an `ask` rule prompts under `bypassPermissions` in **headless** sessions at a **lower** layer.
The three variables it left open — managed layer, TUI, nested glob — are P2's subject.

⚠ Two properties of the setup that make the results meaningful, and would silently invalidate them if
changed: every target lived **inside the repo's own `rw` mount**, so mount mode was not a variable and
the committed `access: {claude: all}` mask (FI-25) was irrelevant; and each probe carried a **negative
control**, because a dialog that appears for everything proves nothing about the rule.

## P1 — the per-session overlay of the baked managed settings

**Question**: can a generated `managed-settings.json` be bind-mounted `:ro` over the baked
`/etc/claude-code/managed-settings.json`? **Gates** ADR-0057 D9 — the managed layer is the only one a
session cannot rewrite, so it is where cco's own rules must land.

```
$ docker run --rm --entrypoint cat \
    -v "$PWD/scratchpad/probe-ask-plane/overlay.json:/etc/claude-code/managed-settings.json:ro" \
    claude-orchestrator:latest /etc/claude-code/managed-settings.json
{"probe":"overlay-wins"}

$ docker run --rm --entrypoint cat \
    claude-orchestrator:latest /etc/claude-code/managed-settings.json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  ...
  "permissions": { "deny": [ "Read(~/.claude.json)", "Read(~/.ssh/*)" ] }
}
```

✅ **PASS, both arms.** The overlay wins; the control prints the real baked file, which is what proves
the first command measured the substitution rather than an empty or absent path.

## P2 — a managed `ask` under `bypassPermissions`, in the TUI, on a nested glob

**Question**: four at once — does the rule prompt at the **managed** layer, does `//workspace/**/CLAUDE.md`
match a **nested** file, does a non-matching sibling stay silent, and is a refusal honoured?
**Gates** D1 and D8.

Method: the rule was **baked** (added to `defaults/managed/managed-settings.json` + `cco build`), so
the measurement ran at the real layer rather than a simulated one. Targets were
`scratchpad/probe-ask-plane/nested/CLAUDE.md` (matches, and is nested — one target proves both) and
`.../nested/NOTES.md` (control). Session started with `cco new --repo …`, to avoid interfering with a
live session on the same project.

✅ **PASS, all four.** The dialog appeared for `CLAUDE.md` and **not** for `NOTES.md`; answering *no*
left the file unwritten.

## P3 — is a managed `ask` removable from below?

**Question**: does an `allow` for the same path in the user layer (`~/.cco/.claude/settings.json`,
which the session mounts `rw`) neutralise the managed `ask`? **Gates** D9 — and with it the layering
doctrine that lets cco compose with pack- and user-authored settings *through the platform's own
precedence* instead of merging them itself.

✅ **PASS** — *"the dialog still appears"*. Permission arrays merge upward and a lower layer cannot
remove a managed entry, as documented. cco's generated rules are therefore **not neutralisable by the
session that carries them**, which is also the property C2/FI-48 inherits.

## P4 — what an unanswered dialog does

**Question**: is there a timeout? **Gates** the user-docs wording for autonomy (D7) and the disposal of
alternative A7.

**Measured: it blocks.** No timeout, no self-resolution — the session waits. This confirms from the
opposite direction that **autonomy must be declared, never inferred** (cco cannot detect that nobody is
watching: the session runs a TUI on a pty either way), and that the declaration is what the shipped
presets already provide — `claude_access: none`, `repo`, `all`.

## What was cleaned up

The probe rule was un-baked (`git checkout -- defaults/managed/managed-settings.json` + `cco build`),
the user layer restored from its backup, and the probe files removed. Verified: the working tree shows
no diff under `defaults/`.
