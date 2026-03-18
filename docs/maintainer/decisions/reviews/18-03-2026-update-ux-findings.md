# Key Findings: Update System UX Audit

**Date**: 2026-03-18
**Status**: Issues #1 and #2 resolved. Issue #3 open.

## Executive Summary

Audited all user-facing messages in the `cco update` system across 3 files (update.sh, cmd-update.sh, cmd-project.sh). Found **7 status codes**, **50+ distinct user messages**, and **3 major UX issues** using unexplained technical jargon.

---

## 1. CRITICAL UX ISSUES

### Issue #1: "base" Jargon in BASE_MISSING
**Severity:** HIGH  
**Impact:** Users don't understand why files are flagged as "BASE_MISSING"

**Where it appears:**
- Discovery summary: "2 file(s) with missing base (BASE_MISSING)"
- Sync prompt: "framework has updates, no baseline to compare"
- Diff header: "update available, base missing"

**What users see:**
```
2 file(s) with missing base (BASE_MISSING)
```

**What they think:** "What is 'base'? I didn't set anything called 'base'."

**Root cause:** `.cco/base/` is internal framework tracking; users shouldn't need to know this term.

**Recommendation:** Replace "missing base" with more user-friendly phrasing:
- "3 file(s) have updates but no history (can't auto-merge)"
- "3 file(s) with unclear modification history"
- "3 file(s) where we can't tell if you customized them"

---

### Issue #2: "merge" Used Loosely in Summary Footer
**Severity:** MEDIUM  
**Impact:** Users don't know that "merge" might create conflict markers

**Where it appears:**
- Summary footer: "Run 'cco update --sync' to merge."
- Prompt header: "both modified — merge needed"

**What users see:**
```
Run 'cco update --sync' to merge.
```

**What they think:** "Merge will solve everything automatically. It's like a merge button in git."

**Reality:** Merge can produce conflict markers that need manual resolution.

**Recommendation:** Use more precise language:
- "Run 'cco update --sync' to review and apply updates."
- "Run 'cco update --sync' to interactively resolve conflicting changes."

---

### Issue #3: "Kept" vs "Skipped" Semantics Unclear
**Severity:** MEDIUM  
**Impact:** Users may not understand that (K) and (S) have different persistence

**Where it appears:**
- UPDATE_AVAILABLE prompt: offers both (S)kip and (K)eep options
- BASE_MISSING prompt: offers both (S)kip and (K)eep options
- MERGE_AVAILABLE prompt: offers both (S)kip and (K)eep options

**The distinction:**
- **(K)eep** → keeps user file, updates `.cco/base/` to prevent future notifications
- **(S)kip** → defers decision, re-shows same file next time

**What users understand:**
- Both seem to "do nothing"

**Recommendation:** Either:
1. **Rename** (K) to something like (D)one or (M)ark-resolved
2. **Document** in-line: add a note "(K)eep your version and mark as resolved"
3. **Unify behavior**: always use (S)kip for "not now" and remove (K)

---

## 2. INTERNAL JARGON AUDIT

### Terms Used (Visible to Users)

| Term | Where | Frequency | Severity |
|---|---|---|---|
| **base** | 6 places (summary, diff, sync, conflict) | High | HIGH |
| **merge** | 10+ places (summary, prompts, messages) | High | MEDIUM |
| **policy** | Not visible | - | SAFE |
| **manifest** | Not visible (internal tracking) | - | SAFE |
| **3-way merge** | 3 places (prompts, messages) | Low | LOW |
| **conflict markers** | 2 places (merge error messages) | Low | LOW |

---

## 3. MISSING CONTEXT / DOCUMENTATION

### Problem: BASE_MISSING Explanation
**Current text:**
```
{scope}: {path} (framework has updates, no baseline to compare)
```

**User questions:**
1. "What's a baseline?"
2. "Why don't I have one?"
3. "What should I do about it?"

**Suggested enhancement:**
```
{scope}: {path} (framework has updates, but we can't detect your changes)
  Tip: This happens when you added or modified this file before we started tracking it.
  Choose (N) to review the framework version side-by-side, or (K) to keep yours.
```

---

### Problem: "Kept" vs "Skipped" Not Explained
**Current behavior:**
- Both hide the file from next prompt
- But "Kept" updates metadata, "Skipped" doesn't

**Suggested enhancement:**
```
(K)eep yours — accept your version, won't ask again
(S)kip — defer this decision, will ask again next time
```

---

### Problem: Why DELETED_UPDATED Default is (s) Not (A)
**Current code:**
```
choice="${choice:-s}"  # Default to skip
```

**Confusion:**
- Why skip by default for deleted files?
- Other statuses default to apply/add/merge

**Suggested context:**
```
{scope}: {path} (you deleted this, framework has updates)
  (A)dd back with new version
  (S)kip — keep it deleted, won't ask again
```

---

## 4. MESSAGE COMPLETENESS CHECK

### ✅ Comprehensive Status Coverage
All 7 status codes have user-facing messages:
- ✓ NEW (new framework file)
- ✓ UPDATE_AVAILABLE (framework updated)
- ✓ MERGE_AVAILABLE (both modified)
- ✓ BASE_MISSING (can't determine changes)
- ✓ REMOVED (file removed from framework)
- ✓ DELETED_UPDATED (you deleted; framework updated)
- ✓ USER_MODIFIED (silent; no message)
- ✓ NO_UPDATE (silent; no message)

### ✓ All Modes Have Output
- ✓ `cco update` (discovery) — shows summary counts
- ✓ `cco update --diff` — shows diffs with headers
- ✓ `cco update --sync` — shows prompts and outcome messages
- ✓ `cco update --news` — shows changelog
- ✓ `cco update --dry-run` — shows "no changes made"

### ✓ Error Paths Covered
- ✓ Migration failures
- ✓ Non-TTY mode (auto-skip with warning)
- ✓ Merge conflicts
- ✓ Missing bases (fallback to interactive)
- ✓ Remote unreachable
- ✓ Project errors

---

## 5. RECOMMENDATIONS BY PRIORITY

### ~~PRIORITY 1: Fix BASE_MISSING Jargon~~ ✅ RESOLVED

Resolved in commit `532158b` (2026-03-18). All internal status codes removed from
user-facing output. `BASE_MISSING` replaced with "available updates — manual review
recommended".

---

### ~~PRIORITY 2: Clarify "merge" Language~~ ✅ RESOLVED

Resolved in the same commit. Footer changed from "to merge" to "to review and apply".
Sync prompt header updated to match.

---

### 🟡 PRIORITY 3: Document (K) vs (S) Distinction
**Action:** Add inline hints to prompts
- (K)eep yours → "accept your version, won't ask again"
- (S)kip → "defer, will ask again next time"

**Effort:** 30 mins  
**Impact:** Reduces "what's the difference?" confusion

---

### 🟢 PRIORITY 4: Add Context to Edge Cases
**Action:** Enhance prompts for BASE_MISSING and DELETED_UPDATED
- Add "why" explanation
- Guide user to right choice
- Link to docs

**Effort:** 1-2 hours  
**Impact:** Improves user confidence in complex scenarios

---

## 6. TEST CASES TO VERIFY

All 7 status codes must be testable:

```bash
# 1. NEW — create file in defaults, not in project
# 2. UPDATE_AVAILABLE — update defaults, don't touch project file
# 3. MERGE_AVAILABLE — update both defaults and project file
# 4. BASE_MISSING — delete .cco/base/ entry, modify project file
# 5. REMOVED — delete file from defaults, keep in .cco/base/
# 6. DELETED_UPDATED — delete from project, update in defaults
# 7. USER_MODIFIED — update defaults, user changes project (same file different)
```

---

## 7. FILES WITH MESSAGES

| File | Lines | Messages | Functions |
|---|---|---|---|
| update.sh | 2,700 | 45+ | _show_discovery_summary, _show_file_diffs, _interactive_sync, _resolve_with_merge, _show_changelog_* |
| cmd-update.sh | 260 | 15+ | cmd_update (completion, errors, pack/project discovery) |
| cmd-project.sh | ~40 | 2 | _update_project (mostly delegated to update.sh) |

---

## 8. AUDIT ARTIFACTS

**Complete audit document:** `AUDIT_UPDATE_MESSAGES.md`  
**Contains:**
- All 50+ exact message texts with file:line references
- 7 status codes × all display modes (summary/diff/sync)
- 30+ prompt variations with defaults and choices
- Migration, changelog, and error messages
- UX analysis and testing checklist

---

