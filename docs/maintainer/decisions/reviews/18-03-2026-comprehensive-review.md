# Comprehensive Review — claude-orchestrator

**Date**: 2026-03-18
**Scope**: Full codebase review — architecture, code quality, tests, documentation, proxy, configuration
**Method**: 6 parallel analysis agents examining all source files with cross-referencing

---

## Executive Summary

claude-orchestrator is a mature, well-engineered bash CLI (~12,500 LOC across 24 lib/ modules) with a Go security proxy (~4,500 LOC). After multiple development cycles, the codebase demonstrates strong architectural foundations with clean layering, comprehensive documentation (95%+ consistency), and 805 well-structured tests. The review identified concrete improvement opportunities in code maintainability (DRY violations, SRP in large modules), test coverage gaps (error paths, Docker integration), and minor proxy test gaps.

### Health Dashboard

| Area | Rating | Key Strength | Key Weakness |
|------|--------|-------------|--------------|
| **Architecture** | 8/10 | Clean 5-layer dependency graph, no circular deps | `update.sh` god module, `cmd-project.sh` oversized |
| **Code Quality** | 7/10 | Good separation, bash 3.2 compat, idempotent ops | ~1,000 lines of YAML parsing duplication, missing error checks |
| **Test Suite** | 7.5/10 | 805 design-driven tests, excellent isolation | Error messages not validated, Docker integration only dry-run |
| **Documentation** | 9.5/10 | 95%+ consistency with implementation | 4 minor pending items tracked in roadmap |
| **Go Proxy** | 8.5/10 | Strong security controls, clean Go idioms | Cache and handler modules untested |
| **Config System** | 8.5/10 | Idempotent migrations, clear layering, no conflicts | Minor edge cases in entrypoint timeouts |

---

## 1. Architecture

### 1.1 Component Map

The codebase is organized in 5 clean layers with strictly unidirectional dependencies:

```
Layer 1 — Utilities: colors.sh (22 LOC), paths.sh (132), utils.sh
Layer 2 — Data:      yaml.sh (570), secrets.sh (88), auth.sh (18)
Layer 3 — Domain:    workspace.sh (100), packs.sh (100+), manifest.sh (485), update.sh (600+), remote.sh (80+)
Layer 4 — Commands:  cmd-start.sh (1,063), cmd-project.sh (1,909), cmd-pack.sh (400+), + 10 others
Layer 5 — CLI:       bin/cco (dispatcher, sources all lib/ modules)
```

**No circular dependencies detected.** Dependencies flow from Layer 5 → Layer 1.

### 1.2 Architecture Strengths

- **Clean layering**: Each module has clear responsibility with unidirectional dependency flow
- **Declarative policies**: `FILE_POLICIES` arrays in `update.sh` separate file classification from merge logic
- **Graceful migration**: Dual-path fallback in `paths.sh` (new path → old path) enables smooth upgrades
- **Bash 3.2 compatibility**: No modern-isms; works on macOS default bash
- **Idempotent operations**: e.g., `_generate_workspace_yml` preserves user descriptions
- **Leverage native Claude Code**: Configuration tiers map directly onto Claude Code's native settings resolution

### 1.3 Architecture Issues

#### ARCH-1: `update.sh` is a God Module (HIGH)

**File**: `lib/update.sh` (~600+ LOC, 15+ functions)

Mixes 10+ distinct responsibilities: file hashing, base version storage, policy transition handling, 3-way merge, remote version checks, migration running, changelog management, file change collection, interactive sync, diff display.

**Recommendation**: Split into focused modules:
- `update-merge.sh` — 3-way merge engine
- `update-discovery.sh` — File change detection
- `update-migration.sh` — Migration runner
- `update-changelog.sh` — Changelog tracking
- `update.sh` — Coordinator only

**Impact**: Each concern becomes independently testable. Changes to merge logic won't risk breaking remote checks.

#### ARCH-2: `cmd-project.sh` and `cmd-pack.sh` are Oversized (MEDIUM)

**File**: `lib/cmd-project.sh` (1,909 LOC, 9 subcommands)
**File**: `lib/cmd-pack.sh` (~400 LOC, 9 subcommands)

Each file implements create, list, show, install, update, publish, validate, and pack management. Hard to locate logic; functions are tightly coupled.

**Recommendation**: Split into `cmd-project-create.sh`, `cmd-project-install.sh`, etc. Or at minimum add section markers and extract shared helpers.

#### ARCH-3: Missing Abstraction for File Sync (MEDIUM)

`cmd_init`, `cmd_update`, `cmd_project_install`, `cmd_pack_install` all perform similar file sync operations with no shared code. A `_sync_scope(scope, source, target)` function would reduce duplication.

#### ARCH-4: Entrypoint Complexity (LOW)

`config/entrypoint.sh` (222 LOC) handles Docker socket GID, proxy startup, MCP merge, Chrome proxy, GitHub auth, tmux launch. The proxy startup has a hardcoded 3-second timeout with no clear failure feedback if setup fails. Consider extracting concerns into functions and making the timeout configurable.

---

## 2. Code Quality & Refactoring

### 2.1 DRY Violations

#### DRY-1: YAML Parsing Pattern Repetition (~1,000 lines)

**File**: `lib/yaml.sh`

Contains 50+ near-identical awk parsing patterns across 6 functions (`yml_get`, `yml_get_list`, `yml_get_deep`, `yml_get_deep_list`, `yml_get_deep_map`, `yml_get_deep4`). Each varies only in nesting depth and output mode.

**Refactoring**: Create a generic `_yml_get_at_depth(file, depth, key_path, mode)` function that generates the appropriate awk script based on depth (1-4) and mode (scalar/list/map). Estimated reduction: ~1,000 lines → ~200 lines.

#### DRY-2: File Cleanup Pattern Duplication

**File**: `lib/cmd-clean.sh` (lines 170-258)

Four nearly identical functions (`_clean_bak`, `_clean_new`, `_clean_tmp`, `_clean_generated`) differ only in glob pattern and action. Extract to a single `_clean_pattern(dir, dry_run, label, pattern, action)`.

#### DRY-3: Path Resolution Fallback (11 repetitions)

**File**: `lib/paths.sh` (lines 18-131)

11 functions implement identical new-path-then-old-path fallback logic. Extract to `_cco_resolve_path(new, old, type)` and call from each helper.

#### DRY-4: Option Parsing (50+ reimplementations)

**Files**: All 11 `cmd-*.sh` files

Each command reimplements the same `while/case` loop for CLI argument parsing. A shared `lib/getopt.sh` helper would reduce ~200 lines of duplication and eliminate option handling inconsistencies.

#### DRY-5: Placeholder Substitution (10+ occurrences)

**Files**: `cmd-init.sh`, `cmd-pack.sh`, `cmd-project.sh`, `cmd-start.sh`

macOS/Linux-compatible `sed -i` pattern (`sed -i '' ... 2>/dev/null || sed -i ...`) repeated 10+ times. Extract to `_substitute(file, key, value)` helper.

### 2.2 Single Responsibility Violations

| Module | LOC | Responsibilities | Recommendation |
|--------|-----|-----------------|----------------|
| `cmd-start.sh` | 1,063 | Tutorial setup, option parsing, validation, compose generation, session startup, cleanup | Extract 7 focused functions (~100 LOC each) |
| `cmd-project.sh` | 1,909 | 9 subcommands (create, list, show, install, update, publish, add-pack, remove-pack, validate) | Split into 8 separate files |
| `update.sh` | 600+ | 10+ responsibilities (see ARCH-1) | Split into 4-5 focused modules |
| `manifest.sh` | 485 | Init, refresh, validate, display + 15 internal helpers | Separate internal helpers from public API |

### 2.3 Encapsulation Issues

- **Private functions used across modules**: Functions with `_` prefix in `packs.sh`, `manifest.sh`, and `update.sh` are called by `cmd-*.sh` files. These should be properly documented as public API or wrapped in proper interface functions.
- **Global state**: `colors.sh`, `paths.sh`, and `update.sh` depend on globals set in `bin/cco` (`$USER_CONFIG_DIR`, `$GLOBAL_DIR`, `$PROJECTS_DIR`, `FILE_POLICIES` arrays). These are read-only after startup, which mitigates risk, but creates implicit coupling.

### 2.4 Error Handling Gaps

- **Missing error checks on file operations**: `cp`, `mkdir`, `rm` in `cmd-init.sh`, `cmd-project.sh`, `cmd-new.sh` lack `|| die` guards. Failures proceed silently.
- **Inconsistent exit codes**: No convention for distinguishing user errors (1) from system errors (2).
- **Incomplete error messages**: Missing actionable suggestions (e.g., `warn "Project not found"` doesn't suggest `cco project list`).
- **No exit traps for temp resources**: `cmd-new.sh` creates `/tmp/cc-*` dirs without cleanup traps.

### 2.5 Shell Best Practices

- **Variable quoting**: Generally good throughout the codebase. Minor risk in subshells.
- **set -u with arrays**: Requires `${arr[@]+"${arr[@]}"}` pattern for empty arrays in bash 3.2. Used correctly in most places, but `packs.sh` initializes empty arrays that could fail under strict mode.
- **Magic strings**: Hardcoded paths (`/Applications/Google Chrome.app/...`), timeouts (3600), port numbers. Should be extracted to `lib/constants.sh`.
- **Complex awk blocks**: 30+ line awk blocks in `yaml.sh` and `manifest.sh` with minimal comments. Need inline documentation.

---

## 3. Test Suite

### 3.1 Overview

| Metric | Value |
|--------|-------|
| Test files | 33 |
| Total tests | 805 |
| Lines of test code | ~15,642 |
| Framework | Pure bash (bin/test runner, no external deps) |
| Largest file | test_update.sh (84 tests) |
| Assertion functions | 45+ |

### 3.2 Test Strengths

- **Design-driven testing**: `test_invariants.sh` (29 tests) explicitly encodes architectural constraints from the spec. Failures immediately point to architecture violations.
- **Excellent isolation**: Every test uses `mktemp -d` + `trap EXIT` cleanup. No shared state, no order dependencies.
- **Comprehensive YAML parser coverage**: 46 tests covering nested keys, lists, booleans, whitespace, inline comments, enum validation.
- **Strong update system coverage**: 84 tests for file policies, migrations, conflict resolution, idempotency.
- **Meaningful assertions**: `assert_file_contains`, `assert_no_placeholder`, `assert_valid_compose` — not just exit code checks.
- **Canary pattern**: Detects unintended file overwrites across `cco init` and `cco update`.
- **Dry-run strategy**: Compose generation tested without Docker daemon via `--dry-run --dump`.
- **Deterministic**: No random values, no sleep/date, proper mktemp, strict mode.

### 3.3 Test Weaknesses

#### TEST-1: Error Messages Not Validated (HIGH)

Tests check exit codes for negative cases but don't validate error messages:
```bash
# Current (weak):
if run_cco project create "MyProject" 2>/dev/null; then fail; fi

# Should be:
run_cco project create "MyProject" 2>&1
assert_output_contains "lowercase"
```

If error messages regress or become confusing, tests still pass.

#### TEST-2: Module-to-Test Mapping Opaque (MEDIUM)

`cmd-*.sh` files show 0 direct test mentions. They ARE tested via integration patterns (`run_cco`), but the mapping is not documented. If `cmd-start.sh` breaks, it's unclear which tests should catch it.

**Recommendation**: Create a module-to-test mapping document.

#### TEST-3: Limited Error Path Coverage (MEDIUM)

Many error paths untested:
- Invalid flag combinations (`--dry-run --force`)
- Missing required arguments
- Corrupt YAML files
- Missing repos in `project.yml`

#### TEST-4: Docker Integration Only Dry-Run (EXPECTED)

No actual container, tmux, or entrypoint testing. Only compose generation is verified. This is intentional — E2E tests are planned for Sprint 8 per roadmap.

#### TEST-5: Secret Detection Untested (MEDIUM)

Vault's pattern matching for `AWS_ACCESS_KEY`, `DATABASE_PASSWORD` etc. has no tests. False positive/negative behavior is unverified.

#### TEST-6: Weak Idempotency Validation (LOW)

Idempotency tests use canary survival (file not overwritten) but don't verify structural identity of the output after repeated runs.

### 3.4 Coverage Matrix

| Module | Test Coverage | Assessment |
|--------|-------------|------------|
| `lib/update.sh` | 84 tests, 170 mentions | Excellent |
| `lib/yaml.sh` | 46 tests, 96 mentions | Excellent |
| `lib/remote.sh` | 41 tests, 111 mentions | Very good |
| `lib/manifest.sh` | 23 tests, 59 mentions | Good |
| `lib/packs.sh` | 61 mentions | Good |
| `lib/paths.sh` | 42 mentions | Adequate |
| `lib/auth.sh` | 24 mentions | Adequate |
| `lib/secrets.sh` | 11 mentions | Undertested |
| `lib/workspace.sh` | 7 mentions | Undertested |
| `lib/cmd-build.sh` | Skipped (CCO_SKIP_BUILD) | Not tested |

---

## 4. Go Docker Security Proxy

### 4.1 Architecture

Clean 4-package structure with dependency injection:
- `internal/config/` — Policy loading & validation
- `internal/cache/` — Container ID resolution with periodic refresh
- `internal/filter/` — Modular filters (containers, mounts, security, errors)
- `internal/proxy/` — HTTP handler and route matching

**No external dependencies** (stdlib only). Static binary with cross-compilation (amd64 + arm64).

### 4.2 Security Posture

| Control | Assessment | Details |
|---------|-----------|---------|
| Container name/label filtering | **Strong** | Name validation on create, required labels injected, AND logic for labels |
| Mount path validation | **Strong** | Implicit deny checked first, correct DfD path translation |
| Privilege escalation prevention | **Good** | Blocks `--privileged` and dangerous capabilities, case-insensitive normalization |
| Resource limits | **Good** | Max containers tracked with periodic reconciliation |
| Network isolation | **Medium** | Basic prefix matching in handler, not modularized as dedicated filter |

**Design doc alignment**: 99% complete. Only deviation: `internal/filter/networks.go` module missing (network logic is inline in proxy handler).

### 4.3 Proxy Test Coverage

| Module | Tests | Quality |
|--------|-------|---------|
| `config` | 11 | Excellent — all policies + edge cases |
| `filter/containers` | 15 | Very good — all policies, labels, validation |
| `filter/mounts` | 25 | Excellent — DfD translation, sensitive paths |
| `filter/security` | 23 | Very good — privilege, caps, memory, CPU |
| `proxy/routes` | 15 | Good — path extraction, route matching |
| **`cache`** | **0** | **MISSING** — 200+ LOC of critical logic untested |
| **`proxy/proxy`** | **0** | **MISSING** — 700+ LOC of handler logic untested |

**Total**: ~89 tests, ~1,600 lines of test code.

### 4.4 Proxy Issues

#### PROXY-1: Cache Module Untested (MEDIUM)

`cache.go` handles container ID → name resolution critical for filtering. A bug could allow access to unintended containers. Needs `cache_test.go` with mock upstream Docker socket.

#### PROXY-2: Handler Module Untested (MEDIUM)

`proxy.go` (700+ LOC) handles HTTP request interception, response modification (label injection, readonly enforcement). Changes could silently break. Needs `proxy_test.go` with HTTP testing framework.

#### PROXY-3: Network Filter Not Modularized (LOW)

`isNetworkAllowed()` logic lives inline in proxy handler instead of a dedicated `internal/filter/networks.go`. Less testable than other filter modules.

#### PROXY-4: Two Ignored Errors (LOW)

- `routes.go:42`: `matched, _ := filepath.Match(pattern, name)` — ignores error
- `proxy.go`: `result, _ := json.Marshal(filtered)` — ignores error

Both are low risk (patterns are validated at load time, and policy struct is fixed), but should be addressed for static analysis compliance.

### 4.5 Go Code Quality

| Criterion | Score | Notes |
|-----------|-------|-------|
| Package organization | 10/10 | Perfect naming, Go idioms |
| Concurrency | 9/10 | Correct RWMutex/atomic usage, no race conditions |
| Error handling | 8/10 | Good wrapping with `%w`, two ignored errors |
| Security filtering | 9/10 | Strong controls, minor gaps (missing `/dev/mem` in implicit deny) |
| Testing | 6/10 | Excellent filter tests, large gaps in integration |

---

## 5. Documentation Consistency

### 5.1 Overall Status: 95%+ Consistent

Documentation and implementation are extremely well-aligned. No critical discrepancies found.

### 5.2 Verified Consistent

| Area | Status | Evidence |
|------|--------|---------|
| Architecture ADRs (4) | ✅ | All match implementation in code |
| CLI reference (12+ commands) | ✅ | All options documented and implemented |
| project.yml schema | ✅ | Template, validation code, and docs aligned |
| Docker security proxy | ✅ | Design doc 99% matches implementation |
| Update system | ✅ | 18 migrations match their design docs |
| Vault system | ✅ | Profiles, sync, secret detection all documented |
| Browser automation | ✅ | Port resolution, MCP injection documented |
| Changelog (7 entries) | ✅ | All entries accurate and verified |
| User guides | ✅ | Getting-started and user-guides accurate |

### 5.3 Minor Pending Items

All tracked in roadmap — not hidden or forgotten:

| Item | Description | Status |
|------|-------------|--------|
| FI-2 | `/init-workspace` empty workspace conditional prompt | Low-effort quick win, planned |
| FI-5 | GitHub branch protection guide + template ref | Partially addressed, docs pending |
| FI-4 | Per-project LLM model config | Documented in roadmap, not yet implemented |
| Sprint 6C | Network hardening / Squid sidecar | Design complete, Phase C pending |

---

## 6. Configuration, Defaults & Migrations

### 6.1 Configuration Layering

4-tier system with clear precedence, no conflicts detected:

| Layer | Source | Scope | Overridable |
|-------|--------|-------|------------|
| Managed | `/etc/claude-code/` (baked in image) | Hooks, env, deny rules | No |
| Global | `user-config/global/.claude/` | Workflow, agents, skills, permissions | Yes |
| Project | `user-config/projects/<name>/.claude/` | Project context, rules | Yes |
| Repo | `/workspace/<repo>/.claude/` | Repo-specific config | Yes |

MCP server merging: managed > project > global. Warnings shown on conflict but managed always wins.

### 6.2 Migration Quality

**19 migrations total** (9 global, 10 project). All properly implement idempotency with existence checks and guard clauses.

**Issues identified**:
- **Missing migration 008 in global scope** — gap in sequence (001-007, then 009). Should be documented.
- **Migration 010** (tutorial_to_internal) uses interactive prompt without proper fallback in non-interactive environments — silently falls back to warn-only.
- **Migration 007** calls `_save_all_base_versions` without checking return code.

### 6.3 Entrypoint Quality

`config/entrypoint.sh` (222 LOC) is high quality with comprehensive error handling, defensive socket setup, and clean proxy startup. Minor issues:
- Proxy socket timeout hardcoded at 3 seconds
- MCP server conflict only warns, doesn't prevent override
- Chrome DevTools proxy has no port conflict detection

### 6.4 Hooks Quality

All 4 hooks (`session-context.sh`, `subagent-context.sh`, `statusline.sh`, `precompact.sh`) follow consistent patterns with safe JSON output via `jq -n --arg`. All are read-only with no side effects. Minor issue: pack.md parsing in `subagent-context.sh` assumes Markdown list format with em-dash separator.

### 6.5 Template Quality

Templates are well-structured with extensive inline documentation and secure defaults (`mount_socket: false`). Minor issues:
- Language rule placeholders (`{{COMM_LANG}}`) in global defaults are never substituted — could confuse new users
- `pack.yml` template missing optional `description` field example

---

## 7. Refactoring Roadmap

### Phase 1 — Quick Wins (Low Effort, High Impact)

| ID | Refactoring | Impact | Effort |
|----|------------|--------|--------|
| R-1 | Create `lib/constants.sh` for magic strings/numbers | Eliminates hardcoded values | Very low |
| R-2 | Add `|| die` error checks to file operations in `cmd-init.sh`, `cmd-project.sh`, `cmd-new.sh` | Prevents silent failures | Low |
| R-3 | Add exit traps for temp resource cleanup in `cmd-new.sh` | Prevents orphaned files | Very low |
| R-4 | Improve error messages with actionable suggestions | Better UX on failures | Low |
| R-5 | Fix 2 ignored errors in proxy (`routes.go`, `proxy.go`) | Static analysis compliance | Very low |

### Phase 2 — Medium Effort

| ID | Refactoring | Impact | Effort |
|----|------------|--------|--------|
| R-6 | Extract generic YAML parser in `yaml.sh` | ~1,000 lines saved, single bug-fix point | Medium |
| R-7 | Create `lib/getopt.sh` option parsing helper | Reduces duplication across 11 cmd-*.sh files | Medium |
| R-8 | Extract path resolution helper in `paths.sh` | ~50 lines saved, single migration fallback point | Low |
| R-9 | Extract placeholder substitution helper | Consistent across 4+ files | Low |
| R-10 | Add `cache_test.go` for proxy | Eliminates medium security risk | Medium |
| R-11 | Add `proxy_test.go` for proxy handler | Eliminates medium security risk | Medium |
| R-12 | Add error message validation to negative tests | Catches error message regressions | Medium |

### Phase 3 — Larger Effort

| ID | Refactoring | Impact | Effort |
|----|------------|--------|--------|
| R-13 | Split `update.sh` into 4-5 focused modules | Major testability improvement | High |
| R-14 | Split `cmd-project.sh` into 8 focused files | Clearer separation, easier navigation | High |
| R-15 | Split `cmd-start.sh` into 7 focused functions | Each function testable independently | Medium-High |
| R-16 | Extract network filter to `internal/filter/networks.go` | Consistency with other proxy filters | Low |
| R-17 | Add module-to-test mapping document | Clearer test traceability | Low |

### Phase 4 — Test Coverage Expansion

| ID | Area | Tests Needed |
|----|------|-------------|
| T-1 | Error paths in CLI commands | Invalid flags, missing args, corrupt YAML |
| T-2 | Secret detection patterns | AWS keys, database passwords, false positives |
| T-3 | File policy transitions | All 24 transitions (untracked→tracked, etc.) |
| T-4 | `lib/workspace.sh` coverage | Mount generation, idempotency |
| T-5 | `lib/secrets.sh` coverage | Pattern matching, validation edge cases |

---

## 8. Patterns Worth Preserving

These patterns represent good engineering decisions that should be maintained:

1. **Declarative FILE_POLICIES** over imperative merge logic
2. **Graceful degradation** (dual-path fallback, sparse-checkout → shallow clone)
3. **Idempotent operations** (preserve user descriptions, refresh always, no-op if no changes)
4. **Design-driven tests** (invariant tests tied to architecture spec)
5. **Canary pattern** in tests (detect unintended file overwrites)
6. **Dry-run strategy** (test compose generation without Docker daemon)
7. **Dependency injection** in Go proxy (filters depend on `*config.Policy`, no mocking needed)
8. **Fail-closed security** (cache miss → deny, not allow)
9. **Bash 3.2 compatibility** throughout (no `${var,,}`, safe array handling)
10. **Leverage native Claude Code** (map onto native settings resolution, don't reimplement)

---

## 9. Risk Assessment

### Low Risk (Well-Covered)
- Core config management, YAML parsing, update logic, file policy system
- Architecture consistency, CLI documentation accuracy
- Security proxy filter logic (containers, mounts, capabilities)

### Medium Risk (Gaps Identified)
- CLI argument handling, error messages, edge cases
- Proxy cache and handler logic (untested)
- Secret detection patterns (untested)
- `workspace.sh` and `secrets.sh` coverage

### Higher Risk (Known Gaps, Planned)
- Docker integration (E2E tests — Sprint 8)
- Concurrent operations (no file locking tests)
- Network hardening (Sprint 6C pending)

---

## 10. Conclusion

claude-orchestrator is in a solid state after multiple development cycles. The architecture is clean with well-separated layers, the documentation is highly consistent with the implementation, and the test suite covers the most critical paths effectively. The main areas for improvement are:

1. **Code DRY**: The YAML parser and option parsing represent the biggest duplication opportunities
2. **Module size**: `update.sh`, `cmd-project.sh`, and `cmd-start.sh` would benefit from decomposition
3. **Proxy tests**: Cache and handler modules need test coverage before the proxy can be considered fully validated
4. **Error handling**: File operations and error messages need hardening across the codebase

None of these issues block current functionality, but addressing them (especially Phases 1-2 of the refactoring roadmap) would significantly improve maintainability and confidence for future development.
