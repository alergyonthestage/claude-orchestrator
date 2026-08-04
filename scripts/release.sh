#!/usr/bin/env bash
# scripts/release.sh — cut a cco release (maintainer-run, local). ADR-0037 D6/D7.
#
# Bumps package.json `version` (the single source of truth), runs the test suite
# + the npm-pack hygiene check locally as a fast pre-flight, commits, creates an
# annotated tag, and pushes. Pushing the tag triggers .github/workflows/release.yml
# which re-runs the suite + the read-only FRAMEWORK_ROOT gate + hygiene, then
# `npm publish --access public`. No npm token is needed on this machine — the
# token lives in CI (the NPM_TOKEN GitHub Actions secret).
#
# Usage:
#   scripts/release.sh <x.y.z> [--dry-run] [--allow-branch] [--full-tests|--skip-tests]
#
#   <x.y.z>          New semantic version (must be > the current package.json one)
#   --dry-run        Show every step without committing/tagging/pushing
#   --allow-branch   Skip the "must be on main" guard (use with care)
#   --full-tests     Run the ENTIRE test suite locally (~2-3 min). Default: only the
#                    fast read-only publish gate — CI re-runs the full suite on the tag.
#   --skip-tests     Skip local tests entirely (CI still runs the full suite + gate).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '\033[0;36m• %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m✓ %s\033[0m\n' "$*"; }
step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

VERSION=""; DRY_RUN=false; ALLOW_BRANCH=false; SKIP_TESTS=false; FULL_TESTS=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)      DRY_RUN=true; shift ;;
        --allow-branch) ALLOW_BRANCH=true; shift ;;
        --full-tests)   FULL_TESTS=true; shift ;;
        --skip-tests)   SKIP_TESTS=true; shift ;;
        -h|--help)      sed -n '2,22p' "$0"; exit 0 ;;
        -*)             die "Unknown option: $1" ;;
        *)              [[ -z "$VERSION" ]] && VERSION="$1" || die "Unexpected argument: $1"; shift ;;
    esac
done
$SKIP_TESTS && $FULL_TESTS && die "--skip-tests and --full-tests are mutually exclusive."

command -v jq  >/dev/null || die "jq is required."
command -v git >/dev/null || die "git is required."
[[ -n "$VERSION" ]] || die "Usage: scripts/release.sh <x.y.z> [--dry-run] [--allow-branch]"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version must be semantic x.y.z (got '$VERSION')."

run() { if $DRY_RUN; then printf '   [dry-run] %s\n' "$*"; else eval "$@"; fi; }

# ── Pre-flight checks ────────────────────────────────────────────────
step "Pre-flight"

local_branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$local_branch" != "main" ]] && ! $ALLOW_BRANCH; then
    die "Releases are cut from 'main' (on '$local_branch'). Merge develop→main first, or pass --allow-branch."
fi

[[ -z "$(git status --porcelain)" ]] || die "Working tree is dirty — commit or stash first."

CURRENT="$(jq -r '.version' package.json)"
[[ "$VERSION" != "$CURRENT" ]] || die "Version $VERSION is already the current package.json version."
# Ensure the new version sorts strictly after the current one.
greatest="$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
[[ "$greatest" == "$VERSION" ]] || die "Version $VERSION is not greater than current $CURRENT."

TAG="v$VERSION"
git rev-parse "$TAG" >/dev/null 2>&1 && die "Tag $TAG already exists."
ok "main / clean tree / $CURRENT → $VERSION / $TAG free"

# Reminder: changelog entries are added per-feature during development, not here.
if ! grep -q "Browse the bundled user docs offline" changelog.yml 2>/dev/null; then :; fi
info "Verify changelog.yml has entries for everything user-visible in this release."

# ── Local gate: tests + hygiene ──────────────────────────────────────
# Nothing is committed/tagged/pushed until AFTER these pass, so Ctrl-C here is
# always safe. The full suite is slow (~2-3 min) and CI re-runs it authoritatively
# on the tag, so the default pre-flight is just the fast read-only publish gate.
step "Release-critical checks"
if $SKIP_TESTS; then
    info "Skipping local tests (--skip-tests). CI still runs the full suite + gate on the tag."
elif $FULL_TESTS; then
    info "Running the FULL test suite (~2-3 min). Ctrl-C is safe — no tag is created until it passes."
    run "bin/test"
else
    info "Running the read-only FRAMEWORK_ROOT publish gate (fast). Use --full-tests for the whole suite."
    run "bin/test --file test_readonly_framework"
fi

step "npm pack hygiene"
"$REPO_ROOT/scripts/check-pack-hygiene.sh" || die "pack hygiene failed."

# ── Bump, commit, tag, push ──────────────────────────────────────────
# `package.json` is the single source of truth, but README.md states the version in
# prose on the repo's front page — and that copy DRIFTED: it shipped reading v0.5.1
# while package.json was already 0.5.2, because nothing kept the duplicate honest.
# Rewriting it here does. The marker is REQUIRED: if the line is reworded the script
# dies instead of silently skipping the bump, which is how the drift happened in the
# first place. The status word is matched generically so Alpha → Beta needs no change.
_readme_version() {
    grep -oE '\*\*[A-Za-z]+ \(v[0-9]+\.[0-9]+\.[0-9]+\)\*\*' README.md | head -1 \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
}

step "Bump package.json + README → $VERSION"
readme_was="$(_readme_version || true)"
[[ -n "$readme_was" ]] || die "README.md has no '**<Status> (vX.Y.Z)**' version marker, so this script cannot keep it in step with package.json. Restore the marker, or update _readme_version in scripts/release.sh."
if [[ "$readme_was" != "$CURRENT" ]]; then
    info "README said v$readme_was while package.json said $CURRENT — they had drifted; realigning both to $VERSION."
fi
if $DRY_RUN; then
    info "[dry-run] would set package.json .version = $VERSION"
    info "[dry-run] would set README.md marker v$readme_was → v$VERSION"
else
    tmp="$(mktemp)"; jq --arg v "$VERSION" '.version = $v' package.json > "$tmp" && mv "$tmp" package.json
    ok "package.json version = $(jq -r .version package.json)"
    # Not `sed -i`: BSD sed needs an argument there and GNU sed must not have one.
    tmp="$(mktemp)"
    sed "s/\*\*\([A-Za-z][A-Za-z]*\) (v${readme_was})\*\*/**\1 (v${VERSION})**/" README.md > "$tmp" && mv "$tmp" README.md
    [[ "$(_readme_version)" == "$VERSION" ]] || die "README.md rewrite did not take (still reads v$(_readme_version))."
    ok "README.md version = v$(_readme_version)"
fi

step "Commit + annotated tag + push"
run "git add package.json README.md"
run "git commit -m 'chore(release): $TAG'"
run "git tag -a '$TAG' -m 'Release $TAG'"
run "git push --follow-tags"

echo ""
ok "Release $TAG prepared."
echo "   CI (.github/workflows/release.yml) now runs the suite + read-only gate +"
echo "   hygiene, then 'npm publish --access public'. Watch the Actions tab."
$DRY_RUN && info "(dry-run: nothing was changed or pushed)"
