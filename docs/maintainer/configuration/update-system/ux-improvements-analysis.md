# Update System — UX Improvements Analysis

**Date**: 2026-03-20
**Status**: Analysis
**Related**: `base-tracking-fix-design.md` (prior fix, partially addresses), `design.md`, `analysis.md`
**Trigger**: Real-world usage of `cco update` revealed three categories of problems

---

## 1. Context

This analysis was triggered by running `cco update --sync` and `cco update --diff`
on real projects (claude-orchestrator, devops-toolkit) on 2026-03-19 and 2026-03-20.
The experience revealed bugs, design gaps, and UX issues that undermine user trust
in the update system.

### 1.1 What Happened

**Day 1** (2026-03-19): First `cco update --sync` after several framework changes.
- Global files applied cleanly (3 files, all SAFE_UPDATE)
- Project claude-orchestrator: CLAUDE.md classified as `MERGE_AVAILABLE` — user
  chose (D)iff, saw raw `{{PROJECT_NAME}}` in "framework changes" diff, then chose (N)
  to save as .new file. The base was saved **raw** (with placeholders).
- Project devops-toolkit: CLAUDE.md merge had conflict on `{{DESCRIPTION}}` —
  user chose (R)eplace, which **overwrote their customized CLAUDE.md with the raw
  skeleton template** (including unresolved `{{DESCRIPTION}}`).

**Day 2** (2026-03-20): Ran `cco update` and `cco update --diff` again.
- claude-orchestrator: Still shows `MERGE_AVAILABLE` — the diff shows base
  (raw `{{PROJECT_NAME}}`) vs new (interpolated `claude-orchestrator`). This is a
  **perpetual false positive** because base was saved raw during sync.
- devops-toolkit: Shows `UPDATE_AVAILABLE` — because the installed file now IS the
  raw template (from yesterday's Replace), and the "new" version is interpolated.
  The "update" is just replacing `{{PROJECT_NAME}}` with `devops-toolkit`.

### 1.2 Problems Identified

| # | Category | Severity | Description |
|---|----------|----------|-------------|
| P1 | Bug | High | `_save_base_version` in sync saves raw template, not interpolated — causes perpetual false MERGE_AVAILABLE |
| P2 | Bug | High | Diff display in `_show_file_diffs` for MERGE_AVAILABLE shows raw base (with placeholders) when base was saved raw |
| P3 | Design | Medium | 3-way merge is structurally incompatible with CLAUDE.md post-init-workspace (skeleton vs rich document) |
| P4 | UX | Medium | `--diff` output dumps all files for all scopes at once — overwhelming with many changes |
| P5 | UX | Low | No scope filtering for `--diff` (can't inspect one project or one file) |

---

## 2. Bug Analysis: Raw Base in Sync (P1, P2)

### 2.1 Root Cause

The `base-tracking-fix-design.md` (2026-03-18) fixed three areas:
1. `cco project create` — now saves base from interpolated project dir ✓
2. `cco project install` — now saves base from interpolated target dir ✓
3. `_handle_policy_transitions` — seeds base from interpolated template ✓
4. `_collect_file_changes` — interpolates template for hash comparison ✓
5. `_show_file_diffs` — interpolates template for display ✓

**What was NOT fixed**: `_save_base_version` calls inside `_interactive_sync`
(`lib/update-sync.sh`). Every action (Apply, New-file, Replace, Keep) calls:

```bash
_save_base_version "$base_dir" "$rel_path" "$defaults_dir/$rel_path"
```

This copies the **raw template** file (with `{{PROJECT_NAME}}`, `{{DESCRIPTION}}`)
as the new base. The next `_collect_file_changes` run computes `new_hash` from the
**interpolated** template, so `base_hash ≠ new_hash` → false `MERGE_AVAILABLE` forever.

### 2.2 Affected Code Points

In `lib/update-sync.sh`, `_save_base_version` is called at these locations
(all within `_interactive_sync`):

| Line | Context | Status |
|------|---------|--------|
| ~51 | NEW → Add file | Saves raw |
| ~94 | UPDATE_AVAILABLE → Apply | Saves raw |
| ~102 | UPDATE_AVAILABLE → Keep | Saves raw |
| ~150 | BASE_MISSING → New-file | Saves raw |
| ~162 | BASE_MISSING → Apply | Saves raw |
| ~170 | BASE_MISSING → Keep | Saves raw |
| ~227 | MERGE_AVAILABLE → after merge | Saves raw |
| ~240 | MERGE_AVAILABLE → New-file | Saves raw |
| ~255 | MERGE_AVAILABLE → Replace | Saves raw |
| ~263 | MERGE_AVAILABLE → Keep | Saves raw |

Additionally, in `lib/update-merge.sh`, `_resolve_conflict_interactive` (line ~214)
also saves `$defaults_dir/$rel_path` as manifest entry hash but does NOT call
`_save_base_version` directly — the base save happens in the caller.

### 2.3 Why This Wasn't Caught

The base-tracking-fix focused on the **initial seeding** path (create, install,
policy transition). The **ongoing sync** path was assumed correct because it copies
from `$defaults_dir` — which is correct for global scope (no placeholders). The
bug only manifests in **project scope** where templates have `{{PLACEHOLDER}}`.

### 2.4 Fix Approach

Pass `project_dir` to `_interactive_sync` for project scope. When saving base,
use `_interpolate_template_tmp` to save the interpolated version:

```bash
# In _interactive_sync, when saving base for project scope:
if [[ -n "$project_dir" ]]; then
    local interp_tmp
    interp_tmp=$(_interpolate_template_tmp "$defaults_dir/$rel_path" "$project_dir")
    _save_base_version "$base_dir" "$rel_path" "$interp_tmp"
    rm -f "$interp_tmp"
else
    _save_base_version "$base_dir" "$rel_path" "$defaults_dir/$rel_path"
fi
```

This requires threading `project_dir` through the call chain:
- `_update_project` → `_interactive_sync` (add `project_dir` parameter)
- `_interactive_sync` → internal base saves (use interpolated version)

The `_show_file_diffs` display fix (P2) is already handled by the existing
`_interpolate_template_tmp` call in `_show_file_diffs`. However, the **base
file itself** shown in the "base → new" diff is the raw stored base. If the
base was saved raw from a previous sync, the diff will show raw placeholders
until the base is re-saved correctly. A one-time base repair during the next
sync (or a migration) would clean this up.

---

## 3. Design Analysis: CLAUDE.md Structural Divergence (P3)

### 3.1 The Fundamental Tension

The project CLAUDE.md has two fundamentally different lifecycles:

```
Template (skeleton)          →  cco project create  →  User file (initial)
     17 lines                                              17 lines
     {{PLACEHOLDER}}                                       project-name
                                                           TODO: Add description

User file (initial)          →  /init-workspace     →  User file (rich)
     17 lines                                              109+ lines
     section headers only                                  full architecture, repos,
                                                           commands, diagrams...
```

The 3-way merge compares:
- **base**: skeleton template (17 lines, interpolated)
- **new**: updated skeleton template (17 lines, possibly with minor changes)
- **installed**: rich document (109+ lines, completely different structure)

This is not a "both sides modified the same document" scenario — the user
replaced the document entirely. The merge is doomed to produce conflicts on
every section because the structures don't overlap meaningfully.

### 3.2 Use Cases for Project CLAUDE.md

| # | Scenario | Initial CLAUDE.md | After first session | Update value |
|---|----------|-------------------|---------------------|-------------|
| UC1 | Base template, user runs init-workspace | Skeleton (17 lines) | Rich auto-generated (100+ lines) | **Low** — document is completely replaced, merge meaningless |
| UC2 | Base template, user doesn't run init-workspace | Skeleton with TODOs | Manually filled by user/agent | **Medium** — structural similarity preserved, merge might work |
| UC3 | Shared/published project with rich CLAUDE.md | Detailed, project-specific | Possibly enriched by init-workspace | **High** — publisher updates are meaningful content |
| UC4 | Shared project with skeleton CLAUDE.md | Similar to UC1 | Same as UC1 | **Low** — same problem as UC1 |
| UC5 | User template with rich CLAUDE.md | Detailed, template-specific | Possibly enriched | **High** — same as UC3 |
| UC6 | User template with skeleton CLAUDE.md | Skeleton | Same as UC1/UC2 | **Low/Medium** |

### 3.3 Key Insight: Divergence Level Determines Merge Viability

The problem is not with CLAUDE.md tracking per se — it's that the merge
strategy doesn't account for the **degree of divergence**:

- **Low divergence** (UC2, UC3, UC5): User kept the template structure,
  modified content within sections. 3-way merge works well.
- **High divergence** (UC1, UC4, UC6): User (or init-workspace) replaced
  the entire document. 3-way merge is useless — every section conflicts.

### 3.4 Approaches for Handling High Divergence

**Approach A — Detect and skip**: When the installed file diverges beyond a
threshold from the base (e.g., >80% diff), classify as `USER_RESTRUCTURED`
instead of `MERGE_AVAILABLE`. Default to (K)eep with a clear message.

Pro: Simple heuristic, no false merge prompts.
Con: Threshold is arbitrary; might miss legitimate merge cases.

**Approach B — Init-workspace updates the base**: After `/init-workspace`
regenerates CLAUDE.md, also update `.cco/base/CLAUDE.md` to match. The next
framework template change will be compared against the init-workspace output
(much closer to the user's current file), making merge viable.

Pro: Structurally correct — base always reflects "what the framework gave".
Con: Requires init-workspace to know about `.cco/base/`; couples two systems.

**Approach C — AI-assisted merge**: For content-based .md files, offer an
AI merge option that understands document semantics. See section 5.

Pro: Handles arbitrary divergence; understands meaning, not just lines.
Con: Non-deterministic; requires Claude CLI or container.

**Approach D — Separate tracking for template structure vs content**: Track
only the section headers as "framework structure". User content within
sections is ignored by the merge. Framework can add new sections without
conflicting with user content.

Pro: Precise; only merges what matters.
Con: Complex implementation; fragile if section naming changes.

### 3.5 Recommended Combination

1. **Fix P1** (bug fix) — interpolated base saves. Required regardless.
2. **Approach B** — init-workspace updates base. This is the structurally
   correct solution. When init-workspace regenerates CLAUDE.md, the new
   content IS what the framework provided (via the skill). Saving it as
   base means future merges compare against a relevant ancestor.
3. **Approach C** (AI-merge) — as an additional option for cases where
   the user wants intelligent merge of divergent documents. See section 5.
4. **Approach A** (divergence detection) — as a UX improvement on top,
   to guide users toward (K)eep when merge is unlikely to help.

---

## 4. UX Analysis: `--diff` Output (P4, P5)

### 4.1 Current Behavior

`cco update --diff` iterates all scopes (global, each project) and dumps
every file's diff inline. With N projects and M files per project, the output
is N×M diff blocks with no navigation.

For a user with 5 projects and 2-3 changed files each, this is 10-15 diff
blocks — potentially hundreds of lines of output.

### 4.2 Proposed Behavior: Summary + Scoped Drill-Down

**Default `--diff`**: Show summary only (file list with status), like `--diff`
becomes a more detailed version of discovery:

```
$ cco update --diff
Global: up to date

Project 'claude-orchestrator':
  CLAUDE.md — both modified (merge needed)

Project 'devops-toolkit':
  CLAUDE.md — framework updated (safe to apply)

2 file(s) with available changes across 2 project(s).
Use 'cco update --diff --project <name>' or 'cco update --diff <file>' for details.
```

**Scoped drill-down**:

```bash
cco update --diff --global                       # Global scope only
cco update --diff --project claude-orchestrator   # One project
cco update --diff CLAUDE.md                       # Specific file (all scopes)
cco update --diff --project myapp CLAUDE.md       # File + scope
```

**Full dump (opt-in)**:

```bash
cco update --diff --all                          # Current behavior (all diffs)
```

### 4.3 Consistency with Existing Patterns

The `--sync` command already does per-file interactive prompts with inline
diff (D option). The `--diff` command should be the "preview before sync"
tool — showing what's available without the action prompts.

Scope filtering aligns with existing patterns:
- `cco update --sync --project <name>` already works (or should)
- `cco clean --project <name>` scopes cleanup to one project

---

## 5. Feature Analysis: AI-Assisted Merge

### 5.1 Motivation

Text-based 3-way merge (git merge-file) operates on lines. For structured
prose documents like CLAUDE.md, agent specs, rules, and skills, the merge
often produces conflicts where a human would see no ambiguity — e.g., both
sides added content to the same section, but the content is complementary.

An AI merge understands document semantics: sections, headings, code blocks,
lists. It can intelligently combine:
- User's project-specific content (architecture, repos, commands)
- Framework's structural updates (new sections, updated boilerplate)

### 5.2 Applicable File Types

| File type | AI merge value | Rationale |
|-----------|---------------|-----------|
| `.md` content files (CLAUDE.md, rules, agents, skills) | **High** | Prose with semantic structure; AI understands sections |
| `settings.json` | **None** | Structured JSON; deterministic merge is better |
| `project.yml` | **None** | Structured YAML; untracked anyway |
| `mcp.json` | **None** | Structured JSON; untracked |

### 5.3 Execution Environment

`cco` runs on the host where Claude Code **may not be installed**. The
orchestrator provides Claude inside Docker containers, but the CLI itself
has no Claude dependency.

**Options for AI merge execution**:

| Option | Description | Friction | Reliability |
|--------|-------------|----------|-------------|
| **O1: Host Claude** | Require `claude` CLI on host | Medium — user must install | High — direct execution |
| **O2: Dedicated container** | Spin up a lightweight cco container for the merge | Low — uses existing image | High — controlled environment |
| **O3: API call** | Direct Anthropic API call from the CLI | Low — only needs API key | Medium — network dependency |
| **O4: Graceful fallback** | Try host Claude → try container → fall back to text merge | Lowest — always works | Highest — multiple paths |

**Recommendation: O4 (graceful fallback)** with O2 as primary path.

The cco Docker image already has Claude installed. Spinning up a short-lived
container for the merge is:
- Zero additional dependencies for the user
- Consistent environment (same Claude version as sessions)
- No API key management (uses existing auth)
- Fast for small files (container startup + single prompt)

Fallback chain:
1. Check if `claude` is on PATH → use it directly (fastest)
2. If not, check if cco Docker image exists → `docker run --rm` with merge prompt
3. If neither available → fall back to `git merge-file` with conflict markers

### 5.4 Merge Prompt Design

The AI receives:
- The **upstream** file (new framework version)
- The **user** file (current installed version)
- A **context** instruction explaining the merge rules

```
You are merging two versions of a configuration file.

UPSTREAM VERSION (framework update):
[contents of new default]

USER VERSION (current installed):
[contents of user file]

Rules:
- Preserve ALL user-specific content (project descriptions, custom sections,
  architecture details, repo listings)
- Integrate upstream structural changes (new sections, updated boilerplate,
  framework instructions)
- If upstream adds a new section that the user doesn't have, add it
- If upstream removes a section, keep it if the user has content in it
- If both have content in the same section, prefer the user's content
  unless the upstream version fixes an obvious error
- Output ONLY the merged file content, no explanations
```

### 5.5 User Interaction

In `_interactive_sync`, add (I) AI-merge option for `.md` files:

```
ℹ Project 'myapp': CLAUDE.md (both modified — merge needed)
  (M)erge 3-way  (I) AI-merge  (N)ew-file (.new)  (R)eplace + .bak  (K)eep yours  (S)kip  (D)iff
  Tip: (I) uses Claude to intelligently merge — best for heavily customized files
  Choice [M/i/n/r/k/s/d]: I
  ℹ Running AI merge via container...
  ✓ AI merge complete. Review the result:
  [shows diff: user file → merged result]
  (A)ccept  (E)dit  (R)eject → keep yours
```

The user ALWAYS reviews the AI merge result before it's applied.

### 5.6 Scope and Limitations

- AI merge is **optional** — always available alongside text-based merge
- Only offered for `.md` files (prose-based, where AI adds value)
- Non-deterministic: same inputs may produce slightly different outputs
- Cost: one API call per file merge (small files = minimal tokens)
- Latency: container startup (~2-3s) + API call (~3-5s) = ~5-8s total
- The merge result must be shown to the user for review before applying

---

## 6. Summary of Proposed Changes

### Immediate (bug fixes)

| Change | Files | Description |
|--------|-------|-------------|
| P1 fix | `lib/update-sync.sh` | Save interpolated base in project scope |
| P1 fix | `lib/update.sh` | Pass `project_dir` to `_interactive_sync` |
| P1 fix | `lib/update-merge.sh` | Pass `project_dir` to `_resolve_with_merge` |

### Short-term (UX improvements)

| Change | Files | Description |
|--------|-------|-------------|
| P4/P5 | `lib/update-discovery.sh` | `--diff` shows summary by default, scoped drill-down |
| P4/P5 | `lib/cmd-update.sh` | Parse `--global`, `--project <name>`, file args for `--diff` |
| P3 partial | `lib/update-discovery.sh` | Divergence detection: classify as USER_RESTRUCTURED |

### Medium-term (design improvements)

| Change | Files | Description |
|--------|-------|-------------|
| P3 | `defaults/managed/.claude/skills/init-workspace/` | Update base after regeneration |
| AI merge | `lib/update-merge.sh`, new `lib/ai-merge.sh` | AI-assisted merge for .md files |

---

## 7. Open Questions

### Q1: Should init-workspace update .cco/base?

If init-workspace updates `.cco/base/CLAUDE.md` after regeneration (Approach B),
it creates a coupling between the managed skill and the update system's internal
state. The skill runs inside the container where `.cco/base/` is accessible via
the project mount.

Alternative: A hook or post-init step that updates base, rather than embedding
the logic in the skill itself.

### Q2: AI merge — which model?

For merge tasks, a smaller/faster model (Haiku) may suffice. The merge prompt
is well-constrained and the output is verifiable. Using Haiku would reduce
cost and latency.

### Q3: AI merge — auth in container

The dedicated merge container needs Claude auth. Options:
- Mount `~/.claude/.credentials.json` (same as regular sessions)
- Pass API key via environment variable
- Use the existing cco auth flow

### Q4: Divergence threshold for USER_RESTRUCTURED

What metric to use? Options:
- Line count ratio (installed/base > 3x → restructured)
- Diff stat percentage (>80% changed → restructured)
- Section header comparison (>50% headers don't match → restructured)

### Q5: Should --diff scoping also apply to --sync?

Currently `--sync` iterates all scopes. Should `cco update --sync --project myapp`
be supported for applying updates to a single project? This seems useful but needs
to handle the vault snapshot question (scope-specific vs global).
