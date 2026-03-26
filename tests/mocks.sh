#!/usr/bin/env bash
# tests/mocks.sh — mock external commands via PATH prepend
# Sourced by bin/test. Functions are available in every test function.
#
# Strategy: write mock shell scripts into a tmpdir/bin directory, then
# prepend it to PATH. bin/cco subprocess inherits the modified PATH.
#
# Only test_auth.sh currently uses mocks.

# Install a mock `security` command that returns a fake OAuth token JSON.
# Usage: _mock_security_with_token "$mock_bin" "my-fake-token"
_mock_security_with_token() {
    local dir="$1"
    local fake_token="${2:-test-oauth-token-12345}"
    mkdir -p "$dir"
    cat > "$dir/security" <<MOCK
#!/usr/bin/env bash
# Mock: simulates macOS Keychain returning Claude Code credentials JSON
# Matches: security find-generic-password -s "Claude Code-credentials" ... -w
echo '{"claudeAiOauth":{"accessToken":"${fake_token}"}}'
MOCK
    chmod +x "$dir/security"
}

# Install a mock `security` command that simulates a Keychain miss (exit 1).
# Usage: _mock_security_empty "$mock_bin"
_mock_security_empty() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/security" <<'MOCK'
#!/usr/bin/env bash
# Mock: simulates macOS Keychain returning no item found
exit 1
MOCK
    chmod +x "$dir/security"
}

# Prepend $mock_bin to PATH so mocks shadow real system commands.
# Usage: setup_mocks "$mock_bin"
setup_mocks() {
    local mock_bin="$1"
    mkdir -p "$mock_bin"
    export PATH="$mock_bin:$PATH"
}

# Install a mock docker that simulates a running daemon.
# Accepts 0 or more container names that 'docker ps' will return.
# Writes all docker invocations to $DOCKER_CALL_LOG if that env var is set.
# Usage: _mock_docker_with_containers "$mock_bin" ["cc-proj-a" ...]
_mock_docker_with_containers() {
    local dir="$1"
    shift
    local ps_lines=""
    for name in "$@"; do
        ps_lines+="        printf '%s\\n' '${name}'"$'\n'
    done
    mkdir -p "$dir"
    cat > "$dir/docker" <<MOCK
#!/usr/bin/env bash
[[ -n "\${DOCKER_CALL_LOG:-}" ]] && echo "\$*" >> "\${DOCKER_CALL_LOG}"
case "\$1" in
    info)  exit 0 ;;
    ps)
${ps_lines}        ;;
    stop)  ;;
    image) exit 0 ;;
    *)     exit 0 ;;
esac
MOCK
    chmod +x "$dir/docker"
}

# Install a mock docker with no running containers (daemon is running, ps is empty).
# Usage: _mock_docker_no_containers "$mock_bin"
_mock_docker_no_containers() {
    _mock_docker_with_containers "$1"
}

# Install a smart mock docker that returns a container only for a specific project.
# Supports both general label check (cco.project) and targeted check (cco.project=<name>).
# Usage: _mock_docker_with_project_session "$mock_bin" "project-name" ["container-name"]
_mock_docker_with_project_session() {
    local dir="$1"
    local project_name="$2"
    local container_name="${3:-cc-${project_name}-abc123}"
    mkdir -p "$dir"
    cat > "$dir/docker" <<MOCK
#!/usr/bin/env bash
[[ -n "\${DOCKER_CALL_LOG:-}" ]] && echo "\$*" >> "\${DOCKER_CALL_LOG}"
case "\$1" in
    info)  exit 0 ;;
    ps)
        if echo "\$*" | grep -q "label=cco.project=${project_name}"; then
            printf '%s\\n' '${container_name}'
        elif echo "\$*" | grep -q 'label=cco.project='; then
            :
        elif echo "\$*" | grep -q 'label=cco.project'; then
            printf '%s\\n' '${container_name}'
        fi
        ;;
    stop)  ;;
    image) exit 0 ;;
    *)     exit 0 ;;
esac
MOCK
    chmod +x "$dir/docker"
}
