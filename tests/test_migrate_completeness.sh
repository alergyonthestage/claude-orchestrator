#!/usr/bin/env bash
# test_migrate_completeness.sh — table-driven oracle for migration completeness.
#
# Encodes the S2 audit matrix (Round 3, Scope 2): a legacy project carrying one
# artifact of EVERY portable type is migrated with `cco init --migrate`, and each
# type is asserted to reach its correct destination. The maintainer's hard rule is
# "no data loss, no incomplete migration" — so a future change that silently drops
# a resource breaks a row here, instead of being discovered on a real host migrate.
#
# Portable types (legacy `_PORTABLE_FILE_PATTERNS` + design §9 resource map):
#   - committed config:  project.yml, the claude/ tree, mcp.json, setup.sh
#   - gitignored secrets: secrets.env (+ derived .example), arbitrary *.env/*.key/*.pem
#   - machine-local STATE: memory, transcripts (session/claude-state)
#   - index: local-paths → STATE index
# Regenerable-by-design artifacts are intentionally NOT migrated and are not asserted.

# Compact legacy vault: project 'app' carrying one of each portable artifact.
_setup_completeness_vault() {
    local tmpdir="$1"
    setup_cco_env "$tmpdir"
    local vault="$CCO_USER_CONFIG_DIR"
    mkdir -p "$vault/global/.claude" \
             "$vault/projects/app/.claude/rules" \
             "$vault/projects/app/.cco/claude-state" \
             "$vault/projects/app/memory"
    echo "# g" > "$vault/global/.claude/CLAUDE.md"
    cat > "$vault/projects/app/project.yml" <<'YML'
name: app
description: "App"
repos:
  - path: "@local"
    name: apprepo
    url: git@github.com:org/apprepo.git
docker:
  mount_socket: true
YML
    echo "# claude"      > "$vault/projects/app/.claude/CLAUDE.md"
    echo "rule"          > "$vault/projects/app/.claude/rules/r.md"
    echo '{"mcp":1}'     > "$vault/projects/app/mcp.json"
    echo "echo hi"       > "$vault/projects/app/setup.sh"
    echo "SECRET=s"      > "$vault/projects/app/secrets.env"
    echo "EXTRA=e"       > "$vault/projects/app/extra.env"
    echo "KEYBYTES"      > "$vault/projects/app/svc.key"
    echo "PEMBYTES"      > "$vault/projects/app/tls.pem"
    echo "remember"      > "$vault/projects/app/memory/note.md"
    printf '{"t":"x"}\n' > "$vault/projects/app/.cco/claude-state/s.jsonl"
    printf 'repos:\n  apprepo: "/home/dev/apprepo"\n' > "$vault/projects/app/.cco/local-paths.yml"
    git -C "$vault" init -q
    git -C "$vault" symbolic-ref HEAD refs/heads/main 2>/dev/null
    git -C "$vault" add -A 2>/dev/null
    git -C "$vault" commit -q -m main 2>/dev/null
    mkdir -p "$tmpdir/clones/apprepo"
}

test_migrate_completeness_matrix() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_completeness_vault "$tmpdir"
    ( cd "$tmpdir/clones/apprepo" && CCO_ASSUME_YES=1 run_cco init --migrate app )

    local cco="$tmpdir/clones/apprepo/.cco"
    local st="$CCO_STATE_HOME/projects/app"
    # The audit oracle: "resource|path that MUST exist after migrate".
    local rows=(
        "project.yml|$cco/project.yml"
        "claude tree|$cco/claude/CLAUDE.md"
        "claude rules|$cco/claude/rules/r.md"
        "mcp.json|$cco/mcp.json"
        "setup.sh|$cco/setup.sh"
        "secrets.env|$cco/secrets.env"
        "secrets.env.example (derived)|$cco/secrets.env.example"
        "arbitrary *.env|$cco/extra.env"
        "arbitrary *.key|$cco/svc.key"
        "arbitrary *.pem|$cco/tls.pem"
        ".gitignore|$cco/.gitignore"
        "memory -> STATE|$st/session/memory/note.md"
        "transcripts -> STATE|$st/session/claude-state/s.jsonl"
    )
    local row name path
    for row in "${rows[@]}"; do
        name=${row%%|*}; path=${row#*|}
        [[ -e "$path" ]] || fail "migration completeness: '$name' did not reach its destination ($path)"
    done

    # local-paths → STATE index (repo path registered, machine-local).
    assert_file_contains "$CCO_STATE_HOME/index" 'apprepo: "/home/dev/apprepo"' \
        "migration completeness: local-paths must register the repo path in the index"
    # AD3/G8: the committed project.yml stays machine-agnostic (no host path leak).
    assert_file_not_contains "$cco/project.yml" "/home/dev" \
        "migration completeness: no host path may leak into the committed project.yml"
}
