# Phase II kickoff — privilege boundary (ADR-0047)

> **Session-resume handoff.** Start here to run **S1 Phase II** of hardening-v2 in a
> fresh, dedicated-context session. Phase I (the `(G,Pc,Po)` model) is **done + merged
> into the working tree**; this phase builds the enforcement on top of it.
>
> **Master plan**: [`implementation-handoff.md`](implementation-handoff.md) (read §1
> operating constraints + §5 Phase II). **Design**:
> [ADR-0047](../decisions/0047-config-access-enforcement.md) (the whole ADR — it is the
> spec). **Model it enforces**: [ADR-0046](../decisions/0046-unified-cco-access-model.md)
> §7 (read-visibility + write-authority tables — the helper's gate).

---

## 1. Starting state (as of 2026-07-09)

- **Branch**: `feat/config-access/e2e-review`. **HEAD**: `274723e` (Phase I complete).
  The branch is **NOT pushed** — push both branches from the Mac.
- **Suite baseline**: `bash bin/test` → **1169 passed, 0 failed** (in-session; the
  memory ~1147/1 env-only fail is neutralized by `bin/test`). Never regress this.
- **Phase I delivered** (5 commits `ec56f9f`→`274723e`): the resolved session access is
  now the triple **`(G, Pc, Po)`** (each `none|ro|rw`). Host-side `cco start` resolves it
  (`_start_resolve_access`, scalar preset OR granular `global=…,current=…,others=…` OR the
  project.yml `access.cco` map), exports it as **`CCO_ACCESS_TRIPLE=G,Pc,Po`** (+ the label
  `CCO_CCO_ACCESS`). In-container, `lib/access-scope.sh` reads it (`_env_triple`/`_env_axis`)
  and derives read-visibility + write-authority **per axis**. `edit-global` is redefined
  `(rw,rw,none)` (writes the project too). The shim gate is per-axis
  (`_cco_triple_write_satisfies`).
- **Deferred (not Phase II)**: the §6 multi-repo Pc mount-narrowing (flag
  `access.cco.include_member_configs` is plumbed/read/documented; the hosting-vs-member
  `:ro` narrowing is a follow-up — see the DEFERRED note in `_start_generate_compose`).

## 2. What Phase II must do (ADR-0047 §2/§3)

Close the **S1/S1b confidentiality bypass**: today a `read-project` agent can `cat` the
mounted STATE index / DATA bucket and read every other project's name/host-path/tags/
remote-URLs (output-scoping filters command output, never the raw files; agent + cco share
uid `claude`, no FS confinement). Fix = a **privilege boundary** around the **internal store
only** (STATE index, DATA registries, CACHE internals). Config-content trees (`~/.cco`,
`<repo>/.cco`) keep their current mount model — **not the leak**.

Mechanism (empirically grounded — ADR-0047 §8 `fakeowner` Test A/B/C, macOS Docker Desktop):
`chown`/`chmod` on bind-mount **content** is not DAC-enforced, but the kernel checks path
**traversal** on the real **parent** inode. So nest the internal store under a
**`cco-svc`-owned, mode-0700, real-container-FS parent** the `claude` user cannot traverse
(→ `EACCES`), reached by `cco` via a **setuid `cco-svc` helper** that enforces `(G,Pc,Po)`.

## 3. Build phases (implementation-handoff §5 Phase II — atomic units)

1. **Dockerfile**: create the **`cco-svc`** uid; bake the **minimal setuid helper** (owned
   `cco-svc`, setuid bit); create **`/var/lib/cco-internal/`** owned `cco-svc`, **mode 0700**.
2. **`config/entrypoint.sh`**: establish + **lock down the privileged root first**
   (chmod-before-use, mirroring the proxy `:47-85`); make `$HOME/.local/{state,share,cache}/cco`
   **symlinks** into that root (Test B layout). `claude` must not own/traverse the root (R1).
3. **`lib/paths.sh`**: XDG resolver (`_cco_state_dir`/`_cco_data_dir`/`_cco_cache_dir`) →
   the privileged root; internal-store **primitives re-exec through the setuid helper**.
4. **The setuid helper** enforces `(G,Pc,Po)` (ADR-0046 §7) from the **trusted session
   descriptor** (R2) — never `argv`/env; **fail-closed** absent a valid descriptor.
5. **`lib/cmd-start.sh`**: write the `cco-svc`/root-owned **session descriptor** (`:ro`,
   the resolved triple — reuse the Phase I `cco_g/cco_pc/cco_po` locals) host-side; **simplify
   the internal mounts** — registries may mount **whole, rw** (the parent boundary confines;
   drop the `read-project` narrowing of the internal registries, ADR-0047 §4). Config-content
   mounts unchanged.

**Two hard requirements** (ADR-0047 §3): **R1** — privileged root lives OUTSIDE `claude`'s
owned tree (a `$HOME` parent could be renamed by the agent); XDG paths reach it via symlink
only. **R2** — the helper derives scope from the **trusted `cco start`-written descriptor**
(`:ro`, `cco-svc`/root-owned), never agent input; fail-closed.

**Tests**: new `tests/test_privilege_boundary.sh` — **S1/S1b acceptance**: a `read-project`
shell `cat`-ing the index → **EACCES** (parent traversal); the helper reads it;
`show_host_paths=off` truly hides host paths; fail-closed on a missing/forged descriptor.
`tests/test_paths.sh` for the resolver redirect.

## 4. Critical constraints (read before touching code)

- **This is a REBUILD phase, NOT in-session-verifiable.** `Dockerfile`, `entrypoint.sh`, the
  setuid helper, and the privileged-root layout are **image/entrypoint plumbing** — inactive
  in the running session (self-dev caveat). Write it, land atomic commits, mark each
  "verify after `cco build` on the Mac". The **suite** (`bin/test`) is the in-session net for
  the bash logic (`lib/paths.sh` resolver, `cmd-start.sh` descriptor gen); the boundary
  itself is verified only after `cco build` on the Mac.
- **Maintainer check-in AFTER Phase II** (the security core): confirm the `fakeowner` layout
  holds on the Mac (ADR-0047 §8 Test B) before Phase III builds on top.
- Code baselines to load: `lib/paths.sh` (XDG 4-bucket resolver + `_cco_container_operator`),
  `lib/cmd-start.sh` (`_start_generate_compose` mount block ~`:960-1120`, the operator-buckets
  block; `cco_g/cco_pc/cco_po` locals), `config/entrypoint.sh` (proxy chmod-first pattern
  `:47-85`), `Dockerfile` (the `cco-svc` uid + `/opt/cco` bake + proxy binary precedent),
  `lib/access-scope.sh` (`_cco_triple_write_satisfies` — the helper's gate logic to mirror).
- **Language**: respond in Italian; code/comments/docs in English. Atomic conventional commits.
- **Shipped-behavior docs**: the DOC5 cutover is **Phase VI (S3)** — do NOT rewrite user docs
  here. Living design docs (design.md §5, design-docker.md §1.2.3) are already reconciled.

## 5. Host commands (run on the Mac)

- **Before/independent of Phase II** — push Phase I: `git push` both branches (branch is
  unpushed; no build needed to *verify* Phase I — the suite already did, and host-side
  `cco start` resolution is active from bash immediately after checkout).
- **After Phase II lands** — `cco build && cco start` on the Mac to activate the image-baked
  boundary, then run `test_privilege_boundary.sh` / the S1/S1b acceptance manually, then the
  **maintainer check-in**.

## 6. After Phase II

→ **S2** (Phase III per-command A1 fixes: tag B5, `path list` scoping, whoami+ triple render,
B6 hint invariant + Phase IV config-editor/tutorial presets, ADR-0044) → **S3** (Phase V
registry ADR-0045 + B1–B4, Phase VI migrations/changelog/**DOC5 cutover**/`cco build`) →
**e2e v2 acceptance**. See [`implementation-handoff.md`](implementation-handoff.md) §4/§5.
