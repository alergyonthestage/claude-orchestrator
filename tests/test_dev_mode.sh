#!/usr/bin/env bash
# tests/test_dev_mode.sh — developer execution mode: IDENTITY (A10.1)
#
# Contract source: ADR-0060 (D1, D2, D3, D7, D8) + the living design
# `docs/maintainers/engineering/design/dev-execution-mode.md` §3 (flag, dispatch,
# resolution order), §4 (image mapping), §6.1 (in-container refusal), §6.3
# (clone-without-`--dev` note), §9 (what does NOT change), §10 (DoD).
# Every assertion below is derived from those documents, never from the code.
#
# What A10.1 owns — and only this:
#   - `--dev` / `--dev=<path>` / `CCO_DEV=1`, the argv scan that STOPS at `--`,
#     and the two legacy flags as superseded aliases                     (§3.2)
#   - target resolution + validation + dispatch, with the identity and
#     second-dispatch loop guards                                        (§3.3)
#   - `_cco_dev_image` and its TWO application points, plus `check_image`  (§4)
#   - the in-container refusal                                          (§6.1)
#   - the clone-provenance note when dev mode was NOT requested          (§6.3)
# The snapshot store, `cco dev <sub>`, `project.dev.yml` and the `cco start`
# build-ref warn are A10.2 and are deliberately NOT asserted here.
#
# ── Oracles, and why the obvious ones are refused ────────────────────
#   * `cco --version` is NON-DISCRIMINATING (ADR-0060 M3: npm and the clone are
#     both 0.6.0). It is used here only as a cheap VERB, never as evidence of
#     which code ran.
#   * `docker run` is never used: in-session it returns rc 0 with empty stdout
#     (FI-82). The image half is asserted on the RESOLVED IMAGE NAME — the
#     generated compose's `image:` line and the `docker build -t` argument — so
#     these tests need no daemon at all. Proving that a real `cco build` produces
#     `…-dev:latest` while leaving `claude-orchestrator:latest` untouched is a
#     HOST acceptance step (`docker image inspect` on both tags), not a suite test.
#   * "did the dispatcher dispatch" is answered by a stub clone that PRINTS a
#     marker and its argv — not by `which cco`, which answers PATH order.
#
# ── Environment traps this file is written against ───────────────────
#   * This suite runs INSIDE cco's own self-dev container, so `/.dockerenv`
#     exists and `_cco_in_container` is TRUE by default — and the dev block's
#     first act is an in-container refusal. Host mode is therefore FORCED with
#     CCO_IN_CONTAINER=0 everywhere (=1 for the in-container branch). Without the
#     force these tests would refuse here and pass on a real host.
#   * The container also exports an ambient operator envelope
#     (CCO_CONTAINER_OPERATOR, CCO_*_HOME, CCO_SESSION_CONTEXT, PROJECT_NAME, …).
#     `_dm_cco` strips it explicitly, as test_dev_sandbox.sh's full-binary test does.
#   * A `die` inside `$( )` exits only the subshell, so every rc is captured from
#     the substitution itself (`out=$( … ) || rc=$?`), never from a `die` alone.
#
# ⚠ tests/test_dev_sandbox.sh is NOT touched: §9 pins
# `test_dev_sandbox_config_stays_shared` as the check that the CONFIG default did
# not move, and dev mode does not fork CONFIG.

# ── Fixtures ─────────────────────────────────────────────────────────

# A minimal HOST env with the dev knobs deliberately unset, for the two pure
# resolvers in lib/paths.sh. Mirrors _ds_env in test_dev_sandbox.sh.
_dm_lib_env() {
    export HOME="$1/home"; mkdir -p "$HOME"
    unset CCO_DEV CCO_DEV_REPO CCO_DEV_DISPATCHED CCO_IMAGE_NAME \
          CCO_DEV_SANDBOX CCO_DEV_SANDBOX_SEED CCO_DEV_SANDBOX_ROOT \
          CCO_CONTAINER_OPERATOR 2>/dev/null || true
    export CCO_IN_CONTAINER=0
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
}

# Invoke the REAL bin/cco in a clean host environment (see the header for why
# each strip/force is here). Caller sets:
#   DM_HOME          — a throwaway $HOME (required)
#   DM_IN_CONTAINER  — 0 (default) or 1
#   DM_ENV           — extra `VAR=value` env for this invocation (optional array)
_dm_cco() {
    env -u CCO_CONTAINER_OPERATOR -u CCO_DATA_HOME -u CCO_STATE_HOME -u CCO_CACHE_HOME \
        -u CCO_CCO_ACCESS -u CCO_CLAUDE_ACCESS -u CCO_SHOW_HOST_PATHS -u CCO_CONFIG_TARGETS \
        -u CCO_ACCESS_TRIPLE -u PROJECT_NAME -u CCO_PROJECT_PACKS -u CCO_PROJECT_LLMS \
        -u CCO_SESSION_CONTEXT -u CCO_SUBAGENT_CONTEXT -u CCO_STORE_TOTALS \
        -u XDG_STATE_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME \
        -u CCO_DEV -u CCO_DEV_REPO -u CCO_DEV_DISPATCHED -u CCO_IMAGE_NAME \
        -u CCO_DEV_SANDBOX -u CCO_DEV_SANDBOX_SEED -u CCO_DEV_SANDBOX_ROOT \
        HOME="$DM_HOME" CCO_IN_CONTAINER="${DM_IN_CONTAINER:-0}" \
        CCO_SKIP_BUILD=1 CCO_NONINTERACTIVE=1 CCO_USER_CONFIG_DIR="$DM_HOME/.absent-vault" \
        ${DM_ENV[@]+"${DM_ENV[@]}"} \
        bash "$REPO_ROOT/bin/cco" "$@"
}

# A stand-in dev clone: it satisfies §3.3's validation (an EXECUTABLE bin/cco and
# a package.json naming @claude-orchestrator/cco) and its bin/cco announces both
# that it ran and the argv it received — so "which target did the dispatcher
# exec, and what did it hand over" is directly observable.
# Usage: _dm_stub_clone <dir> <tag>
_dm_stub_clone() {
    local dir="$1" tag="$2"
    mkdir -p "$dir/bin" "$dir/.git"
    printf '{ "name": "@claude-orchestrator/cco", "version": "9.9.9" }\n' > "$dir/package.json"
    cat > "$dir/bin/cco" <<STUB
#!/usr/bin/env bash
printf 'STUB-RAN=%s\n' '$tag'
printf 'STUB-ARGV='
for _a in "\$@"; do printf '[%s]' "\$_a"; done
printf '\n'
exit 0
STUB
    chmod +x "$dir/bin/cco"
}

# A project.yml with an OPTIONAL `docker.image` pin — the second application
# point of the mapping (§4). Called as "$(_dm_project_yml …)": the heredoc lives
# in the function body, never inside the command substitution (bash 3.2 / INV-B32).
# Usage: _dm_project_yml <name> [<image>]
_dm_project_yml() {
    local name="$1" image="${2:-}"
    cat <<YAML
name: $name
description: "dev-mode fixture"
auth:
  method: oauth
docker:
${image:+  image: $image}
  ports: []
  env: {}
repos:
  - name: dummy-repo
YAML
}

# A docker mock whose daemon is UP but that owns NO image: `docker info` succeeds,
# every `docker image inspect` fails. This is what makes check_image's missing-image
# branch reachable deterministically — asserting that `claude-orchestrator-dev:latest`
# is absent from the real daemon would break the moment the acceptance lane builds it.
_dm_mock_docker_no_images() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/docker" <<'MOCK'
#!/usr/bin/env bash
[[ -n "${DOCKER_CALL_LOG:-}" ]] && echo "$*" >> "${DOCKER_CALL_LOG}"
case "$1" in
    info)  exit 0 ;;
    image) exit 1 ;;          # no image exists → check_image must react
    ps)    exit 0 ;;
    *)     exit 0 ;;
esac
MOCK
    chmod +x "$dir/docker"
}

# The `image:` line of a generated compose — the resolved image name, which is the
# whole observable for §4. Usage: _dm_compose_image <dry-run-dir>
_dm_compose_image() {
    sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$1/.cco/docker-compose.yml" | head -1
}

# ── §4 — _cco_dev_image: the repository forks, the tag does not ──────

test_dev_mode_active_reads_the_env_toggle() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local out
    out=$(
        _dm_lib_env "$tmp"
        declare -F _cco_dev_active >/dev/null && echo "DEFINED=yes" || echo "DEFINED=no"
        echo "OFF=$(_cco_dev_active && echo yes || echo no)"
        export CCO_DEV=0
        echo "ZERO=$(_cco_dev_active && echo yes || echo no)"
        export CCO_DEV=1
        echo "ON=$(_cco_dev_active && echo yes || echo no)"
    )
    [[ "$out" == *"DEFINED=yes"* ]] \
        || fail "_cco_dev_active() must exist in lib/paths.sh (ADR-0060 D1), got: $out"
    [[ "$out" == *"OFF=no"*  ]] || fail "dev mode must be OFF when CCO_DEV is unset, got: $out"
    [[ "$out" == *"ZERO=no"* ]] || fail "CCO_DEV=0 must not engage dev mode, got: $out"
    [[ "$out" == *"ON=yes"*  ]] || fail "CCO_DEV=1 must engage dev mode, got: $out"
}

# §4's table IS the oracle. The fourth row is the same rule stated as prose — "the
# tag separator is the last ':' after the last '/'" — and it is the case a naive
# last-colon split gets wrong in the opposite direction from row 3.
test_dev_mode_image_forks_the_repository_and_keeps_the_tag() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local out
    out=$(
        _dm_lib_env "$tmp"
        declare -F _cco_dev_image >/dev/null && echo "DEFINED=yes" || echo "DEFINED=no"
        for _img in "claude-orchestrator:latest" "myorg/custom" \
                    "localhost:5000/foo:1.0" "localhost:5000/foo"; do
            echo "MAP $_img -> $(_cco_dev_image "$_img")"
        done
    )
    [[ "$out" == *"DEFINED=yes"* ]] \
        || fail "_cco_dev_image() must exist in lib/paths.sh (ADR-0060 D3), got: $out"
    [[ "$out" == *"MAP claude-orchestrator:latest -> claude-orchestrator-dev:latest"* ]] \
        || fail "the default must map to claude-orchestrator-dev:latest, got: $out"
    [[ "$out" == *"MAP myorg/custom -> myorg/custom-dev"* ]] \
        || fail "an untagged image must fork the repository only, got: $out"
    [[ "$out" == *"MAP localhost:5000/foo:1.0 -> localhost:5000/foo-dev:1.0"* ]] \
        || fail "a registry host:port must not be mistaken for a tag, got: $out"
    [[ "$out" == *"MAP localhost:5000/foo -> localhost:5000/foo-dev"* ]] \
        || fail "with no ':' after the last '/', there is no tag to keep, got: $out"
}

# §4: a digest names ONE specific image and cannot be mapped ⇒ die. The mapped
# name must not be produced at all — a die that still echoes something would let a
# caller run the unmapped image, which is the incident this unit closes.
test_dev_mode_image_dies_on_a_digest_pin() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local digest="foo@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    local rc=0 mapped err
    mapped=$( _dm_lib_env "$tmp" >/dev/null 2>&1; _cco_dev_image "$digest" 2>/dev/null ) || rc=$?
    err=$( _dm_lib_env "$tmp" >/dev/null 2>&1; _cco_dev_image "$digest" 2>&1 >/dev/null ) || true
    [[ "$rc" -eq 1 ]] \
        || fail "a digest-pinned image must die (§4), got rc=$rc: ${err:-<no stderr>}"
    assert_empty "$mapped" "a digest-pinned image must not resolve to a mapped name" || return 1
    [[ "$err" == *"$digest"* ]] \
        || fail "the digest refusal must name the image it could not map, got: ${err:-<empty>}"
}

# ── §6.1 — the in-container refusal (and its complement) ─────────────

test_dev_mode_refuses_in_container() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local DM_HOME="$tmp/home"; mkdir -p "$DM_HOME"
    local DM_IN_CONTAINER=1
    local DM_ENV=()
    local spelling rc out
    for spelling in --dev --dev-sandbox --dev-sandbox-seed; do
        rc=0
        out=$(_dm_cco "$spelling" --version 2>&1) || rc=$?
        assert_refused "$rc" "$out" "host" || return 1
    done
    # The env spelling is one of the three accepted spellings (§3.2), so it takes
    # the same refusal — otherwise the flag would be refused while CCO_DEV=1
    # silently engaged, which is the false-success shape §6.1 exists to remove.
    DM_ENV=("CCO_DEV=1")
    rc=0
    out=$(_dm_cco --version 2>&1) || rc=$?
    assert_refused "$rc" "$out" "host" || return 1
}

# The refusal is gated on the FLAG, not on being in a container: an ordinary
# in-container invocation is untouched. Without this, "refuse everything" passes.
test_dev_mode_in_container_without_the_flag_is_untouched() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local DM_HOME="$tmp/home"; mkdir -p "$DM_HOME"
    local DM_IN_CONTAINER=1
    local rc=0 out
    out=$(_dm_cco --version 2>&1) || rc=$?
    [[ "$rc" -eq 0 ]] \
        || fail "in-container without --dev must not be refused, got rc=$rc: $out"
}

# ── §3 — dispatch: resolve, validate, hand off ───────────────────────

test_dev_mode_dispatches_into_the_resolved_target() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local DM_HOME="$tmp/home"; mkdir -p "$DM_HOME"
    _dm_stub_clone "$tmp/target" "TARGET"
    local rc=0 out
    out=$(_dm_cco --dev="$tmp/target" --version 2>&1) || rc=$?
    [[ "$out" == *"STUB-RAN=TARGET"* ]] \
        || fail "--dev=<path> must exec into the target clone (D1), got rc=$rc: $out"
}

# §3.2: the scan STOPS at the first `--`; `--` and everything after it are passed
# through VERBATIM. The two dev spellings placed after `--` are the discriminating
# payload — a consume-from-anywhere scan swallows them and the sequence breaks.
test_dev_mode_argv_terminator_is_passed_through_verbatim() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local DM_HOME="$tmp/home"; mkdir -p "$DM_HOME"
    _dm_stub_clone "$tmp/target" "TARGET"
    local out
    out=$(_dm_cco --dev="$tmp/target" start proj -- --dev --dev-sandbox extra 2>&1) || true
    [[ "$out" == *"STUB-RAN=TARGET"* ]] \
        || fail "the target must still be reached with a '--' in argv, got: $out"
    [[ "$out" == *"[start][proj][--][--dev][--dev-sandbox][extra]"* ]] \
        || fail "'--' and everything after it must survive verbatim (§3.2), got: $out"

    # And the same rule where nothing is dispatched: a dev spelling after `--` is a
    # payload, not a flag, so it must not engage the mode HERE either. Measured: the
    # scan the block replaces consumes from anywhere, so this half fails on a change
    # that fixes the dispatch path alone and leaves a second strip behind.
    rm -rf "$DM_HOME"; mkdir -p "$DM_HOME"
    local err
    err=$(_dm_cco whoami -- --dev-sandbox 2>&1 >/dev/null) || true
    [[ ! -d "$DM_HOME/.cco-devsandbox" ]] \
        || fail "--dev-sandbox AFTER '--' must not engage the mode in place (§3.2)"
    [[ -z "$(grep -E '^note:.*--dev-sandbox' <<< "$err" || true)" ]] \
        || fail "--dev-sandbox AFTER '--' must not be read as the alias flag, got: $err"
}

# §3.3, first match wins: --dev=<path> → \$CCO_DEV_REPO → walk up from \$PWD →
# ~/.cco/dev-repo. Each scenario keeps every LOWER-priority source available, so a
# pass means the higher one actually won rather than being the only one present.
test_dev_mode_target_resolution_precedence() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local DM_HOME="$tmp/home"; mkdir -p "$DM_HOME/.cco"
    _dm_stub_clone "$tmp/flag"   "FLAG"
    _dm_stub_clone "$tmp/env"    "ENV"
    _dm_stub_clone "$tmp/walkup" "WALKUP"
    _dm_stub_clone "$tmp/file"   "FILE"
    mkdir -p "$tmp/walkup/nested/deeper" "$tmp/neutral"
    printf '%s\n' "$tmp/file" > "$DM_HOME/.cco/dev-repo"

    local out
    # ⚠ DM_ENV is set as its own STATEMENT, never as a command prefix: `arr=(x) fn`
    # assigns the literal string "(x)" instead of an array, so the env source would
    # silently not be present and scenarios 1–2 would measure less than they claim.
    # 1. the flag, with all three lower sources present
    out=$(cd "$tmp/walkup/nested/deeper" && DM_ENV=("CCO_DEV_REPO=$tmp/env") \
          && _dm_cco --dev="$tmp/flag" --version 2>&1) || true
    [[ "$out" == *"STUB-RAN=FLAG"* ]] \
        || fail "1. --dev=<path> must win over every other source, got: $out"

    # 2. \$CCO_DEV_REPO, with the walk-up and the file still present
    out=$(cd "$tmp/walkup/nested/deeper" && DM_ENV=("CCO_DEV_REPO=$tmp/env") \
          && _dm_cco --dev --version 2>&1) || true
    [[ "$out" == *"STUB-RAN=ENV"* ]] \
        || fail "2. \$CCO_DEV_REPO must win over the walk-up and the file, got: $out"

    # 3. the walk-up from \$PWD — what makes worktree-per-agent work — over the file
    out=$(cd "$tmp/walkup/nested/deeper" && _dm_cco --dev --version 2>&1) || true
    [[ "$out" == *"STUB-RAN=WALKUP"* ]] \
        || fail "3. the nearest enclosing clone must win over ~/.cco/dev-repo, got: $out"

    # 4. ~/.cco/dev-repo, from a cwd enclosed by no clone at all
    out=$(cd "$tmp/neutral" && _dm_cco --dev --version 2>&1) || true
    [[ "$out" == *"STUB-RAN=FILE"* ]] \
        || fail "4. ~/.cco/dev-repo is the last source before the die, got: $out"
}

# §3.3 stage 5: no silent fallback — die, printing the four it tried.
test_dev_mode_unresolvable_target_dies_listing_the_sources() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local DM_HOME="$tmp/home"; mkdir -p "$DM_HOME" "$tmp/neutral"
    local rc=0 out
    out=$(cd "$tmp/neutral" && _dm_cco --dev --version 2>&1) || rc=$?
    [[ "$rc" -eq 1 ]] \
        || fail "an unresolvable dev target must die (§3.3), got rc=$rc: $out"
    [[ "$out" == *"--dev="*        ]] || fail "the die must name source 1 (--dev=<path>), got: $out"
    [[ "$out" == *"CCO_DEV_REPO"*  ]] || fail "the die must name source 2 (\$CCO_DEV_REPO), got: $out"
    [[ "$out" == *"dev-repo"*      ]] || fail "the die must name source 4 (~/.cco/dev-repo), got: $out"
    [[ "$out" == *"$tmp/neutral"* || "$out" == *[Cc]"urrent"* ]] \
        || fail "the die must name source 3 (the cwd it walked up from), got: $out"
}

# §3.3: "Never exec into an unvalidated path." Each invalid target keeps an
# executable, marker-printing bin/cco wherever the case allows one, so a dispatch
# that skipped validation is visible as STUB-RAN rather than inferred.
test_dev_mode_validates_the_target_before_exec() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local DM_HOME="$tmp/home"; mkdir -p "$DM_HOME"

    _dm_stub_clone "$tmp/nopkg" "NOPKG";   rm -f "$tmp/nopkg/package.json"
    _dm_stub_clone "$tmp/wrongpkg" "WRONGPKG"
    printf '{ "name": "some-other-package", "version": "1.0.0" }\n' > "$tmp/wrongpkg/package.json"
    _dm_stub_clone "$tmp/notexec" "NOTEXEC"; chmod -x "$tmp/notexec/bin/cco"
    mkdir -p "$tmp/nobin"
    printf '{ "name": "@claude-orchestrator/cco", "version": "9.9.9" }\n' > "$tmp/nobin/package.json"

    local case_dir rc out
    # The positive control FIRST, and it is load-bearing: every invalid case below
    # also dies with the path in its message when `--dev` is simply not implemented
    # ("Unknown command: --dev=<path>"), so without a valid target that must be
    # REACHED this whole test is green against a feature that does not exist.
    _dm_stub_clone "$tmp/valid" "VALID"
    out=$(_dm_cco --dev="$tmp/valid" --version 2>&1) || true
    [[ "$out" == *"STUB-RAN=VALID"* ]] \
        || fail "control: a VALID target must be dispatched, got: $out"

    for case_dir in "$tmp/nopkg" "$tmp/wrongpkg" "$tmp/notexec" "$tmp/nobin"; do
        rc=0
        out=$(_dm_cco --dev="$case_dir" --version 2>&1) || rc=$?
        [[ "$out" != *"STUB-RAN="* ]] \
            || fail "$case_dir is not a valid dev target — it must never be exec'd, got: $out"
        [[ "$rc" -eq 1 ]] \
            || fail "an invalid dev target must die (§3.3), got rc=$rc for $case_dir: $out"
        [[ "$out" == *"$case_dir"* ]] \
            || fail "the validation die must name the rejected target, got: $out"
    done
}

# §3.3, the primary loop guard: `cd -P "$target" && pwd` == REPO_ROOT ⇒ no dispatch,
# run in place. Proven two ways, because "it ran" alone cannot tell the two apart:
#   (a) the mode ENGAGES here — the internal buckets redirect (D2, unchanged from
#       ADR-0052 §7), which is the positive signal that the flag did something;
#   (b) with CCO_DEV_DISPATCHED=1 already set it still runs — a dispatch would have
#       hit the second-dispatch refusal below, so rc 0 proves none was attempted.
test_dev_mode_identity_match_engages_in_place() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local DM_HOME="$tmp/home"; mkdir -p "$DM_HOME"
    local DM_ENV=("CCO_DEV_REPO=$REPO_ROOT")
    local rc=0 out
    out=$(_dm_cco --dev whoami 2>&1) || rc=$?
    [[ "$rc" -eq 0 ]] \
        || fail "an identity match must run in place, not fail, got rc=$rc: $out"
    assert_dir_exists "$DM_HOME/.cco-devsandbox/state" \
        "engaging dev mode must redirect the internal buckets (ADR-0060 D2)" || return 1

    rm -rf "$DM_HOME"; mkdir -p "$DM_HOME"
    DM_ENV=("CCO_DEV_DISPATCHED=1")
    rc=0
    out=$(_dm_cco --dev="$REPO_ROOT" whoami 2>&1) || rc=$?
    [[ "$rc" -eq 0 ]] \
        || fail "identity short-circuits BEFORE the second-dispatch guard, got rc=$rc: $out"
}

# §3.3, the belt for symlink/mount aliasing: a second dispatch is refused.
test_dev_mode_second_dispatch_is_refused() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local DM_HOME="$tmp/home"; mkdir -p "$DM_HOME"
    _dm_stub_clone "$tmp/target" "TARGET"
    local DM_ENV=("CCO_DEV_DISPATCHED=1")
    local rc=0 out
    out=$(_dm_cco --dev="$tmp/target" --version 2>&1) || rc=$?
    [[ "$out" != *"STUB-RAN="* ]] \
        || fail "a second dispatch must not exec the target, got: $out"
    [[ "$rc" -eq 2 ]] \
        || fail "a second dispatch is a policy refusal (exit 2), got rc=$rc: $out"
    [[ -n "$out" ]] || fail "an exit-2 refusal must never be silent (B6)"
}

# ── §3.2 / D7 — the legacy flags are superseded aliases ──────────────

test_dev_mode_legacy_flags_are_superseded_aliases() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local DM_HOME="$tmp/home"; mkdir -p "$DM_HOME"
    local DM_ENV=("CCO_DEV_REPO=$REPO_ROOT")
    local rc=0 err line

    rc=0
    err=$(_dm_cco whoami --dev-sandbox 2>&1 >/dev/null) || rc=$?
    [[ "$rc" -eq 0 ]] || fail "--dev-sandbox must still work as an alias, got rc=$rc: $err"
    line=$(grep -E '^note:.*--dev-sandbox([^-]|$)' <<< "$err" | head -1)
    [[ -n "$line" ]] \
        || fail "--dev-sandbox must emit a superseded note naming itself (D7), got: ${err:-<empty>}"
    grep -qE '(^|[^-A-Za-z])--dev([^-A-Za-z]|$)' <<< "$line" \
        || fail "the note must point at --dev, the flag that supersedes it, got: $line"
    assert_dir_exists "$DM_HOME/.cco-devsandbox/state" \
        "--dev-sandbox is an ALIAS of --dev — it must engage the same mode" || return 1

    rm -rf "$DM_HOME"; mkdir -p "$DM_HOME"
    rc=0
    err=$(_dm_cco whoami --dev-sandbox-seed 2>&1 >/dev/null) || rc=$?
    [[ "$rc" -eq 0 ]] || fail "--dev-sandbox-seed must still work as an alias, got rc=$rc: $err"
    line=$(grep -E '^note:.*--dev-sandbox-seed' <<< "$err" | head -1)
    [[ -n "$line" ]] \
        || fail "--dev-sandbox-seed must emit a superseded note naming itself (D7), got: ${err:-<empty>}"
}

# ── §6.3 — clone provenance WITHOUT --dev: a note, nothing more ──────

# The mirror of the incident: the clone's own bin/cco tags the REAL image. Ruled
# detect-and-note — never auto-engage (that would make the mode implicit, against
# D6) and never refuse (a false positive must cost one line of stderr).
test_dev_mode_clone_without_the_flag_notes_on_stderr() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local DM_HOME="$tmp/home"; mkdir -p "$DM_HOME"
    local rc=0 out err count
    out=$(_dm_cco --version 2>/dev/null) || rc=$?
    err=$(_dm_cco --version 2>&1 >/dev/null) || true

    [[ "$rc" -eq 0 ]] \
        || fail "the clone note must never refuse or fail the run (§6.3), got rc=$rc: $err"
    count=$(grep -cE '^note:.*--dev' <<< "$err" || true)
    [[ "$count" -eq 1 ]] \
        || fail "expected exactly one clone note naming --dev on stderr, got $count: ${err:-<empty>}"
    [[ "$out" != *"note:"* ]] \
        || fail "the note belongs on stderr — stdout stays machine-readable, got: $out"
    [[ ! -d "$DM_HOME/.cco-devsandbox" ]] \
        || fail "the note must NOT auto-engage dev mode (D6/§6.3)"

    # Every invocation, unrated: no marker, no rate limit, no list of verbs.
    err=$(_dm_cco whoami 2>&1 >/dev/null) || true
    count=$(grep -cE '^note:.*--dev' <<< "$err" || true)
    [[ "$count" -eq 1 ]] \
        || fail "the clone note fires on EVERY invocation (§6.3), got $count for whoami: $err"
}

# The other half of the condition — "dev mode was not requested". With --dev the
# clone is running exactly as intended, so the note must be silent.
#
# The note is identified by the LINE the un-flagged run actually emits, not by a
# guessed wording: the same invocation, once without the flag and once with it.
# That also makes the un-flagged emission a PRECONDITION, so this test cannot go
# green against a binary that emits no note at all.
test_dev_mode_clone_note_is_absent_under_dev() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local DM_HOME="$tmp/home"; mkdir -p "$DM_HOME"
    local plain rc=0 dev
    plain=$(_dm_cco --version 2>&1 >/dev/null | grep -E '^note:' | head -1) || true
    [[ -n "$plain" ]] \
        || fail "precondition: the clone note must fire without --dev (§6.3)"

    local DM_ENV=("CCO_DEV_REPO=$REPO_ROOT")
    dev=$(_dm_cco --dev --version 2>&1 >/dev/null) || rc=$?
    [[ "$rc" -eq 0 ]] \
        || fail "cco --dev must run in the clone, not fail, got rc=$rc: $dev"
    [[ "$dev" != *"$plain"* ]] \
        || fail "the clone note must not fire when --dev WAS requested (§6.3), got: $dev"
}

# ── §4 — the two application points, observed on the resolved name ───

# §9 / bin/cco:37: the default does not move, and CCO_IMAGE_NAME becomes its
# override. Asserted on the generated compose, which needs no daemon.
test_dev_mode_image_default_does_not_move() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(_dm_project_yml test-proj)"
    export CCO_IN_CONTAINER=0

    local rc=0
    run_cco start "test-proj" --dry-run --dump || rc=$?
    [[ "$rc" -eq 0 ]] || fail "dry run failed (rc=$rc): $CCO_OUTPUT"
    assert_equals "claude-orchestrator:latest" "$(_dm_compose_image "$DRY_RUN_DIR")" \
        "the default image must not move (§9)" || return 1

    export CCO_IMAGE_NAME="cco-fixture-base:9.9"
    rc=0
    run_cco start "test-proj" --dry-run --dump || rc=$?
    [[ "$rc" -eq 0 ]] || fail "dry run with CCO_IMAGE_NAME failed (rc=$rc): $CCO_OUTPUT"
    assert_equals "cco-fixture-base:9.9" "$(_dm_compose_image "$DRY_RUN_DIR")" \
        "CCO_IMAGE_NAME must override the default (bin/cco:37)" || return 1
}

# Application point 1: the default is mapped when dev mode engages — and mapped
# ONCE (an `-dev-dev` would be the double-mapping §4's else-arm rule prevents).
# Application point 2, the else arm: with no `docker.image` the already-mapped
# $IMAGE_NAME is used, which is what this same assertion measures.
test_dev_mode_maps_the_default_image_once() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(_dm_project_yml test-proj)"
    export CCO_IN_CONTAINER=0
    export CCO_DEV_REPO="$REPO_ROOT"

    local rc=0
    run_cco --dev start "test-proj" --dry-run --dump || rc=$?
    [[ "$rc" -eq 0 ]] || fail "dry run under --dev failed (rc=$rc): $CCO_OUTPUT"
    assert_equals "claude-orchestrator-dev:latest" "$(_dm_compose_image "$DRY_RUN_DIR")" \
        "dev mode maps the default image exactly once (§4)" || return 1
}

# §4: "explicit wins" — the same rule _cco_apply_dev_sandbox already applies to
# CCO_*_HOME. An explicitly set CCO_IMAGE_NAME is NOT mapped.
test_dev_mode_explicit_image_env_is_not_mapped() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(_dm_project_yml test-proj)"
    export CCO_IN_CONTAINER=0
    export CCO_DEV_REPO="$REPO_ROOT"
    export CCO_IMAGE_NAME="cco-fixture-base:9.9"

    local rc=0
    run_cco --dev start "test-proj" --dry-run --dump || rc=$?
    [[ "$rc" -eq 0 ]] || fail "dry run under --dev failed (rc=$rc): $CCO_OUTPUT"
    assert_equals "cco-fixture-base:9.9" "$(_dm_compose_image "$DRY_RUN_DIR")" \
        "an explicit CCO_IMAGE_NAME must survive dev mode unmapped (§4)" || return 1
}

# Application point 2, the if arm: a `docker.image` that WAS set is mapped — and
# the committed project.yml is never rewritten (D3: dev mode must not require a
# config change, because project.yml is shared with the team).
test_dev_mode_maps_a_project_image_pin_and_leaves_the_file_alone() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(_dm_project_yml test-proj myorg/pinned:3.2)"
    export CCO_IN_CONTAINER=0

    local rc=0
    run_cco start "test-proj" --dry-run --dump || rc=$?
    [[ "$rc" -eq 0 ]] || fail "dry run failed (rc=$rc): $CCO_OUTPUT"
    assert_equals "myorg/pinned:3.2" "$(_dm_compose_image "$DRY_RUN_DIR")" \
        "without dev mode a project pin is used as written" || return 1

    export CCO_DEV_REPO="$REPO_ROOT"
    rc=0
    run_cco --dev start "test-proj" --dry-run --dump || rc=$?
    [[ "$rc" -eq 0 ]] || fail "dry run under --dev failed (rc=$rc): $CCO_OUTPUT"
    assert_equals "myorg/pinned-dev:3.2" "$(_dm_compose_image "$DRY_RUN_DIR")" \
        "a project pin is mapped too (§4, application point 2)" || return 1
    assert_file_contains "$(host_cco_dir "$tmpdir" test-proj)/project.yml" "image: myorg/pinned:3.2" \
        "the committed project.yml must never be rewritten (D3)" || return 1
}

# R1, satisfied at lib/cmd-build.sh's tag argument: the observable is the RESOLVED
# NAME in the `docker build -t` call, so no image is built and no daemon is read.
# That a real build produces the tag is the HOST acceptance step (`docker image
# inspect` on both tags), deliberately not attempted here.
test_dev_mode_build_tags_the_mapped_image() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local mock_bin="$tmpdir/mockbin"
    setup_mocks "$mock_bin"
    _mock_docker_with_containers "$mock_bin"
    export DOCKER_CALL_LOG="$tmpdir/docker.log"; : > "$DOCKER_CALL_LOG"
    export CCO_IN_CONTAINER=0

    run_cco build
    assert_file_contains "$DOCKER_CALL_LOG" "-t claude-orchestrator:latest" \
        "a normal build tags the real image" || return 1
    assert_file_not_contains "$DOCKER_CALL_LOG" "-dev:latest" \
        "a normal build must not touch the dev image" || return 1

    : > "$DOCKER_CALL_LOG"
    export CCO_DEV_REPO="$REPO_ROOT"
    run_cco --dev build
    assert_file_contains "$DOCKER_CALL_LOG" "-t claude-orchestrator-dev:latest" \
        "a dev build tags the forked repository (R1/D3)" || return 1
    assert_file_not_contains "$DOCKER_CALL_LOG" "-t claude-orchestrator:latest" \
        "a dev build must NOT overwrite the image a real session uses (R1)" || return 1
}

# §4: check_image DIES on a missing mapped image, naming BOTH images and the way
# out. A fallback to the unmapped image is forbidden — it would run published code
# in a dev session, which is the original incident with a warning on top.
# ⚠ `project.dev.yml` is A10.2 and is deliberately not asserted as a way out here.
test_dev_mode_check_image_dies_naming_both_images() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(_dm_project_yml test-proj)"
    local mock_bin="$tmpdir/mockbin"
    setup_mocks "$mock_bin"
    _dm_mock_docker_no_images "$mock_bin"
    export CCO_IN_CONTAINER=0
    export CCO_DEV_REPO="$REPO_ROOT"

    local rc=0
    run_cco --dev start "test-proj" || rc=$?
    [[ "$rc" -eq 1 ]] \
        || fail "a missing dev image must die, never fall back (§4), got rc=$rc: $CCO_OUTPUT"
    assert_output_contains "claude-orchestrator-dev:latest" \
        "the die must name the image it looked for" || return 1
    assert_output_contains "claude-orchestrator:latest" \
        "the die must name the unmapped image too (§4)" || return 1
    assert_output_contains "cco --dev build" \
        "the die must name the way out" || return 1
}

# The control: outside dev mode the same missing image dies with the ordinary
# message. Without this, a check_image that always printed both names would pass.
test_dev_mode_check_image_message_is_dev_specific() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(_dm_project_yml test-proj)"
    local mock_bin="$tmpdir/mockbin"
    setup_mocks "$mock_bin"
    _dm_mock_docker_no_images "$mock_bin"
    export CCO_IN_CONTAINER=0

    local rc=0
    run_cco start "test-proj" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "a missing image must die, got rc=$rc: $CCO_OUTPUT"
    assert_output_contains "claude-orchestrator:latest" \
        "the ordinary die names the real image" || return 1
    assert_output_not_contains "-dev:latest" \
        "outside dev mode nothing may mention the dev image" || return 1
    # ⚠ The way OUT is the discriminating half, not the image name: a check_image
    # that took its dev branch unconditionally still prints only
    # `claude-orchestrator:latest` here (there is no `-dev` suffix to strip), so the
    # two assertions above pass on it — measured. The verb is what differs.
    assert_output_contains "cco build" \
        "the ordinary die points at 'cco build'" || return 1
    assert_output_not_contains "cco --dev build" \
        "outside dev mode the die must not point at the dev build" || return 1
}
