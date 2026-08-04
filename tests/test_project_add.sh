#!/usr/bin/env bash
# tests/test_project_add.sh — cco project add (P1 Commit 6; ADR-0023 D3)
#
# Embed-at-add: coordinate into the cwd project's .cco/project.yml + (with
# --path) the machine-local index binding. url-from-origin; flag applicability;
# duplicate guard; section creation. Mask-safe: `… || return 1`.

# Run bin/cco from a given cwd (inherits exported CCO_*/HOME); sets CCO_OUTPUT.
_pa_cco_in() {
    local dir="$1"; shift
    local rc=0
    CCO_OUTPUT=$(cd "$dir" && bash "$REPO_ROOT/bin/cco" "$@" 2>&1) || rc=$?
    return $rc
}

# Minimal decentralized project unit at <repo_root>/.cco/project.yml.
_pa_unit() {
    local root="$1"
    mkdir -p "$root/.cco"
    printf 'name: demo\nrepos:\n  - name: self\n' > "$root/.cco/project.yml"
}

test_add_repo_embeds_coordinate() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"

    _pa_cco_in "$tmp/dev/repo1" project add repo backend --url https://ex.com/backend.git --ref main || return 1
    local m="$tmp/dev/repo1/.cco/project.yml"
    assert_file_contains "$m" "- name: backend" || return 1
    assert_file_contains "$m" "url: https://ex.com/backend.git" || return 1
    assert_file_contains "$m" "ref: main" || return 1
}

test_add_repo_roundtrips_through_parser() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"

    _pa_cco_in "$tmp/dev/repo1" project add repo backend --url https://ex.com/b.git --ref dev || return 1
    # The embedded coordinate must be readable by the P0 parser.
    local out
    out=$(
        source "$REPO_ROOT/lib/colors.sh"
        source "$REPO_ROOT/lib/yaml.sh"
        yml_get_repo_coords "$tmp/dev/repo1/.cco/project.yml" | awk -F'\t' '$1=="backend"{print $2"|"$3}'
    )
    assert_equals "https://ex.com/b.git|dev" "$out" || return 1
}

test_add_repo_with_path_binds_index() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"
    mkdir -p "$tmp/dev/backend"

    _pa_cco_in "$tmp/dev/repo1" project add repo backend --url https://ex.com/b.git --path "$tmp/dev/backend" || return 1
    run_cco path list || return 1
    assert_output_contains "backend" || return 1
    assert_output_contains "$tmp/dev/backend" || return 1
}

test_add_repo_no_path_leaves_index_untouched() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"

    _pa_cco_in "$tmp/dev/repo1" project add repo backend --url https://ex.com/b.git || return 1
    run_cco path list || return 1
    assert_output_not_contains "backend" || return 1   # coordinate only; no index binding
}

test_add_repo_url_from_origin() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"
    mkdir -p "$tmp/dev/backend"
    git -C "$tmp/dev/backend" init -q || return 1
    git -C "$tmp/dev/backend" remote add origin https://ex.com/from-origin.git || return 1

    # No --url: must be derived from the clone's origin.
    _pa_cco_in "$tmp/dev/repo1" project add repo backend --path "$tmp/dev/backend" || return 1
    assert_file_contains "$tmp/dev/repo1/.cco/project.yml" "url: https://ex.com/from-origin.git" || return 1
}

test_add_mount_with_target_and_readonly() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"

    _pa_cco_in "$tmp/dev/repo1" project add mount assets --target /workspace/assets --readonly || return 1
    local m="$tmp/dev/repo1/.cco/project.yml"
    assert_file_contains "$m" "extra_mounts:" || return 1
    assert_file_contains "$m" "- name: assets" || return 1
    assert_file_contains "$m" "target: /workspace/assets" || return 1
    assert_file_contains "$m" "readonly: true" || return 1
}

test_add_llms_requires_url() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"

    local rc=0
    _pa_cco_in "$tmp/dev/repo1" project add llms docs || rc=$?
    [[ $rc -ne 0 ]] || { echo "ASSERTION FAILED: add llms without --url should fail"; return 1; }
    assert_output_contains "llms requires --url" || return 1
}

test_add_llms_embeds_url_and_variant() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"

    _pa_cco_in "$tmp/dev/repo1" project add llms anthropic --url https://docs.anthropic.com/llms.txt --variant full || return 1
    local m="$tmp/dev/repo1/.cco/project.yml"
    assert_file_contains "$m" "llms:" || return 1
    assert_file_contains "$m" "- name: anthropic" || return 1
    assert_file_contains "$m" "variant: full" || return 1
}

test_add_pack_embeds_coordinate() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"

    _pa_cco_in "$tmp/dev/repo1" project add pack mypack --url https://ex.com/packs.git --ref v1 || return 1
    local m="$tmp/dev/repo1/.cco/project.yml"
    assert_file_contains "$m" "packs:" || return 1
    assert_file_contains "$m" "- name: mypack" || return 1
    assert_file_contains "$m" "ref: v1" || return 1
}

test_add_pack_rejects_path() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"

    local rc=0
    _pa_cco_in "$tmp/dev/repo1" project add pack mypack --path "$tmp/x" || rc=$?
    [[ $rc -ne 0 ]] || { echo "ASSERTION FAILED: --path should be rejected for pack"; return 1; }
    assert_output_contains "not valid for pack" || return 1
}

test_add_duplicate_name_errors() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"

    _pa_cco_in "$tmp/dev/repo1" project add repo backend --url https://ex.com/b.git || return 1
    local rc=0
    _pa_cco_in "$tmp/dev/repo1" project add repo backend --url https://ex.com/other.git || rc=$?
    [[ $rc -ne 0 ]] || { echo "ASSERTION FAILED: duplicate add should fail"; return 1; }
    assert_output_contains "already present" || return 1
}

test_add_outside_project_errors() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/empty"

    local rc=0
    _pa_cco_in "$tmp/empty" project add repo x --url https://ex.com/x.git || rc=$?
    [[ $rc -ne 0 ]] || { echo "ASSERTION FAILED: add outside a project should fail"; return 1; }
    assert_output_contains "No .cco/project.yml" || return 1
}

# ── INV-YAML — the section boundary (R-E, cycle-1.2 S5) ──────────────
#
# Regression for the config-structure corruption: `_yml_append_coord` used to end
# a section at "the first top-level line that is not a comment", so a top-level
# comment block did NOT close the section and the insertion slid PAST it, landing
# after the NEXT section's header comment. On a project.yml scaffolded from the
# shipped base template — where extra_mounts/packs/llms/github/browser all ship
# commented out — the second `cco project add repo` landed its entry under the
# `# ── Docker options ──` banner, immediately before `docker:`. Observed live on
# the maintainer's `cave-ensemble`.
#
# The assertions below are derived from the RULE, not from the implementation:
# buffer the trailing run of top-level comment and blank lines; on the next
# top-level key emit BEFORE that run, then flush it. Indented commented examples
# are section content, so the new entry lands AFTER them.

# The shipped base template, interpolated, as <root>/.cco/project.yml. This is the
# fixture with the full comment furniture — the whole point of the golden test.
_pa_unit_from_base_template() {
    local root="$1"
    mkdir -p "$root/.cco"
    sed -e 's/{{PROJECT_NAME}}/demo/g' -e 's/{{DESCRIPTION}}/Demo project/g' \
        "$REPO_ROOT/templates/project/base/project.yml" > "$root/.cco/project.yml"
}

# Two adds through the real verb: the first upgrades the `repos: []` stub, the
# second takes the section-scan branch — the one that carried the defect.
_pa_two_adds_on_base_template() {
    local root="$1"
    _pa_unit_from_base_template "$root"
    _pa_cco_in "$root" project add repo alpha --url https://ex.com/a.git || return 1
    _pa_cco_in "$root" project add repo beta  --url https://ex.com/b.git || return 1
}

# GOLDEN-FILE ROUND TRIP. A YAML parse would call every misplacement equivalent
# (all of them parse to the same document), so placement can only be asserted on
# the exact resulting BYTES.
test_add_repo_golden_roundtrip_base_template() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_two_adds_on_base_template "$tmp/dev/repo1" || return 1

    local got="$tmp/dev/repo1/.cco/project.yml"
    local golden="$REPO_ROOT/tests/golden/project-add-base-template.yml"
    assert_file_exists "$golden" || return 1
    if ! diff -u "$golden" "$got"; then
        fail "INV-YAML: two 'cco project add repo' on the shipped base template did not"\
" reproduce tests/golden/project-add-base-template.yml byte-for-byte (diff above:"\
" '-' = golden, '+' = produced). If templates/project/base/project.yml changed on"\
" purpose, regenerate the golden and re-read the placement by hand."
        return 1
    fi
}

# PROVENANCE of the golden — so it cannot drift away from the template silently.
# The golden must be the interpolated template plus EXACTLY the four inserted
# lines, and nothing else: strip those four and restore the `repos: []` stub, and
# what remains must equal the template byte-for-byte. This pins the golden's
# CONTENT; the round trip above pins its ORDER. Neither alone is sufficient.
test_add_repo_golden_is_the_shipped_template_plus_the_entries() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local golden="$REPO_ROOT/tests/golden/project-add-base-template.yml"
    assert_file_exists "$golden" || return 1

    sed -e 's/{{PROJECT_NAME}}/demo/g' -e 's/{{DESCRIPTION}}/Demo project/g' \
        "$REPO_ROOT/templates/project/base/project.yml" > "$tmp/template.yml"
    grep -v -x -F \
        -e '  - name: alpha' -e '    url: https://ex.com/a.git' \
        -e '  - name: beta'  -e '    url: https://ex.com/b.git' \
        "$golden" | sed -e 's/^repos:$/repos: []/' > "$tmp/stripped.yml"

    if ! diff -u "$tmp/template.yml" "$tmp/stripped.yml"; then
        fail "INV-YAML: the golden is no longer the shipped base template plus the two"\
" added entries — templates/project/base/project.yml drifted (diff above:"\
" '-' = template, '+' = golden minus the entries). Regenerate the golden."
        return 1
    fi
}

# THE RULE, stated positionally and independently of the golden bytes. This is
# what actually fails on the pre-fix code: `beta` must sit INSIDE `repos:` —
# after the indented commented examples (they are section content) and BEFORE the
# `# ── Extra mounts` banner (a top-level comment block contiguous with the
# following key is THAT key's header, not this section's footer).
test_add_repo_entry_lands_inside_its_own_section() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_two_adds_on_base_template "$tmp/dev/repo1" || return 1
    local m="$tmp/dev/repo1/.cco/project.yml"

    local l_repos l_example l_beta l_banner l_docker
    l_repos=$(grep -n -x -F 'repos:'                  "$m" | head -1 | cut -d: -f1)
    l_example=$(grep -n -F '  #   description: "Backend API service"' "$m" | head -1 | cut -d: -f1)
    l_beta=$(grep -n -x -F '  - name: beta'           "$m" | head -1 | cut -d: -f1)
    l_banner=$(grep -n -F '# ── Extra mounts'         "$m" | head -1 | cut -d: -f1)
    l_docker=$(grep -n -x -F 'docker:'                "$m" | head -1 | cut -d: -f1)
    [[ -n "$l_repos" && -n "$l_example" && -n "$l_beta" && -n "$l_banner" && -n "$l_docker" ]] \
        || { fail "anchors missing (repos=$l_repos example=$l_example beta=$l_beta banner=$l_banner docker=$l_docker)"; return 1; }

    [[ "$l_beta" -gt "$l_repos" ]] \
        || { fail "INV-YAML: entry at line $l_beta is not inside 'repos:' (line $l_repos)"; return 1; }
    [[ "$l_beta" -gt "$l_example" ]] \
        || { fail "INV-YAML: entry at line $l_beta jumped ABOVE the indented commented examples (line $l_example) — indented comments are section content"; return 1; }
    [[ "$l_beta" -lt "$l_banner" ]] \
        || { fail "INV-YAML: entry at line $l_beta slid PAST the '# ── Extra mounts' banner (line $l_banner) — that comment block is the next key's header, so it must close 'repos:'. This is the R-E corruption (pre-fix the entry landed at ~$l_docker, just above 'docker:')"; return 1; }
}

# The buffered run is FLUSHED, never dropped: nothing between the entry and the
# next top-level key may go missing, and the trailing run must keep its order.
test_add_repo_preserves_the_buffered_comment_run() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_two_adds_on_base_template "$tmp/dev/repo1" || return 1
    local m="$tmp/dev/repo1/.cco/project.yml"

    sed -e 's/{{PROJECT_NAME}}/demo/g' -e 's/{{DESCRIPTION}}/Demo project/g' \
        "$REPO_ROOT/templates/project/base/project.yml" > "$tmp/template.yml"
    # Every template line except the mutated `repos: []` stub must survive, in
    # the same order — a buffer that leaks would silently delete user comments.
    grep -v -x -F 'repos: []' "$tmp/template.yml" > "$tmp/want.txt"
    grep -v -x -F -e '  - name: alpha' -e '    url: https://ex.com/a.git' \
                  -e '  - name: beta'  -e '    url: https://ex.com/b.git' \
                  -e 'repos:' "$m" > "$tmp/have.txt"
    if ! diff -u "$tmp/want.txt" "$tmp/have.txt"; then
        fail "INV-YAML: the buffered top-level comment/blank run was not flushed verbatim — template lines were lost or reordered (diff above)"
        return 1
    fi
}

# A section whose trailing run is a top-level comment block at EOF: the entry is
# emitted BEFORE the run there too (same rule, END arm), and the run survives.
test_add_repo_trailing_comment_run_at_eof() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/dev/repo1/.cco"
    printf 'name: demo\nrepos:\n  - name: self\n\n# a trailing note\n# and its second line\n' \
        > "$tmp/dev/repo1/.cco/project.yml"

    _pa_cco_in "$tmp/dev/repo1" project add repo backend --url https://ex.com/b.git || return 1
    local want got
    want=$(printf 'name: demo\nrepos:\n  - name: self\n  - name: backend\n    url: https://ex.com/b.git\n\n# a trailing note\n# and its second line\n')
    got=$(cat "$tmp/dev/repo1/.cco/project.yml")
    assert_equals "$want" "$got" || return 1
}
