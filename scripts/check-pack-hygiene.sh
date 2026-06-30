#!/usr/bin/env bash
# scripts/check-pack-hygiene.sh — fail if the npm tarball would carry anything it
# must not (ADR-0037 D3 §2.1). Run locally by scripts/release.sh and in CI before
# `npm publish`. Inspects `npm pack --dry-run` (the exact publish manifest).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

command -v npm >/dev/null || { echo "✗ npm is required" >&2; exit 1; }

manifest="$(npm pack --dry-run 2>&1)"

# Paths that must NEVER appear in the tarball. The template scaffold placeholder
# templates/project/base/secrets.env is allowed (it is the only secrets.env and
# ships intentionally), so match secrets only OUTSIDE templates/.
# NB: a template's own .cco/ scaffold (templates/project/base/.cco/...) is a
# legitimate shipped file — do NOT match .cco/ generically. The repo's own root
# .cco/ is already excluded by the package `files` allowlist (not listed).
forbidden_res='(^|/)(tests/|bin/test$|reviews/|user-config/|docs/maintainers/|docs/archive/|docs/README\.md|scripts/|\.git/|\.github/|CONTRIBUTING\.md|SECURITY\.md|TODO\.md)|_test\.go|\.credentials\.json'

violations="$(printf '%s\n' "$manifest" \
    | sed -n 's/^npm notice *[0-9.]* *[kKmMgGbB]* *//p' \
    | grep -E "$forbidden_res" || true)"

# A real (non-template) secrets file leaking is also a violation.
secrets_leak="$(printf '%s\n' "$manifest" \
    | sed -n 's/^npm notice *[0-9.]* *[kKmMgGbB]* *//p' \
    | grep -E '(^|/)secrets\.env$' | grep -v '^templates/project/base/secrets\.env$' || true)"

if [[ -n "$violations$secrets_leak" ]]; then
    echo "✗ npm pack hygiene FAILED — forbidden paths in the tarball:" >&2
    printf '%s\n' "$violations" "$secrets_leak" | sed '/^$/d' | sed 's/^/    /' >&2
    exit 1
fi

echo "✓ npm pack hygiene OK ($(printf '%s\n' "$manifest" | grep -c '^npm notice .*[0-9]' ) lines inspected; no forbidden paths)"
