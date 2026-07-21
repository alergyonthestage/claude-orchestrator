# The false-success class — codebase-wide audit

> **Raised**: 2026-07-21, while landing cycle-1.1 **S2** (`fix/config-access/e2e-v3-cycle1.1`).
> **Scope**: the whole `lib/` tree, all mutation families. **Status**: audit complete; remediation
> partly scoped into cycle-1.1 (**S2b**), remainder tracked as **FI-24**.
>
> This exists because the backlog convention (`roadmap-backlog.md`, header) requires re-deriving an
> item's real boundary before designing it — *"which related defects sit in the same neighbourhood —
> then design and fix them as one boundary-aware change."* S2b was raised as "~15 unchecked
> `_index_*` call sites". The boundary turned out to be much larger, and — more importantly — a
> different **shape** than assumed.

## 1. The class

> A state-mutating call whose failure status is not propagated, followed by an unconditional success
> announcement. The user sees `✓ <done>` and exit 0; the mutation did not happen, or half happened.

### Why this codebase is structurally exposed to it

`bin/cco:2` sets `set -euo pipefail`, but every verb dispatches as `cmd_foo "$@" || _cco_rc=$?`
(e.g. `bin/cco:661`). Placing a command in a `||` context **disables errexit for its entire call
tree**. So a failing `cp`, `mv`, `sed -i` or `git commit` deep inside a `cmd_*` body does not abort
the verb — execution continues to the success message. **Explicit `||` / `if !` propagation is the
only mechanism that works**, and it has to be present at every link in the chain.

## 2. The finding that changes the remediation shape

Several **primitives cannot report failure at all** — so adding a check at the call site is inert.
Three were verified by direct reading during this audit (the rest of the table in §3 is
inspection-level unless marked):

| Primitive | Defect | The guard it silently voids |
|---|---|---|
| `_remote_token_set` (`cmd-remote.sh:16-27`) | every mutation bare; the last statement is `if ! chmod …; then warn; fi`, which yields **0 on both paths** — so the function returns 0 unconditionally | `store.sh:370` `_remote_token_set "$new" "$tok" \|\| return 1` — **correctly written, structurally inert** |
| `_remote_token_remove` (`cmd-remote.sh:30-37`) | bare `mv`, then an explicit `return 0` | `cmd-remote.sh:295` `if ! _remote_token_remove` — correctly written, inert. A revocation reported complete while the credential is still on disk |
| `_yaml_rename_list_ref` (`rename.sh:66-72`) | `mv "$tmp" "$file"` then unconditional `return 0` | `rename.sh:230` `if _rename_yaml_write_owned …; then printf path; fi` — correctly written, inert for the `mv` failure (it does correctly catch "awk changed nothing") |

Also reported by the audit, inspection-level: `_sync_copy` (`cmd-sync.sh:100-107`) returns only the
**last** file's status, so a mid-loop failure reports success; `_meta_record_provenance`
(`update-meta.sh:16`) hard-`return 0`s.

**Remediation consequence.** Any fix must be **two-layered and in this order**:

1. make the primitive capable of failing;
2. then add/verify the call-site check.

Doing (2) first produces an audit that reads as closed while the defect persists — which is exactly
the state three call sites are in *today*.

## 3. Findings

Severity is consequence-weighted, not probability-weighted: the triggers are all uncommon
(unwritable tree, root-owned files after a container write or a `sudo cco`, `ENOSPC`, a missing git
identity), but the failure is silent in every case, so probability is the only thing keeping the
blast radius theoretical.

### 3.1 Damage escapes the machine (committed / pushed / shared remote)

| # | Site | Unchecked mutation | Announced as |
|---|---|---|---|
| **A1** | `update-merge.sh:138-156` `_resolve_with_merge` | `cp "$merge_out" "$installed_dir/$rel_path"` | `✓ $rel_path (conflicts resolved)` |
| **A2** | `update-sync.sh` ×13 | apply / add / `.new` `cp`s | `+ … (added)` / `~ … (updated)` |
| **A3** | `update-merge.sh:28-42` `_merge_file` | `cp "$tmpdir/current" "$output"` | returns 0 "clean merge" → `(auto-merged)` |
| **B1** | `cmd-pack.sh:1338`, `cmd-template.sh:1096` | bare `git commit -q` | `Published pack '<n>' to <url>` |
| **B2** | `cmd-pack.sh:1315-1317` | `rm -rf "$theirs_dir"` then bare `cp -R` | same |
| **B3** | `cmd-pack.sh:1174-1193` | per-file `cp` + unconditional `source:` strip | same |
| **C1** | `cmd-sync.sh:315-317` | `_sync_copy` + `_sync_record` | `synced from … -> …` **+ "commit the updated .cco/"** |
| **C6** | `cmd-config.sh:369,378` | `_cv_prune_record` (5 arms, none checked) | `Pruned N synced (DATA) orphan(s).` |
| **C7…C12** | `cmd-llms.sh:807,824` · `cmd-join.sh:164` · `cmd-project-add.sh:203` · `cmd-init.sh:334,385` · `rename.sh:68-69` · `cmd-project-rename.sh:116,126` | `_yml_append_coord` / `_yaml_rename_list_ref` / `_tags_rename` / `_sed_i` | various `ok` + a "commit + push" instruction |

**Three worth reading in full**, because each has a second-order effect that outlives the failure:

- **A1 — the post-condition check reads the file that failed to be written.** After the unguarded
  `cp`, the code greps the *target* for `<<<<<<<` markers. On a failed copy the target still holds
  the user's untouched original, which has no markers → the `else` branch fires and asserts
  `✓ conflicts resolved`. The check is **anti-correlated** with reality. Control then advances
  `.cco/base/`, so the next `cco update` classifies the file `USER_MODIFIED` and filters it out of
  the actionable count — **the framework update is permanently and silently suppressed**.
- **A2 — the evidence does not travel with the corruption.** `<repo>/.cco/claude/**` is committed
  and pushed; `~/.cco/.claude/**` goes out via `cco config push`. The `.cco/base/` state that would
  let a later run *detect* the divergence is machine-local STATE and is **not** synced. Note also
  that `cp` opens the target `O_TRUNC`: on a full disk the user's `CLAUDE.md` is **truncated to zero
  and then the copy fails**, while the tiny STATE base write still fits.
- **B1 — the `|| die` cannot fire.** `git commit` is bare; the guard is on `push`. If `commit` fails
  (unset `user.email` in a fresh container or CI, `commit.gpgsign` with no key, an inherited
  `pre-commit` hook, `ENOSPC` in `$TMPDIR`), HEAD never moves, so `push` exits **0** with
  "Everything up-to-date" and the guard is structurally unreachable. Execution then continues to
  `_record_pack_base`, recording the never-pushed tree as the merge ancestor — so the next publish
  sees `ours == base`, takes **theirs**, and silently drops the user's change from every subsequent
  publish. One green ✓ becomes permanent silent non-publication.

### 3.2 Local but destructive or credential-related

`C2`/`C3` the token primitives (§2) · `C4` `cmd-project-export-import.sh:195-196` (`rm -rf` then bare
`cp -R`) · `C5`/`B5` bare `tar czf` announced as a completed export (backup believed to exist) ·
`B4` `cmd-pack.sh:827/837/847`, `cmd-template.sh:585/600` (`rm -rf "$target_dir"` then bare `cp -r`)
· `B6` `cmd_pack_internalize` (count incremented regardless of per-file `cp` status) · `C13`/`C14`
`cmd-forget.sh:206-207,235` · `C15` `secrets.sh:155-156` · `C16` `migrate.sh:179` · `A4`/`A5`/`A6`
the update engine's remaining writes · `B7`…`B11`, `C17`, `C18` (lower).

### 3.3 Considered and dismissed — the correct patterns

Recording these matters as much as the findings: they show the fix is *local*, not a rewrite.

- **Everything routed through `lib/store.sh`** is rigorously fail-closed (`_store_apply` dies;
  INV-S3 "never a false ✓"). `pack remove`, `template remove/rename`, `remote add/remove` are
  correct **by architecture**.
- `lib/tags.sh:75,85` — `_tags_set` uses `die` on `mktemp`/`mv` failure. Fail-loud by a different
  mechanism than propagation, but genuinely fail-loud.
- `cmd-config.sh:102,127,147,157` (`config save/push/pull`) — every git op `|| die`-guarded,
  including line continuations. Exemplary.
- `local-paths.sh:133` (`if git clone …; then ok`), `cmd-project-coords.sh:232-238` (count reports
  real successes), `sync-meta.sh:122,136` (`{…} > "$tmpf" && mv`, tail-called), `update-meta.sh:108`
  (redirect is the tail command, status propagates to the caller's `if !`).
- Deliberate `|| true` on optional cleanup (`update-merge.sh:72,181`, `_cleanup_clone`) and
  read-only verdicts (`ok "Pack is valid"`) are out of class.
- `cmd-start.sh:1312` secret-mask creation: dismissed because a missing bind source makes `docker`
  fail loudly at session start — it cannot silently degrade.

## 4. Judgement

**Systemic, not confined to the index writers.** Two guarding disciplines coexist and the boundary
is architectural: anything crossing `lib/store.sh` is fail-closed with named invariants; anything
touching the CONFIG tree or the filesystem directly is guarded ad-hoc — correctly where a past
review pointed, and nowhere else. The same file often does both: `cmd_pack_create` guards its
`mkdir`/`cp` under an explicit comment but not the two `sed`s immediately after; `cmd_pack_rename`
guards its `mv` but not the `_sed_i` two lines later; `cco init` guards its final `mv` under a
comment promising atomicity that its staging `cp`s do not deliver.

The `_index_*` catalogue that started this is **one symptom of the pattern, not the pattern**.

**Not yet resolved statically** (needs a runtime check, do not assume either way): whether
`git merge-file` can exit 0 with a truncated `$output` on a full `/tmp` (A3's severity depends on
it), and `_generate_project_cco_meta`'s masking (`update-meta.sh:185-202`), which only manifests
when the six `prev_*` vars are empty.

## 5. What this changes for cycle-1.1

- **S2b is redefined** from "add checks to ~15 `_index_*` call sites" to a **two-layer** stage:
  primitives first, then call sites. See `../../configuration/agent-cco-access/e2e-review/fix-design-v3/00-plan.md` §3b.
- **S5 inherits a dependency**: D-V3-1 makes `remote remove|rename` host-only, but `store.sh:370`'s
  guard on `_remote_token_set` is inert **on the host too**. The token primitive must be fixed for
  the host path regardless of D-V3-1.
- **An honest limit on what S2/S3 shipped**: they closed the *index* half of `repo rename`. The
  *project.yml* half retains a narrower form of the same defect via `_yaml_rename_list_ref` (§2).
  S3's pre-flight mitigates the dominant cause (an unwritable tree) but probes only the **cwd unit's**
  `.cco` — so a multi-repo fan-out where a *different* member is unwritable, or an `ENOSPC`
  mid-write, still reports success for that repo. This is inside S2b's scope and is stated here
  rather than left implied by the S2/S3 commit messages.
- The remainder — the update engine (A1–A6), publish (B1–B3), and the local-destructive set — is
  **outside cycle-1.1** and tracked as **FI-24** in `roadmap-backlog.md`.
</content>
