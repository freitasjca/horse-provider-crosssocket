# Fork-sync automation for `freitasjca/Delphi-Cross-Socket`

Authoritative reference for the GitHub Actions workflow that keeps the
`freitasjca/Delphi-Cross-Socket` fork automatically aligned with upstream
`winddriver/Delphi-Cross-Socket`, while preserving the fork-only additions
(CnPack subset, `SetCipherList`, PATCH-CSHTTP-3, boss.json, workflow self-files).

This document captures **what was prepared, why, and how to operate it**.
It is the canonical source if anyone (future you, a successor maintainer)
needs to understand or modify the fork-sync system.

---

## 1. Background and intent

### Why the fork exists at all

`freitasjca/Delphi-Cross-Socket` started as a fork of
`winddriver/Delphi-Cross-Socket` to carry features and fixes that hadn't
landed upstream:

| Fix tag | Status as of 2026-08-04 |
|---|---|
| `PATCH-IOCP-1` shutdown-cascade race | **Obsolete** — upstream fixed independently |
| `PATCH-CSHTTP-1` zero-body parser hang | **Obsolete** — upstream `SetNoBody` mechanism is functionally equivalent and RFC 7230-correct |
| `TCrossHttpClientConnection._OnBodyEnd` nil-guard | **Obsolete** — upstream line 2028 has the guard |
| `PATCH-CSHTTP-2` CL=0 hang | **Obsolete** — upstream commit `f543650e` implements the identical fix |
| `MTLS-1/2` `AddCACertificate(File)` + `SetVerifyPeer(Boolean)` | **In upstream** winddriver ≥2026-08 (API renamed from `SetCACertificate`); included in fork v1.0.6 |
| `TLSOPT-1` password-in-`SetPrivateKeyFile` | **In upstream** winddriver ≥2026-08; included in fork v1.0.6 |
| `PATCH-CSHTTP-3` keep-alive retry | **Fork-only** — not in upstream winddriver; included in fork v1.0.6 |
| `TLSOPT-2` `SetCipherList` | **Fork-only** — not in upstream winddriver; included in fork v1.0.6 |

The remaining fork-only deltas are **`SetCipherList`** (TLS 1.2 cipher override) and **PATCH-CSHTTP-3** (keep-alive retry in `TCrossHttpClient`). mTLS and password-in-key are now in upstream. The workflow automates upstream sync down to zero human involvement on the happy path.

### Why the fork still exists

The fork remains necessary because `winddriver/Delphi-Cross-Socket` is not Boss-installable (no `boss.json`, CnPack dependency not Boss-resolvable). The fork vendors the CnPack subset and ships `SetCipherList` + PATCH-CSHTTP-3. A current stable release (`v1.0.6`) keeps the fork **as close to upstream as possible** — minimising the surface area where it can diverge silently.

### Operational philosophy

- **Upstream is the source of truth.** Every sync resets the fork to
  upstream's tip and *re-layers* the fork-only additions on top. This
  guarantees the fork never carries stale copies of files upstream has
  rewritten.
- **No manual sync.** A daily cron handles the common case; the rare
  failure case opens a GitHub issue with recovery instructions.
- **Idempotency via marker tag.** `last-synced-upstream` records the last
  upstream sha the workflow successfully reset to. If upstream hasn't
  advanced, the workflow exits in ~30 s without touching the fork.
- **No notifications on success.** Silent success is the goal; failure
  is the only event that needs human attention.

---

## 2. What was prepared

Four files staged in `/workspaces/horse-crosssocket/crosssocket-fork-sync-action/`,
ready to commit onto the `master` branch of
`freitasjca/Delphi-Cross-Socket`:

```
crosssocket-fork-sync-action/
├── INSTRUCTIONS.md                                       ← Windows-side deployment runbook
├── .github/
│   └── workflows/
│       └── sync-upstream.yml                             ← the workflow itself (212 lines)
└── .sync/
    ├── README.md                                         ← in-repo design doc (ships into fork)
    └── patches/
        ├── Net.CrossSslSocket.Base.pas.patch             ← mTLS additions to base SSL socket (57 lines)
        └── Net.CrossSslSocket.OpenSSL.pas.patch          ← OpenSSL implementation overrides (120 lines)
```

### `INSTRUCTIONS.md` — deployment runbook

Step-by-step Windows-side procedure: copy files into the fork checkout,
verify patches apply against the current upstream pristine, commit, push
to `master`, mirror to `dev`, enable write permissions in repo settings,
trigger the first manual run, and confirm the expected post-run state.
Also documents the small set of safe tunables (`CNVCL_REF`, cron
schedule, `MIRROR_BRANCH`) and the do-not-touch items (`.sync/` location,
`last-synced-upstream` tag).

### `.sync/README.md` — design doc that ships into the fork

Lives inside the fork after deployment so future maintainers find the
design rationale next to the patches. Documents:

- The role of `.sync/` (workflow's stable source of truth, survives the
  daily reset because it's preserved/restored via `/tmp`)
- Exactly what each patch adds (every method signature listed, so the
  patches can be hand-grafted onto a future upstream version if `git
  apply --3way` ever fails)
- The patch-regeneration procedure (`diff -u` against upstream pristine)
- The 18-file CnPack manifest (1 `.inc` + 17 `.pas`, split `CnPack/Common` +
  `CnPack/Crypto`) — the workflow `find`s each unit wherever it lives in
  `cnvcl/Source` (resilient to upstream relocations) and fails loudly if the
  transitive closure is broken

### `.sync/patches/Net.CrossSslSocket.Base.pas.patch` — fork-only additions

> **Note (2026-08-04):** mTLS (`AddCACertificate` family + `SetVerifyPeer`) and
> password-in-`SetPrivateKeyFile` merged into upstream winddriver. The patches
> below no longer track those — the workflow now only needs to preserve
> `SetCipherList` (TLSOPT-2, fork-only). Update the `.sync/patches/` files
> accordingly when regenerating.

Current fork-only addition in `TCrossSslSocketBase`:

- `procedure SetCipherList(const ACipherList: string); virtual; abstract;`

Historical additions now in upstream (no longer patched separately):
- `AddCACertificate` overload family (renamed from `SetCACertificate` in upstream ≥2026-08)
- `AddCACertificateFile`
- `SetVerifyPeer(const AVerify: Boolean)`
- `APassword` parameter on `SetPrivateKey` / `SetPrivateKeyFile` overloads

### `.sync/patches/Net.CrossSslSocket.OpenSSL.pas.patch` — fork-only additions

Current fork-only concrete override in `TCrossOpenSslSocket`:

- `SetCipherList(ACipherList)` → `SSL_CTX_set_cipher_list(FSslCtx, PAnsiChar(LAnsi))`;
  raises `ESsl` if the cipher string is rejected

Historical additions now in upstream (no longer patched separately):
- `AddCACertificate(buf, size)` → `BIO_new_mem_buf` + `PEM_read_bio_X509` +
  `SSL_CTX_add_client_CA` + `X509_STORE_add_cert`
- `SetVerifyPeer(Boolean)` →
  `SSL_CTX_set_verify(SSL_VERIFY_PEER or SSL_VERIFY_FAIL_IF_NO_PEER_CERT, nil)` vs `SSL_VERIFY_NONE`
- Password as direct parameter on `SetPrivateKey(buf, size, password)`

The original patches were generated with `diff -u` against
`winddriver/Delphi-Cross-Socket@master` as it stood on 2026-05-30.
When regenerating after upstream merges, generate against the current
upstream HEAD using the same `diff -u` procedure in `.sync/README.md`.

---

## 3. How the workflow works

### Trigger

```yaml
on:
  schedule:
    - cron: '17 4 * * *'   # 04:17 UTC daily — off-peak, away from hour boundaries
  workflow_dispatch:
    inputs:
      force_resync:        # bypasses the last-synced-upstream short-circuit
        required: false
        default: 'false'
```

Off-peak timing matters: GitHub's cron scheduler is best-effort and can
defer jobs by 5–10 minutes at peak times. `17 4` avoids the herd at
`0 *` and `0 0`.

### Permissions

```yaml
permissions:
  contents: write   # force-push master/dev, update the marker tag
  issues:   write   # open failure issue
```

These are the minimal scopes required. No personal access token is
needed; the default `GITHUB_TOKEN` is sufficient unless branch protection
rules require a higher-trust actor.

### Step sequence

```
1. Checkout fork @ master       ─── full history (fetch-depth: 0) so we can read the marker tag
2. Configure git identity        ─── github-actions[bot]
3. Preserve fork-only files      ─── cp -a .sync .github boss.json .gitignore LICENSE README.md → /tmp/preserve
4. Fetch upstream                ─── git remote add upstream … && git fetch upstream master --tags
5. Detect upstream change        ─── compare upstream/master sha against `last-synced-upstream` tag
                                     short-circuit if equal AND force_resync != true
─── if no_change: jump to step 11 ───
6. Reset to upstream master      ─── git reset --hard upstream/master
7. Restore fork-only files       ─── cp -a /tmp/preserve/* back into place
8. Clone CnPack and copy files   ─── git clone --depth 1 cnvcl; copy 1 .inc + 14 .pas into CnPack/
9. Apply mTLS patches            ─── git apply --3way for each .patch file
10. Commit, push master, mirror  ─── force-with-lease to master and dev
11. Update last-synced tag       ─── git tag -f last-synced-upstream upstream-sha; push -f
12. On failure: open issue       ─── via actions/github-script@v7, body = recovery runbook
```

### The preserve-reset-restore pattern

`git reset --hard upstream/master` is destructive — it would wipe
`.sync/`, `.github/workflows/sync-upstream.yml`, and `boss.json`. The
workflow can't survive its own reset that way. The fix:

1. **Before reset:** copy every fork-only path into `/tmp/preserve/`.
   These are exactly the paths that do not exist in upstream.
2. **After reset:** copy them back from `/tmp/`.

This is **Option A**. The alternative (**Option B**) — keeping fork-only
files on a sidecar branch and merging — was rejected because it would
mean two branches to maintain and a more complex merge semantics. Option
A keeps everything on `master` and treats the fork-only files as
*overlays* re-applied each sync.

### `--3way` patch application

`git apply --3way` falls back to a three-way merge if anchor lines have
moved, using the original-blob hash embedded in the patch header. This
is lenient enough to survive line-number shifts above/below the patched
block (the common case as upstream evolves) and strict enough to fail
loudly if upstream actually rewrote one of the affected functions.

When `--3way` fails, the step exits non-zero, the workflow fails, and
the `Open issue on failure` step opens a GitHub issue with the recovery
runbook. The fork stays at its previous-good state because no
push has happened yet.

### Marker tag idempotency

`last-synced-upstream` is a lightweight git tag pointing at the upstream
sha used in the last successful sync. The Detect step compares it against
`upstream/master`:

- Equal → no work to do, exit ~30 s in
- Different → upstream advanced; do the full reset-and-reapply pass
- `force_resync: true` → ignore the comparison

The tag is updated at the **end** of the workflow, after a successful
push. If any step fails before that, the tag stays pinned to the
previous good sha, so the next run retries.

### Mirror branch (`dev`)

The fork tracks two branches in lockstep — `master` and `dev`. The
workflow force-pushes master, then resets dev to match and pushes that
too. `MIRROR_BRANCH: ''` disables this step if the dev branch is ever
retired.

---

## 4. Operational behaviour

| Scenario | Workflow outcome | Notification |
|---|---|---|
| Daily cron, upstream unchanged | ~30 s no-op; `last-synced-upstream` already matches; no commits/pushes | None |
| Daily cron, upstream advanced, patches apply cleanly | Force-pushes master + dev with reapplied overlays; marker tag advances | None |
| Daily cron, upstream rewrote SSL files near patch anchors | Action fails; GitHub issue auto-opened with step-by-step recovery; fork stays at previous good state | Issue with `sync` + `needs-attention` labels |
| Manual `workflow_dispatch` with `force_resync: true` | Bypasses marker check; does full reset-and-reapply even if upstream unchanged | None (or failure issue if patches don't apply) |
| Transient network / GitHub API failure | Step fails; issue created; next scheduled run typically recovers | Issue created — usually safe to close on the next-day success |

### Failure-mode issue body

The auto-created issue body contains the full recovery runbook:

1. Local clone + reset to upstream
2. Restore fork-only files from previous fork tip
3. **Manually graft** the fork-only additions (`SetCipherList` in Base.pas + OpenSSL.pas)
   into the new upstream files — `.sync/README.md` documents each method signature
4. **Regenerate the patch files** from a clean baseline using `diff -u`
5. Commit, push, re-run workflow

The exact commands are embedded in the issue body — copy-paste runnable.

---

## 5. What's safe to tune

| Setting | Location | Notes |
|---|---|---|
| Cron schedule | `on.schedule.cron` | Daily 04:17 UTC by default. Adjust to taste; avoid hour boundaries. |
| `CNVCL_REF` | workflow `env:` | `master` for rolling, or pin to a tested tag (e.g. `v3.1.2`). Pin for reproducibility. |
| `MIRROR_BRANCH` | workflow `env:` | Set to `''` to disable dev-branch mirroring. |
| CnPack manifest | workflow step "Clone CnPack" + `.sync/README.md` table | Add/remove `.pas` files as the Delphi-Cross-Socket Utils.Hash.pas dependency set evolves. Keep the two locations in sync. |

## 6. What must not be changed

- **`.sync/` location.** Must not be moved under any path that exists
  in upstream (`Net/`, `Utils/`, etc.) — the reset would obliterate it
  before the restore step has a chance to bring it back.
- **`last-synced-upstream` tag.** Never delete manually. To force a
  resync, use `workflow_dispatch` with `force_resync: true`.
- **Patch files in `.sync/patches/`.** Never edit by hand. Always
  regenerate via the `diff -u` procedure documented in `.sync/README.md`
  so line numbers, context, and embedded blob hashes stay consistent.

---

## 7. End-state when upstream merges the remaining fork-only additions

> **2026-08-04 update:** mTLS (`AddCACertificate` / `SetVerifyPeer`) and
> password-in-key have already merged into upstream winddriver. The two
> remaining fork-only additions are `SetCipherList` (TLSOPT-2) and
> PATCH-CSHTTP-3 (keep-alive retry in `TCrossHttpClient`).

When `SetCipherList` and PATCH-CSHTTP-3 land in upstream, the fork's
last reason to exist disappears. Procedure for retirement:

1. Confirm both additions are present on `winddriver/Delphi-Cross-Socket@master`.
2. Delete `.sync/patches/Net.CrossSslSocket.Base.pas.patch` and
   `Net.CrossSslSocket.OpenSSL.pas.patch` from the fork.
3. Run the workflow once with `force_resync: true` — the fork will now be
   bit-for-bit identical to upstream, plus only the CnPack subset and
   `boss.json` as additions.
4. Update `horse-provider-crosssocket/boss.json` and docs to depend on
   the upstream repo (or alternative installation path) directly.
5. Archive the fork repo with a redirect note in its README.

The workflow itself can stay running until step 4 — it provides
defence-in-depth against accidental drift even during the transition.

---

## 8. Cross-references

- [Provider README installation paths](../README.md) — Path A
  (upstream + manual CnPack) vs Path B (fork v1.0.6 for `SetCipherList` + PATCH-CSHTTP-3)
- [`patches/horse/doc/providers.md`](../../horse/doc/providers.md) —
  current default-install guidance in the user-facing Horse docs
- [`Net.CrossSslSocket.Base.pas`](../../Delphi-Cross-Socket/Net/Net.CrossSslSocket.Base.pas)
  and
  [`Net.CrossSslSocket.OpenSSL.pas`](../../Delphi-Cross-Socket/Net/Net.CrossSslSocket.OpenSSL.pas)
  — reference copies of the patched files (for hand-grafting if the
  workflow ever fails)
- [`PATCH-HORSE-2-normalisation-plan.md`](PATCH-HORSE-2-normalisation-plan.md)
  — unrelated, but the closest analogue for "how do we document an
  automated infrastructure change?"

---

## Appendix · staging-folder location

While the four files live in
`/workspaces/horse-crosssocket/crosssocket-fork-sync-action/` in this workspace, that
path is **staging only** — they are not committed here. Deployment is to
the fork's own checkout (`C:\lang\Repo\Delphi-Cross-Socket\`), as
documented in `INSTRUCTIONS.md`. Once deployed, this workspace's copy can
be deleted or retained as a backup.
