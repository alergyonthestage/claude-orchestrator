#!/usr/bin/env bash
# tests/test_agent_coordination.sh — the teammate coordination guarantee (ADR-0058)
#
# These tests are written from the DECISION, not from the code: each one names the
# clause it pins. The behaviour under test is "what does the agent definition that
# Claude Code actually READS contain", which is why the assertions compare FILE
# CONTENT wherever the ADR's verification section does — check 6 is explicit that a
# mode-based assertion would pass while measuring nothing (the FI-25 mask makes
# every tree rw in this repo).
#
# ⚠ Checks 1–5 of the ADR (a restricted role delivering to a lead, with the
# normalizer disabled as the negative control) are NOT here and cannot be: they
# need a real session with a live team. This file covers the projection contract;
# the container lane covers the delivery.

_agn_env() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/agents.sh"
}

# One definition per shape the decision distinguishes.
# Sets: AGN_SRC (definitions), AGN_WORK (normalizer work dir).
_agn_fixture() {
    local root="$1"
    AGN_SRC="$root/agents"; AGN_WORK="$root/work"
    mkdir -p "$AGN_SRC"
    # Restricted allowlist — the shape every cco role agent has, and the one that
    # measured 0 deliverables out of 17.
    printf -- '---\nname: analyst\ndescription: d\ntools: Read, Grep, Bash\ndisallowedTools: Write, Edit\nmodel: opus\n---\n\nBody.\n' > "$AGN_SRC/analyst.md"
    # No `tools:` key at all — inherits every tool, so it was never broken.
    printf -- '---\nname: free\ndescription: d\n---\n\nBody.\n' > "$AGN_SRC/free.md"
    # A member of the set explicitly DENIED (A3).
    printf -- '---\nname: denied\ndescription: d\ntools: Read\ndisallowedTools: SendMessage\n---\n\nBody.\n' > "$AGN_SRC/denied.md"
    # No frontmatter at all (D11).
    printf -- 'name: broken\nnot: frontmatter\n' > "$AGN_SRC/broken.md"
    # Block-form list: valid YAML, not the documented inline form (D11).
    printf -- '---\nname: block\ndescription: d\ntools:\n  - Read\n  - Bash\n---\n\nBody.\n' > "$AGN_SRC/block.md"
    _agents_norm_init "$AGN_WORK"
}

# ── D2 — the guarantee is a SET, computed once ───────────────────────

# The return channel alone is not the remedy: a teammate that cannot mark a task
# complete blocks its dependents, and `SendMessage` is a DEFERRED tool that cannot
# be found without the discovery path. Pin all three reasons.
test_agn_d2_set_covers_channel_tasks_and_discovery() {
    _agn_env
    local set; set=$(_cco_coordination_tools)
    echo "$set" | grep -qx "SendMessage" || fail "D2: the return channel itself is missing from the set"
    echo "$set" | grep -qx "ToolSearch" || fail "D2: the discovery path is missing — granting a deferred tool without it grants a tool the agent cannot find"
    local t
    for t in TaskCreate TaskUpdate TaskList TaskGet; do
        echo "$set" | grep -qx "$t" || fail "D2: task tool $t missing — 'teammates sometimes fail to mark tasks complete' becomes always"
    done
    return 0
}

# ── D4 — normalize at start time, never touch the user's file ────────

test_agn_d4_restricted_definition_is_mounted_from_a_normalized_copy() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _agn_env; _agn_fixture "$tmpdir"

    local out; out=$(_agent_src "$AGN_SRC/analyst.md" "/workspace/.claude/agents/analyst.md" "ro")
    [[ "$out" != "$AGN_SRC/analyst.md" ]] \
        || fail "D4: a restricted definition was mounted from the committed file — the teammate has no return channel"
    [[ -f "$out" ]] || fail "D4: the normalized copy does not exist at $out"
    local m
    for m in $(_cco_coordination_tools); do
        grep -q "^tools:.*$m" "$out" \
            || fail "D4: the normalized copy's tools: line is missing $m"
    done
    return 0
}

# P3: cco projects a different VIEW of the file; it never rewrites the file the
# user committed. The whole design rests on this, so it is asserted byte-wise.
test_agn_d4_committed_file_is_never_modified() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _agn_env; _agn_fixture "$tmpdir"

    local before after
    before=$(cat "$AGN_SRC/analyst.md")
    _agent_src "$AGN_SRC/analyst.md" "/workspace/.claude/agents/analyst.md" "ro" >/dev/null
    after=$(cat "$AGN_SRC/analyst.md")
    [[ "$before" == "$after" ]] \
        || fail "D4/P3: cco modified the user's committed agent definition"
    return 0
}

# An omitted `tools:` key already inherits everything — normalizing it would be a
# change with no cause, and every change to a user's toolset has to be announced.
test_agn_d4_definition_without_tools_key_passes_through() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _agn_env; _agn_fixture "$tmpdir"

    local out; out=$(_agent_src "$AGN_SRC/free.md" "/workspace/.claude/agents/free.md" "ro")
    [[ "$out" == "$AGN_SRC/free.md" ]] \
        || fail "D4: a definition that inherits every tool was needlessly rewritten"
    return 0
}

# The guarantee is about `.claude/agents/`. Anything else must be untouched, or
# the wrapper could not be applied safely at a generic mount site.
test_agn_d4_non_agent_target_passes_through() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _agn_env; _agn_fixture "$tmpdir"

    local out; out=$(_agent_src "$AGN_SRC/analyst.md" "/workspace/.claude/rules/analyst.md" "ro")
    [[ "$out" == "$AGN_SRC/analyst.md" ]] \
        || fail "D4: a non-agent mount was rerouted through the normalizer"
    return 0
}

# ── D5 — every producer goes through it ──────────────────────────────

# The pack producer is the one the six failing roles come from, and it sits
# outside the mount emitter — normalizing at the other producer alone would ship a
# fix that misses exactly the agents that motivated it.
test_agn_d5_pack_producer_mounts_the_normalized_copy() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _agn_env
    source "$REPO_ROOT/lib/yaml.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/packs.sh"
    _agn_fixture "$tmpdir"

    # A minimal resolvable pack carrying one restricted agent.
    export PACKS_DIR="$tmpdir/packs"
    mkdir -p "$PACKS_DIR/p1/agents"
    cp "$AGN_SRC/analyst.md" "$PACKS_DIR/p1/agents/analyst.md"
    printf 'name: p1\nagents:\n  - analyst.md\n' > "$PACKS_DIR/p1/pack.yml"

    local out; out=$(_generate_pack_mounts "p1" "$tmpdir/none" 2>/dev/null)
    echo "$out" | grep -q ':/workspace/.claude/agents/analyst.md:ro"' \
        || fail "D5: the pack agent mount disappeared:"$'\n'"$out"
    echo "$out" | grep -q "\"$PACKS_DIR/p1/agents/analyst.md:" \
        && fail "D5: the pack producer still mounts the RAW definition — the roles that motivated the fix stay broken:"$'\n'"$out"
    echo "$out" | grep -q "\"$AGN_WORK/" \
        || fail "D5: the pack producer does not mount a normalized copy:"$'\n'"$out"
    return 0
}

# A tree bound as a whole directory gives its definitions no mount line of their
# own; the copies must arrive as child binds over it.
test_agn_d5_directory_tree_gets_child_overlays() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _agn_env; _agn_fixture "$tmpdir"

    local out; out=$(_emit_agent_dir_overlays "$AGN_SRC" "/home/claude/.claude/agents" "ro")
    echo "$out" | grep -q ':/home/claude/.claude/agents/analyst.md:ro"' \
        || fail "D5: no child bind for a restricted definition in a whole-directory tree:"$'\n'"$out"
    echo "$out" | grep -q 'free.md' \
        && fail "D5: a definition needing nothing was still overlaid — the view must differ from the file only where it must"
    return 0
}

# A duplicate mount point is a compose ERROR, not a last-one-wins: the overlay pass
# runs after the per-file producers and must skip what they already emitted.
test_agn_d5_overlay_skips_targets_already_mounted() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _agn_env; _agn_fixture "$tmpdir"

    _agent_src "$AGN_SRC/analyst.md" "/workspace/.claude/agents/analyst.md" "ro" >/dev/null
    local out; out=$(_emit_agent_dir_overlays "$AGN_SRC" "/workspace/.claude/agents" "ro")
    echo "$out" | grep -q '/workspace/.claude/agents/analyst.md' \
        && fail "D5: the overlay pass re-emitted a target a per-file producer had already mounted — compose refuses a duplicate mount point:"$'\n'"$out"
    return 0
}

# ── D10 — the rw cell is warned, never rewritten ─────────────────────

# ⚠ The assertion compares the FILE the agent would read, not the mount mode —
# ADR-0058 Verification, check 6.
test_agn_d10_writable_tree_is_not_projected() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _agn_env; _agn_fixture "$tmpdir"

    local out; out=$(_agent_src "$AGN_SRC/analyst.md" "/workspace/.claude/agents/analyst.md" "rw")
    [[ "$out" == "$AGN_SRC/analyst.md" ]] \
        || fail "D10: a writable tree was projected — the user would edit an overlay, or read content that is not their file"
    cmp -s "$out" "$AGN_SRC/analyst.md" \
        || fail "D10: the file the agent reads differs from the user's own under a writable tree"
    return 0
}

test_agn_d10_writable_tree_is_still_reported() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _agn_env; _agn_fixture "$tmpdir"

    _agent_src "$AGN_SRC/analyst.md" "/workspace/.claude/agents/analyst.md" "rw" >/dev/null
    local msg; msg=$(_agents_report_flush 2>&1)
    echo "$msg" | grep -q "analyst.md" \
        || fail "D10: the ungoverned rw cell was left silent — the warning is its ENTIRE remedy:"$'\n'"$msg"
    return 0
}

# ── D11 — an unparseable definition passes through, with a warning ───

test_agn_d11_unparseable_definition_does_not_break_the_session() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _agn_env; _agn_fixture "$tmpdir"

    local out rc
    out=$(_agent_src "$AGN_SRC/broken.md" "/workspace/.claude/agents/broken.md" "ro"); rc=$?
    [[ $rc -eq 0 ]] || fail "D11: the normalizer failed on a malformed definition (rc=$rc) — a session must not become unstartable over a stray character"
    [[ "$out" == "$AGN_SRC/broken.md" ]] || fail "D11: a malformed definition was not passed through unchanged"
    return 0
}

test_agn_d11_unparseable_definition_is_named() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _agn_env; _agn_fixture "$tmpdir"

    _agent_src "$AGN_SRC/broken.md" "/workspace/.claude/agents/broken.md" "ro" >/dev/null
    local msg; msg=$(_agents_report_flush 2>&1)
    echo "$msg" | grep -q "broken.md" \
        || fail "D11: the warning must name the FILE, not just the condition:"$'\n'"$msg"
    return 0
}

# A block-form list is valid YAML that this normalizer does not rewrite. Pinning
# it as pass-through is the point: guessing would ORPHAN the list items, i.e.
# corrupt a definition that was merely unusual.
test_agn_d11_block_form_list_is_passed_through_not_corrupted() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _agn_env; _agn_fixture "$tmpdir"

    local out; out=$(_agent_src "$AGN_SRC/block.md" "/workspace/.claude/agents/block.md" "ro")
    [[ "$out" == "$AGN_SRC/block.md" ]] \
        || fail "D11: a block-form tools: list was rewritten — the list items would be orphaned"
    return 0
}

# ── A3 — an explicit exclusion is honoured, never overridden ─────────

test_agn_a3_disallowed_member_is_not_added_back() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _agn_env; _agn_fixture "$tmpdir"

    local out; out=$(_agent_src "$AGN_SRC/denied.md" "/workspace/.claude/agents/denied.md" "ro")
    grep -q '^tools:.*SendMessage' "$out" \
        && fail "A3: cco added a tool the user explicitly denied — and upstream removes a tool listed in both, so it would not even work"
    grep -q '^disallowedTools:.*SendMessage' "$out" \
        || fail "A3: cco rewrote the user's disallowedTools line"
    return 0
}

test_agn_a3_exclusion_is_reported_as_no_return_channel() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _agn_env; _agn_fixture "$tmpdir"

    _agent_src "$AGN_SRC/denied.md" "/workspace/.claude/agents/denied.md" "ro" >/dev/null
    local msg; msg=$(_agents_report_flush 2>&1)
    echo "$msg" | grep -q "denied.md" \
        || fail "A3: an agent left without a return channel was not named:"$'\n'"$msg"
    echo "$msg" | grep -qi "no return channel" \
        || fail "A3: the report does not say the agent cannot deliver:"$'\n'"$msg"
    return 0
}

# ── D6 — the change is announced, never silent ───────────────────────

test_agn_d6_widening_is_announced_naming_the_agents() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _agn_env; _agn_fixture "$tmpdir"

    _agent_src "$AGN_SRC/analyst.md" "/workspace/.claude/agents/analyst.md" "ro" >/dev/null
    local msg; msg=$(_agents_report_flush 2>&1)
    echo "$msg" | grep -q "analyst.md" \
        || fail "D6: the announcement does not name the affected agent:"$'\n'"$msg"
    echo "$msg" | grep -q "SendMessage" \
        || fail "D6: the announcement does not say what was granted:"$'\n'"$msg"
    return 0
}

# ⚠ `warn`, never `info`/`note:` — A5 (FI-55) will make `cco start` pause on its
# warnings and gates on exactly this classification. ADR-0058 A2 ships D6 ahead of
# A5 deliberately, which makes the classification the one thing that cannot be got
# wrong now: a message emitted as a note stays invisible after A5 lands.
test_agn_d6_report_is_a_warning_not_a_note() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _agn_env; _agn_fixture "$tmpdir"

    _agent_src "$AGN_SRC/analyst.md" "/workspace/.claude/agents/analyst.md" "ro" >/dev/null
    local msg; msg=$(_agents_report_flush 2>&1)
    echo "$msg" | grep -q "⚠" \
        || fail "D6: the announcement is not a warn — A5 will never pause on it:"$'\n'"$msg"
    return 0
}

# A clean session says nothing: a warning stream that fires on every start is a
# stream nobody reads, which is the very defect A5 exists to fix.
test_agn_d6_clean_session_is_silent() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _agn_env; _agn_fixture "$tmpdir"

    _agent_src "$AGN_SRC/free.md" "/workspace/.claude/agents/free.md" "ro" >/dev/null
    local msg; msg=$(_agents_report_flush 2>&1)
    [[ -z "$msg" ]] \
        || fail "D6: a session with nothing to report still warned:"$'\n'"$msg"
    return 0
}

# ── Degradation: no work dir, no normalization, but never a lost mount ──

test_agn_uninitialized_normalizer_still_mounts_the_definition() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _agn_env; _agn_fixture "$tmpdir"
    unset _CCO_AGN_DIR _CCO_AGN_REPORT

    local out; out=$(_agent_src "$AGN_SRC/analyst.md" "/workspace/.claude/agents/analyst.md" "ro")
    [[ "$out" == "$AGN_SRC/analyst.md" ]] \
        || fail "an uninitialized normalizer must degrade to the original file, never to an empty path"
    return 0
}
