#!/usr/bin/env bash
# tests/test_utils.sh — general utility helpers (lib/utils.sh)
#
# Focus: _peel_tab(), the centralized TAB-record splitter that replaces the
# "peel by hand" idiom in the coordinate readers. The behaviour that justifies
# a dedicated helper (and forbids `IFS=$'\t' read`) is empty-MIDDLE-field
# survival — tab is whitespace to `read`, which would collapse them.

_utils_test_env() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
}

test_peel_tab_three_fields() {
    _utils_test_env
    local name url ref
    _peel_tab "$(printf 'myrepo\thttps://x/r.git\tmain')" name url ref
    [[ "$name" == "myrepo" ]]          || fail "name, got: $name"
    [[ "$url" == "https://x/r.git" ]]  || fail "url, got: $url"
    [[ "$ref" == "main" ]]             || fail "ref, got: $ref"
}

# The whole point: an empty MIDDLE field must survive (a url-less repo coord
# emitted as "name\t\tref"). `IFS=$'\t' read` would collapse it to name=, ref=.
test_peel_tab_empty_middle_survives() {
    _utils_test_env
    local name url ref
    _peel_tab "$(printf 'myrepo\t\tmain')" name url ref
    [[ "$name" == "myrepo" ]] || fail "name, got: $name"
    [[ -z "$url" ]]           || fail "url should be empty, got: $url"
    [[ "$ref" == "main" ]]    || fail "ref, got: $ref"
}

# An authored pack coordinate ("name" with empty url/ref/resource) is emitted
# as "name\t\t\t" (three trailing tabs) — all coordinate fields empty.
test_peel_tab_all_trailing_empty() {
    _utils_test_env
    local name url ref resource
    _peel_tab "$(printf 'mypack\t\t\t')" name url ref resource
    [[ "$name" == "mypack" ]] || fail "name, got: $name"
    [[ -z "$url" ]]           || fail "url empty, got: $url"
    [[ -z "$ref" ]]           || fail "ref empty, got: $ref"
    [[ -z "$resource" ]]      || fail "resource empty, got: $resource"
}

# Naming fewer vars than fields: trailing fields are ignored (the repos/coords
# call peels only name+url out of a name\turl\tref record).
test_peel_tab_fewer_vars_ignores_trailing() {
    _utils_test_env
    local name url
    _peel_tab "$(printf 'myrepo\thttps://x\tmain')" name url
    [[ "$name" == "myrepo" ]]    || fail "name, got: $name"
    [[ "$url" == "https://x" ]]  || fail "url must be exactly field 2 (no remainder), got: $url"
}

# Naming more vars than fields: the missing fields yield empty vars.
test_peel_tab_more_vars_than_fields() {
    _utils_test_env
    local name url ref
    _peel_tab "$(printf 'onlyname\t')" name url ref
    [[ "$name" == "onlyname" ]] || fail "name, got: $name"
    [[ -z "$url" ]]             || fail "url empty, got: $url"
    [[ -z "$ref" ]]             || fail "ref empty, got: $ref"
}

# llms coordinate shape: name\tdesc\tvariant\turl — naming all four positions
# extracts url correctly even though desc/variant sit between.
test_peel_tab_llms_four_fields() {
    _utils_test_env
    local name desc variant url
    _peel_tab "$(printf 'pydoc\tPython docs\tfull\thttps://llms.txt')" name desc variant url
    [[ "$name" == "pydoc" ]]            || fail "name, got: $name"
    [[ "$desc" == "Python docs" ]]      || fail "desc, got: $desc"
    [[ "$variant" == "full" ]]          || fail "variant, got: $variant"
    [[ "$url" == "https://llms.txt" ]]  || fail "url, got: $url"
}

# Spaces inside a field are part of the value (only TAB delimits).
test_peel_tab_preserves_spaces_in_field() {
    _utils_test_env
    local name desc
    _peel_tab "$(printf 'n\ta b  c')" name desc
    [[ "$desc" == "a b  c" ]] || fail "spaces must be preserved, got: $desc"
}

# _compose_vol — bind-mount volume lines must be YAML-double-quoted so a host
# path with a space (e.g. `Cave gif`) or a leading reserved char (`@`) cannot
# break `docker compose` parsing ('found character that cannot start any token').
test_compose_vol_quotes_space_path() {
    _utils_test_env
    local out; out=$(_compose_vol "/home/Cave gif" "/workspace/ref" "ro")
    assert_equals '      - "/home/Cave gif:/workspace/ref:ro"' "$out" \
        "a space-bearing host path must be double-quoted, with the mode suffix"
}

test_compose_vol_no_mode_omits_suffix() {
    _utils_test_env
    local out; out=$(_compose_vol "/a b" "/c")
    assert_equals '      - "/a b:/c"' "$out" "no mode → quoted host:container, no trailing :mode"
}

test_compose_vol_quotes_reserved_leading_char() {
    _utils_test_env
    # An '@'-leading source (reserved YAML indicator) must be quoted so it stays
    # a plain scalar instead of an alias/tag token that aborts the parser.
    local out; out=$(_compose_vol "@local" "/workspace/x" "ro")
    assert_equals '      - "@local:/workspace/x:ro"' "$out" "a reserved leading char must be quoted"
}

# ── _strip_surrounding_quotes (ADR-0050 D8 — path-input quote hygiene) ──

test_strip_quotes_single_and_double() {
    _utils_test_env
    [[ "$(_strip_surrounding_quotes "'/my/repo'")" == "/my/repo" ]] || fail "single-quote strip"
    [[ "$(_strip_surrounding_quotes '"/my/repo"')" == "/my/repo" ]] || fail "double-quote strip"
}

test_strip_quotes_noop_on_unquoted_and_unbalanced() {
    _utils_test_env
    [[ "$(_strip_surrounding_quotes "/my/repo")"  == "/my/repo" ]]  || fail "unquoted must be untouched"
    [[ "$(_strip_surrounding_quotes "'/my/repo")" == "'/my/repo" ]] || fail "unbalanced leading quote must be literal"
    [[ "$(_strip_surrounding_quotes '"')"          == '"' ]]         || fail "a lone quote must be literal"
}

test_strip_quotes_preserves_inner_characters() {
    _utils_test_env
    # only the OUTER pair is stripped; an inner quote survives.
    [[ "$(_strip_surrounding_quotes '"/a/O'\''Brien"')" == "/a/O'Brien" ]] || fail "inner quote must survive"
}
