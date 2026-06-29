# User-Facing Messages Audit: `cco update` System

**Scope:** `lib/update.sh`, `lib/cmd-update.sh`, `lib/cmd-project.sh`
**Focus:** All text shown to users in `cco update`, `cco update --diff`, `cco update --sync`
**Date:** 2026-03-18
**Note:** Discovery summary and diff header messages were rewritten after this audit
(commit `532158b`). The messages inventoried below reflect the pre-fix state. See
`18-03-2026-update-ux-findings.md` for the resolution status.

---

## 1. DISCOVERY SUMMARY MESSAGES

**Function:** `_show_discovery_summary()` (update.sh:1089-1123)
**Invoked in:** Default `cco update` mode (discovery)
**Output:** Count of files by status with explanatory text

### Summary Status Counts
Generated after scanning all files. Shows count + internal status code + explanation.

| Status Code | Display Text | File Location | Line | Notes |
|---|---|---|---|---|
| `UPDATE_AVAILABLE` | `{N} file(s) can be auto-applied (UPDATE_AVAILABLE)` | update.sh | 1115 | Framework updated, user hasn't modified |
| `MERGE_AVAILABLE` | `{N} file(s) need merge (MERGE_AVAILABLE)` | update.sh | 1116 | Both user and framework changed |
| `NEW` | `{N} new file(s) available (NEW)` | update.sh | 1117 | File exists in defaults but not installed |
| `REMOVED` | `{N} file(s) removed from defaults (REMOVED)` | update.sh | 1118 | File was in .cco/base/ but no longer in framework |
| `BASE_MISSING` | `{N} file(s) with missing base (BASE_MISSING)` | update.sh | 1119 | **Uses jargon — "base" unexplained** |
| `DELETED_UPDATED` | `{N} file(s) you deleted have framework updates (DELETED_UPDATED)` | update.sh | 1120 | User deleted file; framework has new version |

### Summary Footer
```
Run 'cco update --diff' for details, 'cco update --sync' to merge.
```
**Location:** update.sh:1122
**UX Issue:** Uses internal term "merge" — not all users understand this.

### Example Output
```
  Global: opinionated updates available:
  1 file(s) can be auto-applied (UPDATE_AVAILABLE)
  2 file(s) with missing base (BASE_MISSING)
  1 new file(s) available (NEW)

Run 'cco update --diff' for details, 'cco update --sync' to merge.
```

---

## 2. DIFF OUTPUT MESSAGES

**Function:** `_show_file_diffs()` (update.sh:1129-1223)
**Invoked in:** `cco update --diff` and `cco update --diff <scope>`
**Output:** Per-file header + unified diff

### Per-File Headers
Each file shows a header describing why it's being shown, then a unified diff.

| Status | Header Format | File:Line | Context |
|---|---|---|---|
| `NEW` | `{scope}: {path} (new framework file)` | update.sh:1146 | — |
| `UPDATE_AVAILABLE` / `SAFE_UPDATE` | `{scope}: {path} (framework updated, you haven't modified)` | update.sh:1156 | Shows: your version → new default |
| `BASE_MISSING` | `{scope}: {path} (update available, base missing)` | update.sh:1165 | **Uses "base" jargon** |
| `MERGE_AVAILABLE` / `CONFLICT` | `{scope}: {path} (both modified — merge needed)` | update.sh:1186 | Shows TWO diffs: framework changes + your changes |
| `REMOVED` | `{scope}: {path} (removed from framework defaults)` | update.sh:1203 | No diff shown; just notification |
| `DELETED_UPDATED` | `{scope}: {path} (you deleted this file, but framework has updates)` | update.sh:1208 | Shows framework changes since deletion |

### Diff Sub-Headers (for MERGE_AVAILABLE)
When both user and framework have changed, shows two sub-diffs:

```
  --- framework changes (base → new):
  --- your changes (base → current):
```
**Location:** update.sh:1188, 1192

### Example Diff Output
```
Global: .claude/rules/language.md (framework updated, you haven't modified)
  --- your version
  +++ new default
  @@ -1,3 +1,5 @@
  +# New language rules
  ...
```

---

## 3. SYNC INTERACTIVE PROMPTS

**Function:** `_interactive_sync()` (update.sh:1229-1558)
**Invoked in:** `cco update --sync` / `cco update --sync <scope>`
**Output:** Per-file prompt + choices

### NEW Files
**Prompt Text:**
```
{scope}: {path} (new framework file)
  (A)dd file  (S)kip
```
**Location:** update.sh:1251-1252
**Default:** `A` (add)

**User Responses:**
- `A/add/replace` → adds file, updates `.cco/base/`, updates manifest
  - Success message: `✓ {path} (added)` (ok, update.sh:1266)
- `s/skip` → defers decision
  - Message: `Skipped {path}` (info, update.sh:1271)

---

### UPDATE_AVAILABLE / SAFE_UPDATE
**Prompt Text:**
```
{scope}: {path} (framework updated, you haven't modified)
  (A)pply update  (S)kip  (D)iff
```
**Location:** update.sh:1281-1282
**Default:** `A` (apply)

**Supports `(D)iff`:** Shows diff, then re-prompts:
```
  (A)pply update  (S)kip [A/s]:
```
**Location:** update.sh:1294

**User Responses:**
- `A/apply/replace` → applies update, creates `.bak` if needed
  - Success message: `~ {path} (updated)` (ok, update.sh:1309)
- `k/keep` → keeps user file but updates `.cco/base/`
  - Message: `Kept user version of {path}` (info, update.sh:1317)
- `s/skip` → defers decision
  - Message: `Skipped {path}` (info, update.sh:1322)

---

### BASE_MISSING
**Prompt Text (TTY):**
```
{scope}: {path} (framework has updates, no baseline to compare)
  (N)ew-file (.new)  (A)pply update  (K)eep yours  (S)kip  (D)iff
  Tip: (N) saves framework version as .new for manual review — recommended if you customized this file
```
**Location:** update.sh:1339-1341
**Default:** `N` (new-file)

**Non-TTY behavior:** Automatically skips (no interactive prompt)
**Location:** update.sh:1334-1336

**Supports `(D)iff`:** Shows diff, then re-prompts with same options
**Location:** update.sh:1347-1356

**User Responses:**
- `N/new` → saves framework version as `.{path}.new`
  - Success message: `~ {path} → saved framework version as {path}.new` (ok, update.sh:1365)
  - Hint: `Review .new and integrate changes manually, then delete the .new file` (info, update.sh:1366)
- `A/apply/replace` → applies update, creates `.bak` if needed
  - Success message: `~ {path} (updated)` (ok, update.sh:1377)
- `K/keep` → keeps user file but updates `.cco/base/`
  - Message: `Kept user version of {path}` (info, update.sh:1385)
- `s/skip` → defers decision
  - Message: `Skipped {path}` (info, update.sh:1390)

---

### MERGE_AVAILABLE / CONFLICT
**Prompt Text:**
```
{scope}: {path} (both modified — merge needed)
  (M)erge 3-way  (N)ew-file (.new)  (R)eplace + .bak  (K)eep yours  (S)kip  (D)iff
  Tip: use (N) if you restructured this file — saves framework version as .new for manual review
```
**Location:** update.sh:1400-1402
**Default:** `M` (merge)

**Supports `(D)iff`:** Shows both framework changes and your changes, then re-prompts with same options
**Location:** update.sh:1409-1427

**User Responses:**
- `M/merge` → attempts 3-way merge (git merge-file)
  - If clean: `✓ {path} (auto-merged)` (ok, somewhere in merge code)
  - If conflicts: `⚠ {path} written with conflict markers` (warn, update.sh:1462)
    - Then: `Resolve markers manually. 'cco start' will block until resolved.` (info, update.sh:1962)
    - And: `Your original is saved as {path}.bak` (info, update.sh:1963)
  - If auto-merged and no conflicts: tracked as "merged" in sync summary
  
- `N/new` → saves framework version as `.{path}.new`
  - Success message: `~ {path} → saved framework version as {path}.new` (ok, update.sh:1455)
  - Hint: `Review .new and integrate changes manually, then delete the .new file` (info, update.sh:1456)
  
- `R/replace` → replaces with framework version, creates `.bak`
  - Warning message: `↻ {path} (replaced, backup → {path}.bak)` (warn, update.sh:1462)
    OR (if `--no-backup`): `↻ {path} (replaced)` (warn, update.sh:1464)
  
- `K/keep` → keeps user file but updates `.cco/base/`
  - Message: `Kept user version of {path}` (info, update.sh:1477)
  
- `s/skip` → defers decision
  - Message: `Skipped {path}` (info, update.sh:1482)

---

### REMOVED Files
**Prompt Text (shown but minimal):**
```
{scope}: {path} (removed from framework defaults)
  File will be kept locally. No action needed.
```
**Location:** update.sh:1498-1499
**No interaction required:** Message is informational only

---

### DELETED_UPDATED
**Prompt Text:**
```
{scope}: {path} (you deleted, framework has updates)
  (A)dd back with new version  (S)kip
```
**Location:** update.sh:1511-1512
**Default:** `s` (skip — note lowercase, unlike other defaults)

**User Responses:**
- `A/add/replace` → restores file with latest framework version
  - Success message: `+ {path} (re-added with latest version)` (ok, update.sh:1526)
- `s/skip` → respects deletion
  - Message: `Skipped {path} (won't notify again until next framework update)` (info, update.sh:1532)

---

### USER_MODIFIED / NO_UPDATE (Silent)
**Location:** update.sh:1488-1491
**No prompt shown:** These statuses are internal tracking only; manifest entry is updated silently.

---

## 4. SYNC OPERATION SUMMARY

**Function:** `_interactive_sync()` (end summary)
**Location:** update.sh:1543-1557
**Format:** Shows counts of each action taken

**Example Output:**
```
Global files: 3 applied, 1 merged, 2 kept, 1 skipped
```

**Breakdown:**
- `applied` = files added, updated, or replaced (NEW + UPDATE_AVAILABLE + BASE_MISSING + MERGE_AVAILABLE with (N/R))
- `merged` = files auto-merged cleanly (MERGE_AVAILABLE with (M) that didn't have conflicts)
- `kept` = files where user chose (K)eep
- `skipped` = files where user chose (S)kip or deferred

**No output** if total_changes = 0 and skipped = 0

---

## 5. CONFLICT RESOLUTION DETAILS

### Auto-Merge Success
**Message:** `✓ {path} (auto-merged)`
**Location:** update.sh:901
**Context:** 3-way merge (git merge-file) succeeded with no conflicts

### Merge Conflict Detected
**Header:** `Merge conflict: {path}`
**Location:** update.sh:905
**Context Message:**
```
  Both you and the framework changed overlapping sections.

  Conflicting sections:
  {grep output showing <<<<<<<...>>>>>>> markers}
```
**Location:** update.sh:906-915

**Then shows merge resolution options** (above)

### Conflict Resolution (Manual with Markers)
**If user chooses (M) or (E):**
```
  ⚠ {path} written with conflict markers
    Resolve markers manually. 'cco start' will block until resolved.
    Your original is saved as {path}.bak
```
**Location:** update.sh:961-963

### Conflict Resolution (Replace)
**If user chooses (R):**
```
  ↻ {path} (replaced, backup → {path}.bak)
```
**Location:** update.sh:962

---

## 6. FALLBACK CONFLICT (No Base Available)

**Function:** `_resolve_conflict_interactive()` (update.sh:1000-1037)
**When:** BASE_MISSING + user modified + no base available for 3-way merge

**Header:** `Conflict: {path}`
**Location:** update.sh:1007
**Context:**
```
  Your version differs from the new defaults.
  No base version available for 3-way merge.
```
**Location:** update.sh:1008-1009

**Options:**
```
  (K)eep your version
  (R)eplace with new default + create .bak
  (S)kip (decide later)
```
**Location:** update.sh:1011-1013

---

## 7. MIGRATION MESSAGES

**Function:** `_run_migrations()` (update.sh:671-717)
**Invoked:** Start of global/project update (before discovery)

### Migration Pending Notification
**Discovery/Diff modes (dry-run):**
```
{N} global migration(s) pending
```
**Location:** update.sh:1789

**OR for projects:**
```
{N} project migration(s) pending for '{project_name}'
```
**Location:** update.sh:2077

### Migration Execution
**During sync (real execution):**
```
Running migration {ID}: {DESCRIPTION}
```
**Location:** update.sh:692

**On success:**
```
✓ Migration {ID} completed
```
**Location:** (implicit in loop, see update.sh:705-707)

**On failure:**
```
! Migration {ID} failed (exit code {CODE})
```
**Location:** update.sh:703

**Summary after migrations:**
```
✓ Ran {N} migration(s)
```
**Location:** update.sh:716

### Migration Error (Terminal)
```
! Global migrations failed. Run 'cco update' again after resolving the issue.
! Project '{name}' migrations failed. Run 'cco update' again after resolving the issue.
```
**Location:** update.sh:1805, 2080

### Vault Pre-Migration Prompt
**If .git/vault detected:**
```
  Vault detected. Commit current state before running {N} migration(s)? [Y/n]
```
**Location:** update.sh:1795

**On vault sync success:**
```
  Vault snapshot created. You can use --no-backup to skip .bak files.
```
**Location:** update.sh:1871

---

## 8. CHANGELOG NOTIFICATIONS

### Discovery Mode (default `cco update`)
**Function:** `_show_changelog_summary()` (update.sh:1641-1666)

**Header (if new entries exist):**
```
What's new in cco:
  + {title}
  + {title}
  ...
```
**Location:** update.sh:1655-1657

**Footer (if user hasn't read details):**
```
  Run 'cco update --news' for details and examples.
```
**Location:** update.sh:1664

### News Mode (`cco update --news`)
**Function:** `_show_changelog_news()` (update.sh:1670-1691)

**Format (per new entry):**
```
[{date}] {title}
  {description}
```
**Location:** update.sh:1682-1683

**If no new entries:**
```
✓ No new features since last check.
```
**Location:** update.sh:1689

---

## 9. INSTALLED PROJECT DISCOVERY MESSAGES

**Function:** `_update_project()` in discovery mode (update.sh:2175-2198)
**Context:** Project installed from a Config Repo remote

### Remote Status Messages
| Status | Message | File:Line | Notes |
|---|---|---|---|
| `update_available` | `Publisher update available` + `-> run 'cco project update {name}' to review` | update.sh:2180-2181 | New version at source |
| `unknown` | `Version tracking not initialized — run 'cco project update {name}' to check` | update.sh:2184 | No version history yet |
| `unreachable` | `Remote unreachable — skipping remote check` | update.sh:2187 | Source URL not accessible |
| `up_to_date` | `✓ Publisher version: up to date` | update.sh:2190 | Version matches source |

### Framework Updates Note (for installed projects)
```
  {N} framework default(s) also updated (managed by publisher)
```
**Location:** update.sh:2194
**Context:** Informational; user should use publisher update chain, not framework sync

### Installed Project in Sync Mode (without --local)
**Header + redirect message:**
```
Project '{name}' is installed from {source_display}.
Framework opinionated updates are managed by the publisher.
  -> Run 'cco project update {name}' to check for publisher updates.
  -> Use '--local' to apply framework defaults directly.
```
**Location:** update.sh:2099-2102

### Framework Override Confirmation
**When user provides `--local` to installed project:**
```
Applying framework defaults directly (--local escape hatch).
```
**Location:** update.sh:2208

---

## 10. PACK DISCOVERY MESSAGES

**Function:** `cmd_update()` in discovery mode (cmd-update.sh:207-245)
**Context:** Remote source checks for installed packs

### Pack Status Messages
| Status | Message | File:Line | Notes |
|---|---|---|---|
| `update_available` | `Pack '{name}' (from {source}): Update available` + `-> run 'cco pack update {name}'` | cmd-update.sh:230-231 | New version available |
| `unknown` | `Pack '{name}' (from {source}): Version tracking not initialized` + `-> run 'cco pack update {name}' to check` | cmd-update.sh:234-235 | First check |
| `unreachable` | `Pack '{name}' (from {source}): Remote unreachable` | cmd-update.sh:238 | Source not reachable |
| `up_to_date` | *(silent)* | cmd-update.sh:241 | No message for up-to-date packs |

---

## 11. TOP-LEVEL UPDATE COMMAND MESSAGES

**Function:** `cmd_update()` (cmd-update.sh:8-262)

### Operation Messages (before/after)
| Condition | Message | File:Line |
|---|---|---|
| Non-TTY in sync mode | `Non-interactive mode: skipping all file changes. Use a terminal for interactive merge.` | cmd-update.sh:114 |
| Global update starts | `Checking/Updating global config...` | cmd-update.sh:160 |
| Project update starts | `Checking/Updating project '{name}'...` | cmd-update.sh:188 |
| Global update error | `Global update encountered errors. Project updates will still be attempted.` OR `Global update encountered errors.` | cmd-update.sh:164, 166 |
| Project update error | `Project '{name}' update encountered errors.` | cmd-update.sh:190 |
| Multiple project errors | `{N} project(s) had update errors. Run 'cco update' again after resolving.` | cmd-update.sh:195 |
| Single project error (sync) | `Project '{name}' update encountered errors. Run 'cco update --sync {name}' again.` | cmd-update.sh:202 |

### Completion Messages
| Mode | Message | File:Line |
|---|---|---|
| Dry-run | `Dry run complete. No changes made.` | cmd-update.sh:254 |
| Discovery/Diff/News | `✓ Update check complete.` | cmd-update.sh:257 |
| Sync (real execution) | `✓ Update complete.` | cmd-update.sh:260 |
| Error exit | `! Update completed with errors. Run 'cco update' again after resolving.` | cmd-update.sh:248 |

---

## 12. SPECIAL PROJECT MESSAGES

### Project Up-to-Date (local project)
**Message:** `✓ Project '{name}' config is up to date.`
**Location:** update.sh:2164
**Context:** No migrations, no root missing files, no framework changes, no remote changes

### Missing Root Files Notification
**For each missing root file (setup.sh, secrets.env, mcp-packages.txt):**
```
  + {file} (missing, will copy from template)   [dry-run]
  + {file} (copied from template)                [sync]
```
**Location:** update.sh:2220, 2223

---

## 13. UX ANALYSIS & ISSUES

### Terminology Issues

| Term | Where | Impact | Recommendation |
|---|---|---|---|
| **"base"** (BASE_MISSING) | Discovery summary, sync prompt, diff header | Users unfamiliar with framework internals don't understand what "base" means | Replace with "previous version" or "baseline" |
| **"merge"** | Summary footer, merge options | Some users may not understand merge semantics | Add glossary or link to help |
| **"policy"** | Internal use only | Not visible to users; OK |

### Clarity Issues

| Issue | Where | Impact | Fix |
|---|---|---|---|
| No explanatory context for DELETED_UPDATED | Used in summary counts | User may not understand why deleted file is being flagged | Add brief explanation in sync prompt ("you deleted this, but framework updated it") — ALREADY DONE ✓ |
| MERGE_AVAILABLE default is (M)erge | Prompt shows this | User might think auto-merge is guaranteed; conflicts possible | Prompt already mentions "merge needed" and shows conflict handling ✓ |
| Non-TTY skips all files silently | Non-interactive mode | User may not realize changes were deferred | Message: "Non-interactive mode: skipping all file changes" ✓ |

### Missing Context

| Gap | Location | Recommendation |
|---|---|---|
| What does "new baseline to compare" mean in BASE_MISSING? | update.sh:1339 | Add: "This happens when you added this file after the framework started tracking it." |
| What's the difference between "Kept" and "Skipped"? | Multiple prompts | Both defer action, but "Kept" updates .cco/base/ while "Skip" doesn't. Consider unified behavior or clearer naming. |
| Why is DELETED_UPDATED default (s) instead of (A)? | update.sh:1514-1516 | Respects user's deletion decision; makes sense but could be clearer in the prompt. |

---

## 14. MESSAGE CATEGORIES SUMMARY

| Category | Count | File | Coverage |
|---|---|---|---|
| **Status Codes** | 7 main (NEW, UPDATE_AVAILABLE, MERGE_AVAILABLE, BASE_MISSING, REMOVED, DELETED_UPDATED, USER_MODIFIED) | update.sh | ✓ |
| **Discovery Summary** | 6 counts + 1 footer | update.sh | ✓ |
| **Diff Headers** | 6 status → header mappings | update.sh | ✓ |
| **Sync Prompts** | 6 status types × choice options | update.sh | ✓ |
| **Conflict Resolution** | 3-way merge paths + interactive fallback | update.sh | ✓ |
| **Migrations** | Pending, executing, success, failure | update.sh, cmd-update.sh | ✓ |
| **Changelog** | Summary, news, no new entries | update.sh | ✓ |
| **Installed Projects** | Remote status, redirect to publisher | update.sh, cmd-update.sh | ✓ |
| **Packs** | Remote status | cmd-update.sh | ✓ |
| **Errors & Warnings** | Global/project errors, non-TTY, completion | cmd-update.sh, update.sh | ✓ |

---

## 15. TESTING NOTES

To verify all messages are shown correctly:

1. **Discovery Summary:** Run `cco update` with files in each status
2. **Diff:** Run `cco update --diff` for each status
3. **Sync Interactive:** Run `cco update --sync` and try each prompt option (A/S/K/R/M/N/D)
4. **Conflict with merge:** Add conflicting changes to a tracked file; run sync and choose (M)
5. **Conflict with markers:** Run sync, choose (M), intentionally leave conflict markers
6. **Non-TTY:** Run `echo "" | cco update --sync` (verify non-TTY skip message)
7. **Migrations:** Create pending migration (increase schema_version); run update
8. **Changelog:** Add new entry to changelog.yml; run `cco update` and `cco update --news`
9. **Installed projects:** Create project from Config Repo; run `cco update` discovery
10. **Packs:** Install pack from Config Repo; run `cco update` discovery

---

