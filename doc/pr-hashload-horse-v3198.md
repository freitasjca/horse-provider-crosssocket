# PR description — `freitasjca/horse:dev` → `HashLoad/horse:dev`

This is the prose body to paste into the GitHub PR. Title and the source/target are below.

---

## Suggested title

```
PATCH-HORSE-2: three-axis defines (Provider × AppType × Host) + bilingual doc tree + integration-test scaffold
```

(Under 70 chars per repo convention.)

## Source / target

- **Source:** `freitasjca:dev`
- **Target:** `HashLoad:dev`

> Note: `freitasjca/horse:dev` is currently *72 commits ahead of and 44 commits behind* `HashLoad/horse:dev`. Before opening the PR you may want to sync the fork (merge `upstream/dev` into local `dev`, resolve conflicts, push) so the GitHub diff shows only the meaningful changes. If you prefer to open the PR first and let upstream maintainers see the conflict markers, GitHub will compute the diff against the current `HashLoad:dev` tip regardless.

---

## Summary

This PR carries the **Horse-side** half of the CrossSocket interoperability work that has been developing in `freitasjca/horse-provider-crosssocket`. The provider repo itself is a separate package (Boss-installed) and is not part of this PR — only the changes to **`Horse.pas`**, **`Horse.Request.pas`**, **`Horse.Response.pas`**, the **provider abstract base**, and the supporting hybrid-adapter units are proposed here. Existing Indy / VCL / Daemon / Apache / CGI / FCGI / ISAPI projects continue to compile and run **byte-identically** when none of the new defines are set.

Two related changes are bundled:

1. **`Horse.pas` define normalization (PATCH-HORSE-2)** — split the flat `{$IFDEF}` chain into three orthogonal namespaces: `HORSE_PROVIDER_*` (transport), `HORSE_APPTYPE_*` (binary lifecycle shape), `HORSE_HOST_*` (host-managed runtimes). Legacy define names (`HORSE_CROSSSOCKET`, `HORSE_VCL`, `HORSE_DAEMON`, `HORSE_LCL`, `HORSE_APACHE`, `HORSE_ISAPI`, `HORSE_CGI`, `HORSE_FCGI`) continue to work forever via an alias block at the top of `Horse.pas`. The `{$MESSAGE FATAL}` block (PATCH-HORSE-1) is narrowed to combinations that are architecturally impossible (any `HORSE_PROVIDER_*` combined with any `HORSE_HOST_*`); combinations that were rejected because the chain couldn't express them (`HORSE_CROSSSOCKET` + `HORSE_VCL` / `HORSE_DAEMON` / `HORSE_LCL`) are now valid and routed to cross-product provider units in the consumer repo.

2. **Bilingual documentation tree** — a brand-new `doc/` directory with 12 topic pairs (EN + PT-BR) covering Getting Started, Routing, Request/Response, Middleware, Writing Middleware, Middleware Ecosystem, Providers, Deployment, Compiler Support, plus an index. All pairs are line-count matched. The PR also adds top-level `README.pt-BR.md` and `CONTRIBUTING.md` + `CONTRIBUTING.pt-BR.md`.

A third change set lives **outside this PR** but is the consumer of the changes above — referenced for context only:

3. **`horse-provider-crosssocket` v1.0.6** — five new cross-product Provider units (`Horse.Provider.CrossSocket.VCL`, `.Daemon` *(cross-platform: Windows Service + Linux daemon in one unit)*, `.FPC.Daemon`, `.FPC.LCL`, `.FPC.HTTPApplication`) plus an 8-shape integration test matrix (4 Delphi binary shapes × 4 Lazarus binary shapes, sharing a common 32-route definition).

## Why these changes

`Horse.pas` historically resolved one `THorseProvider` via a single conditional chain that accepted `HORSE_CROSSSOCKET`, `HORSE_VCL`, `HORSE_DAEMON`, `HORSE_LCL`, `HORSE_APACHE`, `HORSE_ISAPI`, `HORSE_CGI`, `HORSE_FCGI` as peers. That flat list conflates three conceptually independent axes:

| Axis | Means | Values |
|---|---|---|
| **A · Provider** | The HTTP transport library that owns the socket | Indy (Delphi default), `fphttpserver` (FPC default), CrossSocket, future mORMot |
| **B · Application type** | How the binary is packaged & started | Console (default), VCL, Daemon, LCL, HTTPApplication |
| **C · Host-managed** | The web server owns the socket; no Provider involved | Apache module, ISAPI, CGI, FastCGI |

A user wanting "CrossSocket transport in a VCL desktop app" or "CrossSocket inside a Windows Service" couldn't express it because `HORSE_CROSSSOCKET` and `HORSE_VCL` were mutually exclusive flags; the `{$MESSAGE FATAL}` said "architecturally impossible" when the truth was "not yet implemented".

PATCH-HORSE-2 splits the choices, ships the cross-product units (in the provider repo) that make every architecturally-compatible combination valid, and preserves 100% backwards compatibility via an alias block.

## What's in `Horse.pas`

The file now opens with three explicit blocks:

```pascal
{ ── BACKWARDS-COMPATIBILITY CONTRACT (PATCH-HORSE-2) ─────────────────── }
{ G1. Legacy define names continue to work...                              }
{ G2. Default-provider paths are unchanged                                 }
{ G3. THorseRequest / THorseResponse public API is untouched               }
{ G4. IHorseRawRequest / IHorseRawResponse adapters untouched              }
{ G5. Existing Horse.Provider.CrossSocket.pas is unchanged                 }
{ G6. PATCH-HORSE-1 only rejects architecturally-impossible combinations   }
{ G7. No concrete provider class renamed/removed                           }
{ G8. boss.json version bump (3.1.97 → 3.1.98) opt-in                      }

{ ── PATCH-HORSE-2 legacy aliases + namespaces ────────────────────────── }
{$IFDEF HORSE_CROSSSOCKET} {$DEFINE HORSE_PROVIDER_CROSSSOCKET} {$ENDIF}
{$IFDEF HORSE_VCL}         {$DEFINE HORSE_APPTYPE_VCL}          {$ENDIF}
{$IFDEF HORSE_DAEMON}      {$DEFINE HORSE_APPTYPE_DAEMON}       {$ENDIF}
...

{ ── PATCH-HORSE-1 narrowed FATAL guards ──────────────────────────────── }
{$IF DEFINED(HORSE_PROVIDER_CROSSSOCKET)}
  {$IFDEF HORSE_HOST_ISAPI}  {$MESSAGE FATAL '...'} {$ENDIF}
  {$IFDEF HORSE_HOST_APACHE} {$MESSAGE FATAL '...'} {$ENDIF}
  ...
{$ENDIF}
```

Followed by a two-stage selection chain:

- **Stage 1**: any `HORSE_HOST_*` define wins outright (the host owns the socket, no `THorseProvider` involved).
- **Stage 2**: compose `HORSE_PROVIDER_*` × `HORSE_APPTYPE_*` to choose the concrete provider unit (Console / VCL / Daemon / LCL / HTTPApplication, plus the cross-product CrossSocket variants from the consumer repo).

A parallel `THorseProvider` type-alias chain follows the same structure.

## What's in `Horse.Request.pas` and `Horse.Response.pas`

These are the long-standing CrossSocket-coexistence patches that have been refined since the original PR #443:

| Tag | Change | Effect on Indy |
|---|---|---|
| PATCH-REQ-5 | `RawPathInfo` accessor returns undecoded path | None — wraps existing `FWebRequest.RawPathInfo` |
| PATCH-REQ-8 | `SetCSRawWebRequest` + `FCSRawWebRequest` shadow field | None — only invoked when `HORSE_PROVIDER_CROSSSOCKET` is set |
| PATCH-REQ-9 | `MapBody` caches decoded body string in `FBodyString` | Indy still reads `FWebRequest.Content` on demand |
| PATCH-REQ-10 | `Method` accessor returns `string` (was sometimes `TMethodType`) | None — adds an overload |
| PATCH-RES-1/2/3/4 | `CustomHeaders` + shadow fields + `Clear` + read-only body accessors | All Indy setters preserved; new fields only written when `FWebResponse = nil` |

Existing accessor methods (`Body: string`, `Host`, `InitializeQuery`, `Send`, `Status`, `ContentType`, `SendFile`, `Download`, `RedirectTo`) gain nil-guard branches that route to shadow fields when `FWebRequest`/`FWebResponse` is nil. The Indy code path inside each method is byte-identical to upstream master.

## What's in `Horse.Provider.Abstract.pas`

- `ListenWithConfig` overload (used by CrossSocket; default implementation calls existing `Listen`).
- `Execute(Req, Res)` — extracted the middleware/route pipeline so it can be invoked from outside a provider class (used by CrossSocket's pool-acquired contexts).
- `MaxConnections: Integer` class property (PATCH-ABS-4) — raised from concrete providers to abstract base so `THorse.MaxConnections := N` compiles when `HORSE_PROVIDER_CROSSSOCKET` is set. On Indy providers, the concrete class's existing `FMaxConnections` shadows this — behaviour is unchanged.

## What's in `Horse.Core.RouterTree.pas`

`Execute` now calls `ARequest.RawPathInfo` and `ARequest.MethodType` instead of accessing `RawWebRequest` directly. On the Indy path this resolves to `FWebRequest.RawPathInfo` (undecoded) — identical to the pre-patch behaviour. On the CrossSocket path it resolves to the new shadow field, where reading `RawWebRequest` would crash because `FWebRequest = nil`.

## New units

- `Horse.Provider.RawInterfaces.pas` — defines `IHorseRawRequest` (~15 methods) + `IHorseRawResponse` (~1 method). The minimal surface a new provider must implement.
- `Horse.Provider.RawAdapters.pas` — generic `TInterfacedWebRequest` / `TInterfacedWebResponse` adapters that delegate every `TWebRequest` / `TWebResponse` abstract method to an `IHorseRaw*` implementation. New providers subclass these with thin constructors instead of stubbing 30+ abstract methods.
- `Horse.Provider.Config.pas` — pure data unit (`THorseCrossSocketConfig` record), no dependencies; allows `Horse.Provider.Abstract` to reference the config type without a circular dependency.

## Documentation

The `doc/` tree adds **24 markdown files** (12 EN + 12 PT-BR, line-count matched):

- `index` — TOC
- `getting-started` — install + first route + define selection
- `routing` — route definition API reference
- `request-response` — `THorseRequest` / `THorseResponse` reference
- `middleware` — middleware concepts and registration
- `writing-middleware` — authoring guide
- `middleware-ecosystem` — official middleware catalog
- `providers` — three-axis define model + per-shape recipes (the master reference)
- `deployment` — deployment cheatsheet by binary shape
- `compiler-support` — platform/compiler/provider compatibility matrix

Plus root-level `CONTRIBUTING.md` / `CONTRIBUTING.pt-BR.md` and `README.pt-BR.md`.

## Backwards compatibility

The 8 guarantees encoded as the **G1–G8 BACKWARDS-COMPATIBILITY CONTRACT** comment block at the top of `Horse.pas`:

1. **G1** — Legacy define names (`HORSE_CROSSSOCKET`, `HORSE_VCL`, `HORSE_DAEMON`, `HORSE_LCL`, `HORSE_APACHE`, `HORSE_ISAPI`, `HORSE_CGI`, `HORSE_FCGI`) continue to work.
2. **G2** — Default-provider paths are unchanged: no define → Console on Delphi, HTTPApplication on FPC; `HORSE_NOPROVIDER` → abstract base.
3. **G3** — `THorseRequest` / `THorseResponse` public API is untouched. Every existing method and property remains, with the same signature.
4. **G4** — `IHorseRawRequest` / `IHorseRawResponse` and the adapter classes are pure additions; nothing existing depends on them.
5. **G5** — `Horse.Provider.CrossSocket.pas` (Console-shape) is unchanged — old projects pick up no new behaviour unless they opt-in via `HORSE_APPTYPE_*`.
6. **G6** — PATCH-HORSE-1 only rejects architecturally-impossible combinations. PATCH-HORSE-2 *narrows* the set; nothing new is rejected.
7. **G7** — No existing concrete provider class is renamed or removed.
8. **G8** — `boss.json` version bump (3.1.97 → 3.1.98) is opt-in via `boss update`.

## Verification

Test suite: 32 black-box HTTP tests, currently 88/89 passing on `freitasjca/horse-provider-crosssocket` (the one known limitation is `Set-Cookie` ordering on the Delphi 10.4 / Win64 / Debug combination — documented in the provider repo). Test infrastructure lives at `samples/tests/` in the provider repo:

- 4 Delphi binary shapes (`Console`, `VCL`, `WinService`, `LinuxDaemon`) — `.dpr` projects + `.dproj` configs.
- 4 Lazarus binary shapes (`Console`, `LCL`, `Daemon`, `HTTPApplication`) — `.lpr` projects + `.lpi` configs.
- Shared 32-route handler in `samples/tests/Common/Horse.CrossSocket.TestRoutes.pas` (dual-compiler) so every shape exercises the same surface.
- A single `HorseCSTestClient.dpr` runs the 32 tests against any of the 8 servers.

The reference verification command for backwards compatibility:

```bat
REM On Delphi 10.4 / Win64:
REM 1. Build samples/tests/Delphi/Console/HorseCSTestServer.dpr  ← only HORSE_PROVIDER_CROSSSOCKET set
REM 2. Build samples/tests/Delphi/Console/HorseCSTestServer.dpr  ← only HORSE_CROSSSOCKET set (legacy alias)
REM 3. diff the two executables — byte-identical
```

## Files changed (this PR)

```
src/Horse.pas                              (PATCH-HORSE-1 + PATCH-HORSE-2)
src/Horse.Request.pas                      (PATCH-REQ-5/8/9/10)
src/Horse.Response.pas                     (PATCH-RES-1/2/3/4)
src/Horse.Provider.Abstract.pas            (PATCH-ABS-4 + ListenWithConfig + Execute)
src/Horse.Provider.Config.pas              (NEW — pure data unit)
src/Horse.Provider.RawInterfaces.pas       (NEW — IHorseRawRequest/Response)
src/Horse.Provider.RawAdapters.pas         (NEW — TInterfacedWebRequest/Response)
src/Horse.Core.RouterTree.pas              (uses RawPathInfo + MethodType)
src/Horse.Session.pas                      (PATCH-SES-1 — Clear procedure)
src/Horse.Provider.*.pas                   (updated to compile against the new Abstract base)

README.md                                  (CrossSocket section)
README.pt-BR.md                            (NEW)
CONTRIBUTING.md                            (NEW)
CONTRIBUTING.pt-BR.md                      (NEW)

doc/index.md / .pt-BR.md                   (NEW)
doc/getting-started.md / .pt-BR.md         (NEW)
doc/routing.md / .pt-BR.md                 (NEW)
doc/request-response.md / .pt-BR.md        (NEW)
doc/middleware.md / .pt-BR.md              (NEW)
doc/writing-middleware.md / .pt-BR.md      (NEW)
doc/middleware-ecosystem.md / .pt-BR.md    (NEW)
doc/providers.md / .pt-BR.md               (NEW)
doc/deployment.md / .pt-BR.md              (NEW)
doc/compiler-support.md / .pt-BR.md        (NEW)
doc/issue-indy-empty-body-html.md          (NEW — historical bug record)

boss.json                                  (version 3.1.97 → 3.1.98)
```

## Related work (out of scope for this PR)

The consumer of these changes — `freitasjca/horse-provider-crosssocket` v1.0.6 — ships the CrossSocket transport itself, the five cross-product Provider units, and the 8-shape integration test matrix. It depends on this PR landing (`>= 3.1.98`) but is shipped as a separate Boss package and is **not** proposed for inclusion in the upstream Horse repo.

## Out of scope for this PR

- The CrossSocket transport itself (lives in the consumer package).
- The five cross-product Provider units (`Horse.Provider.CrossSocket.VCL` etc. — same).
- The 8-shape test matrix (same).
- mORMot provider (reserved namespace only — no implementation in this PR).
- Sample projects per binary shape (the existing `samples/` tree is preserved unchanged).
