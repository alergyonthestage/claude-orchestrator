#!/usr/bin/env bash
# tests/test_entrypoint_claude_install.sh — the entrypoint's Claude Code native
# install block (ADR-0039).
#
# The entrypoint as a whole is image plumbing (socket GID, proxy, gosu, tmux) and
# is only verifiable after `cco build && cco start` on a real container. The
# install BLOCK, however, is self-contained enough to run in a sandbox: these
# tests extract it verbatim from config/entrypoint.sh, re-root its hardcoded
# /home/claude paths into a tmpdir, and drive it against a fake install.sh that
# reproduces the real one's contract — `claude install` REFUSES to overwrite a
# launcher it did not create, and exits non-zero.
#
# What that contract costs us in production: the launcher lives in the CACHE
# install dir, which is shared by every project and every session. One foreign
# launcher (an npm-era wrapper, a `claude migrate-installer` result, a symlink
# dangling into a wiped share/claude/versions) made EVERY `cco start` FATAL until
# `cco build --no-cache`. The block must therefore clear the launcher path before
# installing — and must still not reinstall when the install is present and the
# requested channel is unchanged ("one-time per cache").

# ── Harness ───────────────────────────────────────────────────────────

# Extract the install block from the real entrypoint, re-rooted into $1 (the
# sandbox home) and prefixed with the entrypoint's own _log. Echoes the path to
# the runnable script. Extraction is anchored on the block's first statement
# (CLAUDE_BIN=) and the header of the next block, so the test tracks the source.
_extract_claude_install_block() {
    local sandbox_home="$1" out="$2"
    {
        printf '#!/bin/bash\nset -e\n'
        printf '_log() { echo "[entrypoint] $*" >&2; }\n'
        awk '/^CLAUDE_BIN=/{f=1} /^# ── Debug: log env vars/{f=0} f' \
            "$REPO_ROOT/config/entrypoint.sh" \
            | sed "s#/home/claude#${sandbox_home}#g"
    } > "$out"
    # A silent extraction miss would make every assertion below vacuous.
    grep -q 'install.sh' "$out" || fail "install block extraction missed install.sh"
    chmod +x "$out"
}

# Stubs for what the block shells out to. gosu drops its user arg and runs the
# command; chown/curl are faked (the sandbox is already ours; the network is not
# available and would not be deterministic anyway).
#
# The fake install.sh mirrors the real installer's observable behavior: it drops
# the version under share/claude/versions/<v> and symlinks bin/claude at it —
# unless something that is not one of its own launchers already sits there, in
# which case it refuses with the real error text. Every invocation is appended to
# $INSTALL_LOG so "did we (re)install?" is assertable.
_setup_entrypoint_mocks() {
    local mock_bin="$1" sandbox_home="$2"
    mkdir -p "$mock_bin"

    cat > "$mock_bin/gosu" <<'GOSU'
#!/bin/bash
shift            # drop the user argument — the sandbox is already ours
exec "$@"
GOSU

    cat > "$mock_bin/chown" <<'CHOWN'
#!/bin/bash
exit 0
CHOWN

    # `curl -fsSL https://claude.ai/install.sh` → emit the fake installer on stdout,
    # exactly as the real pipeline expects (`curl … | bash -s "$CLAUDE_REQ"`).
    cat > "$mock_bin/curl" <<CURL
#!/bin/bash
cat "$mock_bin/fake-install.sh"
CURL

    cat > "$mock_bin/fake-install.sh" <<INSTALLER
#!/bin/bash
req="\${1:-latest}"
echo "\$req" >> "\$INSTALL_LOG"

# Resolve the channel to a concrete version, as the real installer does.
ver="\$req"
[ "\$req" = "latest" ] && ver="2.1.210"
[ "\$req" = "stable" ] && ver="2.0.0"

versions="${sandbox_home}/.local/share/claude/versions"
launcher="${sandbox_home}/.local/bin/claude"
mkdir -p "\$versions"
printf '#!/bin/bash\necho %s\n' "\$ver" > "\$versions/\$ver"
chmod +x "\$versions/\$ver"

# The refusal, modeled on the real installer's own error text: it overwrites the
# launcher only when that launcher is one it owns AND is working — i.e. a live
# symlink into versions/. Anything else (a foreign wrapper, a symlink dangling at
# a version that no longer exists) is left alone and the install fails.
if [ -e "\$launcher" ] || [ -L "\$launcher" ]; then
    target="\$(readlink "\$launcher" 2>/dev/null || true)"
    ours=""
    case "\$target" in
        "\$versions"/*) [ -e "\$target" ] && ours=1 ;;
    esac
    if [ -z "\$ours" ]; then
        echo "Failed to create executable at \$launcher. Source file exists: true." >&2
        echo "the existing file there was not created by the native installer and is not a working launcher" >&2
        exit 1
    fi
fi

ln -sfn "\$versions/\$ver" "\$launcher"
echo "Claude Code successfully installed!"
INSTALLER

    chmod +x "$mock_bin"/gosu "$mock_bin"/chown "$mock_bin"/curl "$mock_bin"/fake-install.sh
}

# Full sandbox: dirs the compose bind-mounts would provide, mocks, extracted
# block. Sets $SANDBOX_HOME, $BLOCK, $INSTALL_LOG for the test body.
_setup_install_sandbox() {
    local tmpdir="$1"
    SANDBOX_HOME="$tmpdir/home-claude"
    BLOCK="$tmpdir/install-block.sh"
    INSTALL_LOG="$tmpdir/install.log"
    export INSTALL_LOG
    : > "$INSTALL_LOG"
    mkdir -p "$SANDBOX_HOME/.local/bin" "$SANDBOX_HOME/.local/share/claude"
    _setup_entrypoint_mocks "$tmpdir/mockbin" "$SANDBOX_HOME"
    _extract_claude_install_block "$SANDBOX_HOME" "$BLOCK"
    PATH="$tmpdir/mockbin:$PATH"
}

# ── 1. The regression: a foreign launcher must not be fatal ───────────

test_entrypoint_install_replaces_foreign_launcher() {
    # An npm-era wrapper script at the launcher path — the state that made
    # `cco start` FATAL for every project sharing the CACHE dir.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_install_sandbox "$tmpdir"

    printf '#!/bin/sh\nexec node /usr/lib/node_modules/claude/cli.js "$@"\n' \
        > "$SANDBOX_HOME/.local/bin/claude"
    chmod +x "$SANDBOX_HOME/.local/bin/claude"

    CLAUDE_CODE_VERSION=latest bash "$BLOCK" >/dev/null 2>&1
    assert_equals "0" "$?" "install block must not fail on a foreign launcher"

    # The foreign wrapper is gone, replaced by a real installer launcher…
    assert_equals "$SANDBOX_HOME/.local/share/claude/versions/2.1.210" \
        "$(readlink "$SANDBOX_HOME/.local/bin/claude")" \
        "launcher must be the installer's symlink into versions/"
    # …and the marker records the request, so the next start skips the install.
    assert_file_contains "$SANDBOX_HOME/.local/bin/.cco-claude-channel" "latest"
}

test_entrypoint_install_replaces_dangling_launcher() {
    # A launcher symlinked at a version that no longer exists (share/ wiped, or
    # a half-finished install): -x is false → reinstall, and the stale symlink
    # must not block it.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_install_sandbox "$tmpdir"

    ln -sfn "$SANDBOX_HOME/.local/share/claude/versions/1.0.0" \
        "$SANDBOX_HOME/.local/bin/claude"

    CLAUDE_CODE_VERSION=latest bash "$BLOCK" >/dev/null 2>&1
    assert_equals "0" "$?" "install block must not fail on a dangling launcher"
    assert_equals "$SANDBOX_HOME/.local/share/claude/versions/2.1.210" \
        "$(readlink "$SANDBOX_HOME/.local/bin/claude")" \
        "dangling launcher must be replaced by the fresh install"
}

test_entrypoint_install_replaces_foreign_launcher_dir() {
    # Docker Desktop auto-creates a DIRECTORY when a bind-mount source is missing;
    # a directory at the launcher path must not survive either (rm -rf, not rm -f).
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_install_sandbox "$tmpdir"

    mkdir -p "$SANDBOX_HOME/.local/bin/claude/stray"

    CLAUDE_CODE_VERSION=latest bash "$BLOCK" >/dev/null 2>&1
    assert_equals "0" "$?" "install block must not fail on a directory at the launcher path"
    assert_equals "$SANDBOX_HOME/.local/share/claude/versions/2.1.210" \
        "$(readlink "$SANDBOX_HOME/.local/bin/claude")" \
        "directory at the launcher path must be replaced by the fresh install"
}

# ── 2. No regression: the install stays one-time per cache ────────────

test_entrypoint_install_skipped_when_present_and_unchanged() {
    # A healthy install + a marker matching the request → no reinstall at all
    # (the auto-updater owns currency from here — ADR-0039). This is what the
    # launcher-clearing rm must never reach: it would delete a live launcher.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_install_sandbox "$tmpdir"

    local versions="$SANDBOX_HOME/.local/share/claude/versions"
    mkdir -p "$versions"
    printf '#!/bin/bash\necho 2.1.210\n' > "$versions/2.1.210"
    chmod +x "$versions/2.1.210"
    ln -sfn "$versions/2.1.210" "$SANDBOX_HOME/.local/bin/claude"
    printf 'latest\n' > "$SANDBOX_HOME/.local/bin/.cco-claude-channel"

    CLAUDE_CODE_VERSION=latest bash "$BLOCK" >/dev/null 2>&1

    assert_empty "$(cat "$INSTALL_LOG")" \
        "installer must not run when the binary is present and the channel is unchanged"
    assert_equals "$versions/2.1.210" "$(readlink "$SANDBOX_HOME/.local/bin/claude")" \
        "a healthy launcher must survive untouched"
}

test_entrypoint_install_reruns_when_channel_changes() {
    # The marker — not `claude --version` — is what makes the config knob
    # (`cco build --claude-version stable`) actually re-pin: a bare channel
    # string is not comparable to a version number.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_install_sandbox "$tmpdir"

    local versions="$SANDBOX_HOME/.local/share/claude/versions"
    mkdir -p "$versions"
    printf '#!/bin/bash\necho 2.1.210\n' > "$versions/2.1.210"
    chmod +x "$versions/2.1.210"
    ln -sfn "$versions/2.1.210" "$SANDBOX_HOME/.local/bin/claude"
    printf 'latest\n' > "$SANDBOX_HOME/.local/bin/.cco-claude-channel"

    CLAUDE_CODE_VERSION=stable bash "$BLOCK" >/dev/null 2>&1

    assert_file_contains "$INSTALL_LOG" "stable"
    assert_equals "$versions/2.0.0" "$(readlink "$SANDBOX_HOME/.local/bin/claude")" \
        "re-pin must repoint the launcher at the newly requested channel"
    assert_file_contains "$SANDBOX_HOME/.local/bin/.cco-claude-channel" "stable"
}

# ── 3. The failure path still fails loudly, with a way out ────────────

test_entrypoint_install_fatal_names_the_reset_command() {
    # When the installer genuinely fails (no network), the block must exit
    # non-zero AND name the escape hatch — the old message only mentioned the
    # network, leaving a corrupt cache looking like an outage.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_install_sandbox "$tmpdir"

    printf '#!/bin/bash\nexit 1\n' > "$tmpdir/mockbin/fake-install.sh"
    chmod +x "$tmpdir/mockbin/fake-install.sh"

    local rc=0
    CCO_OUTPUT=$(CLAUDE_CODE_VERSION=latest bash "$BLOCK" 2>&1) || rc=$?

    assert_equals "1" "$rc" "a failed install must stay FATAL"
    assert_output_contains "FATAL"
    assert_output_contains "cco build --no-cache"
    # No marker on failure — the next start must retry the install.
    assert_file_not_exists "$SANDBOX_HOME/.local/bin/.cco-claude-channel"
}
