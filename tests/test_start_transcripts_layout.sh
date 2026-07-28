#!/usr/bin/env bash
# tests/test_start_transcripts_layout.sh — the session-transcripts bucket (ADR-0055 D5/D6)
#
# Focus: the bucket is bound as the whole ~/.claude/projects TREE, not as the
# single -workspace key. Claude Code derives one key per cwd, so a subagent or
# teammate started from /workspace/<repo>, a worktree session or a background
# session writes under a DIFFERENT key. Two defects met there (R-D):
#
#   • the parent was left for the container runtime to materialise, root-owned,
#     so those keys could not be created at all — EACCES at runtime, not at
#     start, which is why it read as a broken feature rather than a broken boot;
#   • only -workspace was persisted, so even once writable the rest would live
#     on the container's ephemeral layer and vanish at exit.
#
# The layout repair is a lazy self-heal at the write boundary (ADR-0052 alt-B,
# the precedent FI-27 set for STATE shape) rather than a migrations/ lane. These
# tests pin its contract: idempotent, never destructive, never clobbering.

_tl_test_env() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/cmd-start.sh"
}

# A bucket in the pre-ADR-0055 shape: transcripts sit at the bucket root, because
# the bucket WAS the -workspace key.
_tl_legacy_bucket() {
    local b="$1"
    mkdir -p "$b/013986a7-0b74-491f-bf3d-c09f97f52b1a/subagents" "$b/memory"
    echo '{"t":1}' > "$b/013986a7-0b74-491f-bf3d-c09f97f52b1a.jsonl"
    echo '{"t":2}' > "$b/0690a188-d13f-40bd-b1cc-48285375c00c.jsonl"
    echo '# note'  > "$b/memory/MEMORY.md"
}

test_transcripts_heal_moves_legacy_content_under_workspace_key() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _tl_test_env
    local b="$tmpdir/claude-state"; _tl_legacy_bucket "$b"

    _start_prepare_transcripts_bucket "$b" || fail "heal returned non-zero"

    assert_file_exists "$b/-workspace/013986a7-0b74-491f-bf3d-c09f97f52b1a.jsonl" || return 1
    assert_file_exists "$b/-workspace/0690a188-d13f-40bd-b1cc-48285375c00c.jsonl" || return 1
    assert_dir_exists  "$b/-workspace/013986a7-0b74-491f-bf3d-c09f97f52b1a/subagents" || return 1
    # The old memory mountpoint lands exactly on its new mountpoint.
    assert_file_exists "$b/-workspace/memory/MEMORY.md" || return 1
    # Nothing is left at the old depth to be bound twice or read as a project key.
    assert_file_not_exists "$b/013986a7-0b74-491f-bf3d-c09f97f52b1a.jsonl"
}

# 91 transcripts and ~130MB of real history were in the maintainer's bucket when
# this landed: a repair that loses content is worse than the bug it fixes.
test_transcripts_heal_preserves_content() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _tl_test_env
    local b="$tmpdir/claude-state"; _tl_legacy_bucket "$b"

    _start_prepare_transcripts_bucket "$b" || fail "heal returned non-zero"

    assert_equals '{"t":1}' "$(cat "$b/-workspace/013986a7-0b74-491f-bf3d-c09f97f52b1a.jsonl")"
}

test_transcripts_heal_is_idempotent() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _tl_test_env
    local b="$tmpdir/claude-state"; _tl_legacy_bucket "$b"

    _start_prepare_transcripts_bucket "$b" || fail "first heal returned non-zero"
    local after_first; after_first=$(cd "$b" && find . | sort)
    _start_prepare_transcripts_bucket "$b" || fail "second heal returned non-zero"
    local after_second; after_second=$(cd "$b" && find . | sort)

    assert_equals "$after_first" "$after_second"
}

# A project key is derived from an ABSOLUTE cwd, so it always starts with '-'.
# That is the discriminator between a key and pre-0055 content; a key must never
# be swallowed into -workspace.
test_transcripts_heal_leaves_other_project_keys_alone() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _tl_test_env
    local b="$tmpdir/claude-state"
    mkdir -p "$b/-workspace-claude-orchestrator"
    echo '{"t":3}' > "$b/-workspace-claude-orchestrator/sess.jsonl"

    _start_prepare_transcripts_bucket "$b" || fail "heal returned non-zero"

    assert_file_exists "$b/-workspace-claude-orchestrator/sess.jsonl" || return 1
    assert_dir_not_exists "$b/-workspace/-workspace-claude-orchestrator"
}

# Never destructive: an entry already present at the target wins, and the stray
# copy stays put rather than overwriting real history.
test_transcripts_heal_never_clobbers_an_existing_target() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _tl_test_env
    local b="$tmpdir/claude-state"
    mkdir -p "$b/-workspace"
    echo 'keep' > "$b/-workspace/sess.jsonl"
    echo 'stray' > "$b/sess.jsonl"

    _start_prepare_transcripts_bucket "$b" || fail "heal returned non-zero"

    assert_equals 'keep' "$(cat "$b/-workspace/sess.jsonl")" || return 1
    assert_equals 'stray' "$(cat "$b/sess.jsonl")"
}

# INV-MP one directory further in: the auto-memory child binds at
# -workspace/memory, so cco must own that mountpoint inside its own bucket. The
# dry run cannot see this half — it is the FI-31 class, and the compose YAML was
# correct throughout that bug too.
test_transcripts_bucket_owns_the_memory_mountpoint() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _tl_test_env
    local b="$tmpdir/claude-state"; mkdir -p "$b"

    _start_prepare_transcripts_bucket "$b" || fail "prepare returned non-zero"

    assert_dir_exists "$b/-workspace/memory"
}

test_transcripts_heal_creates_the_workspace_key_on_an_empty_bucket() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _tl_test_env
    local b="$tmpdir/claude-state"; mkdir -p "$b"

    _start_prepare_transcripts_bucket "$b" || fail "heal returned non-zero"

    assert_dir_exists "$b/-workspace"
}

# The compose side of D5: the bucket is the projects TREE. Anchored on the closing
# quote — the pre-0055 ".../projects/-workspace" line satisfies a bare prefix.
test_transcripts_bucket_is_bound_as_the_projects_tree() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"

    run_cco start "test-proj" --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"

    assert_file_contains "$compose" "session/claude-state:/home/claude/.claude/projects\"" || return 1
    # Auto-memory still lands at the -workspace key, now as a grandchild.
    assert_file_contains "$compose" "session/memory:/home/claude/.claude/projects/-workspace/memory\""
}
