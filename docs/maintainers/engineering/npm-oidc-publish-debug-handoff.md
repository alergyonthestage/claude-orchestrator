# Handoff — debug the CI npm publish (OIDC Trusted Publishing) failure

> **Created**: 2026-06-30 · **Track**: release engineering (continues Handover C).
> **Status**: BLOCKED on one thing only — the **CI `npm publish` step fails**. Everything
> else in the npm-packaging workstream (C) is implemented and green.
> **Goal of the next session**: make `.github/workflows/release.yml` publish
> `@claude-orchestrator/cco` to npm via OIDC, then finish the v0.5.1 release.

This doc deliberately separates **VERIFIED facts** (from CI logs / the repo) from
**UNVERIFIED hypotheses**. Do not treat hypotheses as settled.

---

## 1. Where we are (VERIFIED)

- **Workstream C (npm packaging) is implemented**, suite **1036/0**. Decisions in
  **[ADR-0037](decisions/0037-npm-packaging-distribution.md)**; the *how* in the
  living **[design doc](design/packaging-distribution.md)**; original analysis in
  **[Handover C](npm-packaging-distribution-handoff.md)**.
- Package: **`@claude-orchestrator/cco`** (npm org `claude-orchestrator`).
  **`0.5.0` is already published to npm** (bootstrapped manually by the maintainer
  with `npm login` + `npm publish`). The package therefore exists.
- Repo: **public**, `github.com/alergyonthestage/claude-orchestrator`. `package.json`
  `repository.url` = `git+https://github.com/alergyonthestage/claude-orchestrator.git`.
- Release flow (ADR-0037 D6): `scripts/release.sh <x.y.z>` bumps `package.json` +
  tags `vX.Y.Z` + pushes; the tag triggers `.github/workflows/release.yml` which runs
  the suite + read-only gate + `scripts/check-pack-hygiene.sh` + `npm publish`.
- **Auth = npm Trusted Publishing (OIDC), no stored token** (D6). The maintainer
  created an npm **Trusted Publisher** for the package and set the package access
  policy. (The *exact saved values* are asserted correct by the maintainer but were
  **not independently verified** from this side — see hypotheses.)

### Git state (VERIFIED, on a SHARED worktree)

- The container shares the maintainer's working tree (edits/commits here appear on
  their Mac and vice-versa). Current branch: **`main`**. Treat `main` commits as a
  shared-worktree hotfix and reconcile `main → develop` later (project git rule).
- `package.json` version = **`0.5.1`**. Tag **`v0.5.1` exists** but its CI run
  **failed at publish**, so **`0.5.1` is NOT on npm**. `0.5.0` is.
- Local `main` is **ahead of `origin/main`** by the recent debug commits — they must
  be **pushed** before any tag re-point takes effect in CI.
- Latest relevant commits (newest first): `fa22d6a` (workflow_dispatch + OIDC
  diagnostics), `b9dd330` (keep registry-url + clear NODE_AUTH_TOKEN + npm gate),
  `290bc22` (align to official OIDC workflow, node 24), plus the C implementation
  commits.

## 2. The problem (VERIFIED from CI logs)

`npm publish` in `release.yml` fails. The maintainer downloads each run's logs into
the repo root as `logs_<runid>/` (e.g. `logs_76867087659/publish/8_Publish*.txt`) —
read those for ground truth.

Error progression across attempts (each is a real CI log):

| Workflow config tried | Result |
|---|---|
| `setup-node` **with** `registry-url` (placeholder `NODE_AUTH_TOKEN` injected) | **E404** `PUT …/@claude-orchestrator%2fcco - Not found … or you do not have permission` |
| `setup-node` **without** `registry-url`, `NODE_AUTH_TOKEN: ""` | **ENEEDAUTH** `need auth … npm adduser` |
| node 24 + `registry-url` (placeholder token) | **E404** again |
| node 24 + `registry-url` + `NODE_AUTH_TOKEN: ""`, **npm 11.18.0** | **ENEEDAUTH** again |

**Key VERIFIED datapoint** (latest run, `logs_76867087659`): the
"Ensure an OIDC-capable npm" step printed **`npm version: 11.18.0`** — so npm is well
above the 11.5.1 OIDC requirement. The failure is **not** an npm-version problem.

**Interpretation (well-supported, not 100% certain):** OIDC is **not producing a
credential** — npm falls through to token/no-auth. ENEEDAUTH means npm got no
credential at all; E404 means it tried the (placeholder) token and was rejected.

## 3. What is already in the workflow now (VERIFIED — current `release.yml`)

- `permissions: { contents: read, id-token: write }` at workflow level.
- `actions/setup-node@v4` with `node-version: '24'`, `registry-url:
  'https://registry.npmjs.org'`, `package-manager-cache: false`.
- A step that `npm install -g npm@latest` and **fails if npm < 11.5.1**.
- `npm publish --access public` with `env: NODE_AUTH_TOKEN: ""`.
- **NEW debug affordances (commit `fa22d6a`):**
  - `workflow_dispatch: {}` trigger — run it **manually from the Actions tab, no tag,
    skips the suite** (tag-verify + suite are `if: github.event_name == 'push'`).
  - An **"OIDC diagnostics"** step that prints whether `ACTIONS_ID_TOKEN_REQUEST_URL`
    is PRESENT/MISSING, `github.workflow_ref`, and the effective `.npmrc`
    (authToken redacted).

## 4. ▶ START HERE — the fast debug loop (no tag, no 6-min suite)

The slow loop (full suite ~6 min + delete/recreate tag) is why we kept going in
circles. Use the manual path instead:

1. **Push** the pending `main` commits: `git push origin main`.
2. In GitHub → **Actions → "Release" → Run workflow** (branch `main`). ~1 min.
3. Read the **"OIDC diagnostics"** step output:
   - **If `ACTIONS_ID_TOKEN_REQUEST_URL: MISSING`** → GitHub is not issuing an OIDC
     token to the job. The fix is a **GitHub/repo Actions setting**, not the npm
     side (check repo Settings → Actions → General → Workflow permissions; and any
     org/enterprise OIDC restriction). This would explain ENEEDAUTH cleanly.
   - **If PRESENT** → GitHub issues the token; the rejection is on the **npm/registry
     side** → almost certainly the **Trusted Publisher config does not match** the
     run (re-verify, or delete & recreate it — see §5), OR npm isn't using OIDC.
4. If more detail is needed, temporarily run the publish with `npm publish
   --loglevel silly` to see the OIDC token-exchange HTTP call and the registry's
   response. (Remove the verbose flag and the §3 debug affordances before the final
   release commit.)

A **successful `workflow_dispatch` run publishes `0.5.1` for real** (same filename →
same trusted-publisher match) — so the debug loop and the fix converge.

## 5. Hypotheses to test (UNVERIFIED — do not assume)

In rough likelihood order, given npm 11.18.0 + ENEEDAUTH:

1. **GitHub not issuing the OIDC token** (`ACTIONS_ID_TOKEN_REQUEST_URL` missing) —
   a repo/org Actions permission setting. The §3 diagnostics step answers this
   directly. **Check first.**
2. **Trusted Publisher mismatch.** The maintainer asserts it is configured at
   `https://www.npmjs.com/package/@claude-orchestrator/cco/access` with
   org `alergyonthestage`, repo `claude-orchestrator`, **workflow filename
   `release.yml` (filename only)**, **Environment empty**, action **npm publish**.
   Per npm docs a mismatch in ANY field → token rejected. If §4.3 shows the OIDC URL
   PRESENT but publish still fails, **delete and recreate** the trusted publisher and
   re-verify every field character-by-character.
3. **Empty-token / `always-auth` interference.** `NODE_AUTH_TOKEN: ""` leaves
   `//registry.npmjs.org/:_authToken=` (empty) + `always-auth=true` in the
   setup-node `.npmrc`; an empty token may be treated as "auth configured" and block
   OIDC. Worth testing: drop `registry-url` AND unset the token entirely so the
   `.npmrc` has no authToken line at all (note: a no-registry-url attempt earlier
   also ENEEDAUTH'd, but that was before npm 11.18 was confirmed and before the
   trusted publisher was definitely saved — so re-test cleanly).
4. **Package access policy** ("Require 2FA and disallow tokens") interacting with
   OIDC. Trusted publishing is meant to work with it, but if all else fails, try the
   looser "require 2FA or token-with-bypass" policy as a diagnostic.

**Things RULED OUT (verified):** npm version (11.18.0 ✓); the package not existing
(0.5.0 is published ✓); the `files`/hygiene gate (passes in CI ✓); the test suite
(passes in CI before the publish step ✓); `package.json repository.url` mismatch
(matches ✓).

## 6. Reference docs & sources

- ADR-0037 §D6, design doc §5, Handover C §7.4 — the release-pipeline decision
  (auth = OIDC, no token).
- Official npm Trusted Publishing docs: <https://docs.npmjs.com/trusted-publishers/>
  (workflow fields; "workflow filename = filename only"; node 24 example).
- npm OIDC GA: <https://github.blog/changelog/2025-07-31-npm-trusted-publishing-with-oidc-is-generally-available/>
  (requires npm ≥ 11.5.1).
- The placeholder-`NODE_AUTH_TOKEN` gotcha:
  <https://github.com/orgs/community/discussions/176761>.

## 7. After it publishes — wrap-up checklist

- Finish the **v0.5.1** release (re-point/recreate the `v0.5.1` tag onto the commit
  that has the working workflow, or release `0.5.2` via `scripts/release.sh`).
- **Remove the debug affordances** from `release.yml` (the `workflow_dispatch`
  trigger and the OIDC-diagnostics step, or keep `workflow_dispatch` if a manual
  release path is wanted — but drop any `--loglevel silly`).
- Reconcile `main → develop`. Update the design doc DoD "Release" item to done.
- Verify on a Mac: `npm i -g @claude-orchestrator/cco` (closes the only remaining
  v1 DoD item — macOS install validation).
- Clean up the downloaded `logs_*/` directories from the repo root (untracked).
