# Testing Strategy

> Related: [roadmap.md](../decisions/roadmap.md) | [spec.md](spec.md)

---

## Test Taxonomy

The test suite is organized into three tiers, each with different scope, speed, and requirements:

| Tier | Runner | Docker Required | What It Tests | When to Run |
|------|--------|-----------------|---------------|-------------|
| **Unit** | `bin/test` | No | Pure logic: YAML parsing, validation, enum checks | Every iteration |
| **Integration** | `bin/test` | No | CLI commands via `--dry-run`, file-system assertions | Every iteration, pre-merge |
| **E2E** | `bin/test-e2e` | Yes (real containers) | Container behavior, entrypoint, mounts, socket, auth | Pre-release, CI |

### Tier 1 — Unit Tests

Test pure functions in isolation, with no CLI invocation or filesystem setup.

**Pattern**: source the module directly, call the function, assert the result.

```bash
test_yaml_parser_deep_3level_value() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    local tmpfile; tmpfile=$(mktemp); trap "rm -f '$tmpfile'" EXIT
    cat > "$tmpfile" <<'YAML'
docker:
  containers:
    policy: allowlist
YAML
    local result
    result=$(yml_get_deep "$tmpfile" "docker.containers.policy")
    assert_equals "allowlist" "$result"
}
```

**Files**: `test_yaml_parser.sh` (parsing), `test_invariants.sh` (design invariants), `test_managed_scope.sh` (static checks only)

**Typical time**: 10-60ms per test

### Tier 2 — Integration Tests

Test CLI commands end-to-end via `run_cco`, with filesystem isolation per test. These never start real Docker containers — they either use `--dry-run` or test commands that operate purely on config files (`init`, `project create`, `pack install`, etc.).

**Pattern**: `setup_cco_env` + `create_project` + `run_cco` + assertions on generated files.

```bash
test_start_generates_compose() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "myapp" "$(minimal_project_yml myapp)"
    run_cco start "myapp" --dry-run
    assert_file_contains "$CCO_PROJECTS_DIR/myapp/docker-compose.yml" "PROJECT_NAME=myapp"
}
```

**Files**: `test_start_dry_run.sh`, `test_docker_security.sh`, `test_init.sh`, `test_project_*.sh`, `test_pack_*.sh`, `test_vault.sh`, `test_update.sh`, `test_manifest.sh`, etc.

**Typical time**: 30-200ms per test (fast), 500-1000ms for tests involving `cco init` or git operations.

**Important**: `cco init` triggers `docker build` as a side effect, but **no integration test depends on the built image**. The test runner exports `CCO_SKIP_BUILD=1` to skip this, saving ~5s per invocation. See [Performance](#performance) section.

### Tier 3 — E2E Tests (Sprint 8, not yet implemented)

Will test real container behavior: entrypoint execution, volume mounts, socket permissions, auth flow, tmux session startup.

**Planned runner**: `bin/test-e2e` (separate from `bin/test`)
**Planned location**: `tests/e2e/`
**Requires**: Docker daemon available, built image
**See**: [roadmap.md — Sprint 8-E2E](../decisions/roadmap.md) for full scope

---

## Test Runner (`bin/test`)

### Usage

```bash
bin/test                                # Run all tests
bin/test --file test_yaml_parser        # Run only one file
bin/test --filter deep                  # Run tests matching substring
bin/test --file test_init --filter force # Combine file + name filter
bin/test --verbose                      # Show output from passing tests
bin/test --list                         # List all test names without running
```

### Architecture

1. Sources `tests/helpers.sh` and `tests/mocks.sh` into the parent shell
2. Discovers `test_*()` functions via grep on each `tests/test_*.sh` file
3. Sources each test file (loads functions into current shell)
4. Runs each test function in a **subshell** for isolation
5. Captures output and exit code, measures elapsed time
6. Reports pass/fail with timing

### Environment

The test runner automatically sets:
- `CCO_SKIP_BUILD=1` — skips Docker image build in `cco init` (not needed for integration tests)
- `REPO_ROOT` — absolute path to the repository root

Each test should create its own tmpdir and use `setup_cco_env` to redirect all CCO paths there.

---

## Selective Execution Guide

During development, run only the tests relevant to the module you changed:

| Changed file(s) | Test command |
|-----------------|-------------|
| `lib/cmd-start.sh` | `bin/test --file test_start_dry_run --file test_docker_security --file test_invariants` |
| `lib/yaml.sh` | `bin/test --file test_yaml_parser` |
| `lib/cmd-pack.sh`, `lib/packs.sh` | `bin/test --file test_pack_cli --file test_packs --file test_pack_install --file test_pack_internalize --file test_pack_publish` |
| `lib/cmd-project-create.sh` | `bin/test --file test_project_create` |
| `lib/cmd-project-query.sh` | `bin/test --file test_project_list --file test_project_show` |
| `lib/cmd-project-install.sh` | `bin/test --file test_project_install` |
| `lib/cmd-project-publish.sh` | `bin/test --file test_project_publish --file test_publish_install_sync` |
| `lib/cmd-project-update.sh` | `bin/test --file test_project_install_enhanced --file test_publish_install_sync` |
| `lib/cmd-project-pack-ops.sh` | `bin/test --file test_project_pack` |
| `lib/cmd-init.sh` | `bin/test --file test_init` |
| `lib/cmd-vault.sh` | `bin/test --file test_vault --file test_vault_profiles` |
| `lib/update*.sh`, `lib/cmd-update.sh` | `bin/test --file test_update --file test_merge` |
| `lib/manifest.sh` | `bin/test --file test_manifest` |
| `lib/cmd-remote.sh`, `lib/remote.sh` | `bin/test --file test_remote` |
| `lib/auth.sh` | `bin/test --file test_auth` |
| `lib/cmd-chrome.sh` | `bin/test --file test_chrome` |
| `lib/cmd-clean.sh` | `bin/test --file test_clean` |
| `lib/cmd-stop.sh` | `bin/test --file test_stop` |
| `lib/cmd-template.sh` | `bin/test --file test_template` |
| `lib/paths.sh` | `bin/test --file test_paths` |
| `lib/secrets.sh` | `bin/test --file test_secrets` |
| `lib/workspace.sh` | `bin/test --file test_packs` |
| `lib/colors.sh`, `lib/utils.sh` | Utility libraries — covered indirectly by all test files |
| `lib/cmd-build.sh`, `lib/cmd-new.sh` | No unit/integration test (Docker-dependent) |
| `proxy/**` | `bin/test --file test_docker_security` + `cd proxy && go test ./...` |
| `config/entrypoint.sh` | No unit/integration test (E2E only, Sprint 8) |
| `Dockerfile` | No unit/integration test (E2E only, Sprint 8) |

**Pre-merge**: always run the full suite (`bin/test`) to catch cross-module regressions.

---

## Performance

### Profiling (as of 2026-03-19, 827 tests across 33 files)

| File | Time | Tests | Avg | Bottleneck |
|------|------|-------|-----|------------|
| `test_init` | 62s | 14 | 4.5s | `cco init` → `docker build` |
| `test_vault` | 27s | 39 | 686ms | `cco init` + git ops |
| `test_tutorial` | 17s | 18 | 935ms | `cco init` ×20 |
| `test_update` | 15s | 29 | 505ms | `cco init` + migrations |
| `test_manifest` | 14s | 23 | 612ms | `cco init` + manifest ops |
| `test_managed_scope` | 10s | 17 | 566ms | `cco init` ×12 |
| All other files (27) | — | — | — | Fast — no `cco init` |
| **Total** | **—** | **827** | **—** | |

### Root Cause

94 invocations of `cco init` across 10 test files. Each `cco init` triggers `docker build` (~5s with layer cache), which is a side effect irrelevant to what the tests verify (file copy, placeholder substitution, config validation).

### Mitigation: `CCO_SKIP_BUILD`

The test runner exports `CCO_SKIP_BUILD=1`. When set, `cmd_init` skips the `docker build` step entirely. This is safe because:

1. **No test asserts on the Docker image** — all assertions check file-system state
2. `cco init` already degrades gracefully when Docker is unavailable (warns, continues)
3. E2E tests (Sprint 8) will have their own runner (`bin/test-e2e`) that requires Docker

**Impact**: full suite drops from ~180s to ~35s (~5x speedup).

---

## Writing New Tests

### Conventions

- File name: `tests/test_<module>.sh`
- Function name: `test_<module>_<what_is_tested>()` — must start with `test_`
- Each test creates its own tmpdir: `local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT`
- Use `setup_cco_env "$tmpdir"` to redirect CCO paths
- Use `setup_global_from_defaults "$tmpdir"` if the test needs global config
- Use `create_project` / `create_pack` helpers for fixture creation
- Use `minimal_project_yml` for tests that only need a valid project

### Assertions

| Function | Purpose |
|----------|---------|
| `assert_equals` | Compare two strings |
| `assert_empty` | Check string is empty |
| `assert_file_exists` / `assert_file_not_exists` | File presence |
| `assert_dir_exists` / `assert_dir_not_exists` | Directory presence |
| `assert_file_contains` / `assert_file_not_contains` | Literal string in file (grep -F) |
| `assert_output_contains` / `assert_output_not_contains` | Check `$CCO_OUTPUT` from `run_cco` |
| `assert_no_placeholder` / `assert_no_placeholders` | No `{{...}}` patterns remain |
| `assert_valid_compose` | Structural check on generated docker-compose.yml |

### Tips

- **Prefer unit tests** for pure logic (YAML parsing, validation). They're 10x faster than integration tests.
- **Use `--dry-run`** for `cco start` tests — it generates the compose file without invoking Docker.
- **Avoid `cco init`** if you only need global config — use `setup_global_from_defaults` directly.
- **Name tests descriptively** — the test name is the documentation. `test_policy_fractional_cpus` is clear; `test_policy_3` is not.
- **One concern per test** — a test should verify one behavior. Multiple assertions are fine if they check facets of the same behavior.

### Go Tests (proxy)

The proxy module has its own Go test suite:

```bash
cd proxy && go test ./...           # Run all proxy tests
cd proxy && go test ./internal/filter/  # Run specific package
```

These tests are pure unit tests — no Docker, no filesystem, no CLI. They test policy filtering logic in isolation.

**Note**: Go is not installed in the container. Proxy tests run during `docker build` (multi-stage). To run them locally, install Go 1.22+ on the host.
