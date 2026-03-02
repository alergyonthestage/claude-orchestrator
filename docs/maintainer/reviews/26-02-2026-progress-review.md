# Progress Review: claude-orchestrator

**Date**: 2026-02-26
**Scope**: Project status, progress from previous review, readiness for Sprint 2-3
**Baseline**: [24-02-2026 Architecture Review](./24-02-2026-architecture-review.md)

---

## Executive Summary

The project is in **excellent shape**. All P0 and P1 findings from the previous review have been implemented and tested. Documentation is aligned with code (no relevant stale content). Test suite is solid (154 tests, zero failures). The project is ready to move on to the differentiating features of Sprints 2 and 3.

---

## 1. Status Compared to 24-02-2026 Review

### P0 (Critical) — All completed

| Recommendation | Status | Implementation |
|---|---|---|
| `alwaysThinkingEnabled: true` in settings.json | ✅ | `defaults/system/.claude/settings.json` |
| Session lock for concurrent sessions | ✅ | `bin/cco`: check `docker ps` before start |
| Validate `secrets.env` | ✅ | `load_secrets_file()`: skip malformed lines with warning |

### P1 (Important) — All completed

| Recommendation | Status | Implementation |
|---|---|---|
| Pin Claude Code version | ✅ | `ARG CLAUDE_CODE_VERSION` in Dockerfile, `--claude-version` flag in CLI |
| Simplify SessionStart hook matcher | ✅ | Single catch-all, no specific matchers |
| Cleanup pack-copied files (manifest) | ✅ | `.pack-manifest` with `_clean_pack_manifest()` |
| Warning for pack conflicts | ✅ (bonus) | `_detect_pack_conflicts()` with "last wins" semantics |

### P2 (Nice to have) — Mixed status

| Recommendation | Status | Note |
|---|---|---|
| ADR-9 Knowledge Packs | ✅ | Added to `architecture.md` |
| ADR-10 Git Worktree Isolation | ✅ | Added to `architecture.md` |
| SessionEnd hook | ⏳ | Not implemented, not critical |
| PreToolUse safety hook | ❌ Declined | Docker is the sandbox (ADR-1), documented in roadmap |
| Test YAML parser edge cases | ⏳ | Parser works in practice, base coverage present |
| Fallback Python YAML | ⏳ | AWK parser sufficient for use cases |

---

## 2. Features Completed After Review

In addition to review fixes, significant features have been implemented:

### System vs User Defaults Separation

New configuration architecture:
- `defaults/system/` — System files (skills, agents, rules, settings.json), **always synced** on every `cco init`/`cco start`
- `defaults/global/` — User defaults (CLAUDE.md, mcp.json, language.md), copied **only once**
- Mechanism: `system.manifest` → compare with installed `.system-manifest` → incremental sync

Impact: future updates to skills/agents require no user intervention.

### Authentication & Secrets

- OAuth: credentials from macOS Keychain → `~/.claude/.credentials.json` (container mount)
- GitHub: `GITHUB_TOKEN` → `gh auth login --with-token` + `gh auth setup-git` in entrypoint
- Secrets: `global/secrets.env` + `projects/<name>/secrets.env` with override semantics
- Validate KEY=VALUE format with warning for malformed lines

### Environment Extensibility (4 mechanisms)

| Mechanism | Scope | Phase |
|---|---|---|
| `docker.image` in project.yml | Per project | Compose generation |
| `global/setup.sh` | Global | Build time (Dockerfile ARG) |
| `projects/<name>/setup.sh` | Per project | Runtime (entrypoint) |
| `projects/<name>/mcp-packages.txt` | Per project | Runtime (npm install in entrypoint) |

### Docker Socket Toggle

`docker.mount_socket: false` in project.yml disables Docker socket mount. Default: `true` (backward-compatible).

### Pack Manifest & Conflict Detection

- `.pack-manifest` tracks files copied from pack
- Automatic cleanup of stale files on every `cco start`
- Warning for name conflicts between packs (same agent/rule/skill)

---

## 3. Documentation — Status

### Complete verification: 14 documents analyzed

| Document | Status | Notes |
|---|---|---|
| `docs/reference/context-hierarchy.md` | ✅ Updated | Settings and context hierarchy accurate |
| `docs/reference/cli.md` | ✅ Updated | All 7 commands documented |
| `docs/reference/context-hierarchy.md` (merged) | ✅ Updated | Lifecycle diagram and component table correct |
| `docs/maintainer/architecture.md` | ✅ Updated | 10 ADRs (1-10), all accurate |
| `docs/maintainer/spec.md` | ✅ Updated | FR-1 → FR-8 implemented |
| `docs/maintainer/docker/design.md` | ✅ Updated | Dockerfile and entrypoint accurate |
| `docs/maintainer/docker/design.md` (merged) | ✅ Updated | Complete and correct structure |
| `docs/maintainer/roadmap.md` | ✅ Updated | Completed section verified |
| `docs/user-guides/project-setup.md` | ✅ Updated | |
| `docs/user-guides/agent-teams.md` | ✅ Updated | |
| `docs/user-guides/advanced/subagents.md` | ✅ Updated | |
| `docs/maintainer/future/worktree/analysis.md` | ✅ Approved | Ready for implementation |
| `docs/maintainer/future/worktree/design.md` | ✅ Design complete | Pending implementation |
| `docs/maintainer/auth/design.md` | ✅ Design | Implementation completed |
| `docs/maintainer/environment/design.md` | ✅ Design | Implementation completed |

**No relevant stale documentation found.** The design docs for auth and environment have "pending" status but implementation is complete — status should be updated to reflect completion.

### Minor discrepancy to resolve

The design files `auth-design.md` and `environment-design.md` still have "Design — pending implementation" status but features have been implemented. Update status to "Implemented" or archive as completed.

---

## 4. Test Suite

```
154 tests, 0 failures
13 test files
~3100 lines of test code
```

Excellent coverage for: CLI commands, compose generation, YAML parsing, packs, manifest, conflict detection, auth, secrets, system sync, project lifecycle.

---

## 5. Repository Metrics

| Metric | Value |
|---|---|
| Total commits | 74 |
| Active branch | `main` (only) |
| `bin/cco` | ~1618 lines |
| Dockerfile | 97 lines |
| Entrypoint | ~115 lines |
| Hook scripts | ~200 lines (4 files) |
| Test suite | ~3100 lines (13 files) |
| Documentation | ~23 markdown files |

---

## 6. Readiness for Sprint 2-3

### Sprint 2: Daily quality of life

**#1 Fix tmux copy-paste** — Ready to implement.
- In-depth analysis in `docs/maintainer/agent-teams/analysis.md` (531 lines, covers 9 terminals, 3 copy methods)
- Current configuration in `config/tmux.conf` has 6 identified gaps (§7 of analysis)
- High impact: every user encounters it daily
- Low effort: modifications to `config/tmux.conf` + documentation

### Sprint 3: Differentiating feature

**#2 Git Worktree Isolation** — Ready to implement.
- Analysis: approved (`docs/maintainer/future/worktree/analysis.md`)
- Design: complete (`docs/maintainer/future/worktree/design.md`)
- ADR-10: documented in `architecture.md`
- Implementation checklist: 11 items detailed in design doc §8
- Prerequisites: none (auth already implemented)

**#3 Session Resume** — Ready to implement.
- `cco resume <project>` → reattach to running container tmux
- Complements worktree: resume work on same branch
- Low effort: `docker exec` + `tmux attach`

---

## 7. Recommendations

### Immediate (before Sprint 2-3)

1. **Update design doc status** — `auth-design.md` and `environment-design.md` should be marked as "Implemented"
2. **Run tests before each sprint** — The suite is robust, use it as a gate

### Sprint 2-3 Priority

3. **Implement #1 tmux copy-paste** — Quick fix, high UX impact
4. **Implement #2 worktree isolation** — Differentiating feature, complete design, zero risk for existing users (opt-in)
5. **Implement #3 session resume** — Complements worktree, low effort

### Post-Sprint 3

6. **Tag v1.0** — The project is production-ready. A formal tag would help adoption.
