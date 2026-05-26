# Plan: Normalize the Horse Provider/Application-type Defines + Implement All Cross-Product Units

> **Status: ✅ IMPLEMENTED (PATCH-HORSE-2, 2026-05).** All three layers shipped:
> - **Layer 1** (define normalization) — legacy aliases + two-stage selection chain + narrowed `{$MESSAGE FATAL}` block + G1–G8 BACKWARDS-COMPATIBILITY CONTRACT in `patches/horse/src/Horse.pas`.
> - **Layer 2** (five cross-product Provider units) — `Horse.Provider.CrossSocket.VCL`, `.Daemon` *(cross-platform: `{$IFDEF MSWINDOWS}` switches between `THorseCrossSocketService` for Windows Service and `THorseCrossSocketLinuxDaemonApp.Run` for Delphi-on-Linux)*, `.FPC.Daemon`, `.FPC.LCL`, `.FPC.HTTPApplication`.
> - **Layer 3** (doc reconciliation) — `patches/horse/doc/providers.md` §6 + §8 and `deployment.md` updated with the three-namespace table and per-shape recipes; PT-BR mirrors in line-count parity.
>
> User-facing reference: see `patches/horse/doc/providers.md` §6 (define model) and §8 (per-shape recipes). The plan below is preserved as the design record.

## Context

The current `Horse.pas` resolves *one* `THorseProvider` via a single `{$IFDEF}` chain that accepts the defines `HORSE_CROSSSOCKET`, `HORSE_VCL`, `HORSE_DAEMON`, `HORSE_LCL`, `HORSE_APACHE`, `HORSE_ISAPI`, `HORSE_CGI`, `HORSE_FCGI`, and `HORSE_NOPROVIDER` as peers. PATCH-HORSE-1 blocks several combinations with `{$MESSAGE FATAL}` because the chain can't express orthogonal choices.

That single flat list conflates three conceptually independent architectural axes:

| Axis | Means | Values today |
|---|---|---|
| **A · Provider** | The HTTP transport library that owns the socket | Indy (default Delphi), `fphttpserver` (default FPC), CrossSocket, future mORMot |
| **B · Application type** | How the binary is packaged & started | Console (default), VCL, Daemon, LCL, HTTPApplication |
| **C · Host-managed runtime** | The web server owns the socket; no Provider involved | Apache module, ISAPI, CGI, FastCGI |

A user wanting "CrossSocket transport in a VCL desktop app" or "CrossSocket inside a Windows Service" can't express it via the defines today — `HORSE_CROSSSOCKET` and `HORSE_VCL` are mutually exclusive, and the `{$MESSAGE FATAL}` says "architecturally impossible" when the truth is "not yet implemented".

**Goal:** normalize the define names into three explicit namespaces, remove the artificial mutual exclusions between Axis A (Provider) and Axis B (Application type), and ship convenience cross-product units so every architecturally-compatible Provider × Application-type combination becomes expressible.

## Recommended approach — three layers

The implementation has three layers, each independently testable, applied in order.

### Layer 1 — Define-namespace normalization

#### Step 1.1: Establish the new namespaces

| Axis | Prefix | Defines |
|---|---|---|
| A · Provider | `HORSE_PROVIDER_*` | `HORSE_PROVIDER_CROSSSOCKET`, `HORSE_PROVIDER_MORMOT` *(reserved)* |
| B · Application type | `HORSE_APPTYPE_*` | `HORSE_APPTYPE_VCL`, `HORSE_APPTYPE_DAEMON`, `HORSE_APPTYPE_LCL` |
| C · Host-managed | `HORSE_HOST_*` | `HORSE_HOST_APACHE`, `HORSE_HOST_ISAPI`, `HORSE_HOST_CGI`, `HORSE_HOST_FCGI` |
| Special | unchanged | `HORSE_NOPROVIDER` *(escape hatch)* |

Defaults stay implicit: no define → Indy + Console on Delphi; FPC + no define → `fphttpserver` + HTTPApplication.

#### Step 1.2: Legacy-alias block at the top of `Horse.pas`

Place immediately after the unit declaration, before any other `{$IFDEF}`:

```pascal
{ Legacy define aliases (Horse <3.2) — kept for full backwards compatibility.
  The three architectural axes are now expressed as separate namespaces:
    A · Provider          HORSE_PROVIDER_*  (transport library)
    B · Application type  HORSE_APPTYPE_*   (binary lifecycle shape)
    C · Host-managed      HORSE_HOST_*      (web server owns the socket)
  See doc/providers.md for the full model. }

{$IFDEF HORSE_CROSSSOCKET} {$DEFINE HORSE_PROVIDER_CROSSSOCKET} {$ENDIF}
{$IFDEF HORSE_VCL}         {$DEFINE HORSE_APPTYPE_VCL}          {$ENDIF}
{$IFDEF HORSE_DAEMON}      {$DEFINE HORSE_APPTYPE_DAEMON}       {$ENDIF}
{$IFDEF HORSE_LCL}         {$DEFINE HORSE_APPTYPE_LCL}          {$ENDIF}
{$IFDEF HORSE_APACHE}      {$DEFINE HORSE_HOST_APACHE}          {$ENDIF}
{$IFDEF HORSE_ISAPI}       {$DEFINE HORSE_HOST_ISAPI}           {$ENDIF}
{$IFDEF HORSE_CGI}         {$DEFINE HORSE_HOST_CGI}             {$ENDIF}
{$IFDEF HORSE_FCGI}        {$DEFINE HORSE_HOST_FCGI}            {$ENDIF}
```

Every existing `.dproj` continues to compile unchanged.

#### Step 1.3: Rewrite the provider-selection chain

The `Horse.pas` chain currently has ~50 lines selecting `uses` + `THorseProvider` type alias based on the legacy flat defines. Rewrite it as a **two-stage** selection that honours the three-axis model:

```pascal
{ Stage 1: Host-managed runtime wins outright (Axis C).
  If any HORSE_HOST_* is set, the host *is* the transport — no Provider 
  is used, the chosen Provider define (Axis A) is ignored.            }
{$IF DEFINED(HORSE_HOST_ISAPI)}
  // ... Horse.Provider.ISAPI;
{$ELSEIF DEFINED(HORSE_HOST_APACHE)}
  // ... Horse.Provider.Apache / FPC.Apache
{$ELSEIF DEFINED(HORSE_HOST_CGI)}
  // ... Horse.Provider.CGI / FPC.CGI
{$ELSEIF DEFINED(HORSE_HOST_FCGI)}
  // ... Horse.Provider.FPC.FastCGI
{$ELSE}
  { Stage 2: Self-hosted — compose Axis A (Provider) × Axis B (App type). }
  {$IF DEFINED(HORSE_PROVIDER_CROSSSOCKET)}
    {$IF DEFINED(HORSE_APPTYPE_VCL)}
      Horse.Provider.CrossSocket.VCL,
    {$ELSEIF DEFINED(HORSE_APPTYPE_DAEMON)}
      {$IFDEF FPC} Horse.Provider.CrossSocket.FPC.Daemon
      {$ELSE}      Horse.Provider.CrossSocket.Daemon
      {$ENDIF},
    {$ELSEIF DEFINED(HORSE_APPTYPE_LCL)}
      Horse.Provider.CrossSocket.FPC.LCL,
    {$ELSE}
      Horse.Provider.CrossSocket,    // Console shape (the existing unit)
    {$ENDIF}
  {$ELSE}
    { Indy on Delphi / fphttpserver on FPC. }
    {$IF DEFINED(HORSE_APPTYPE_VCL)}
      Horse.Provider.VCL,
    {$ELSEIF DEFINED(HORSE_APPTYPE_DAEMON)}
      {$IFDEF FPC} Horse.Provider.FPC.Daemon
      {$ELSE}      Horse.Provider.Daemon
      {$ENDIF},
    {$ELSEIF DEFINED(HORSE_APPTYPE_LCL)}
      Horse.Provider.FPC.LCL,
    {$ELSEIF DEFINED(HORSE_NOPROVIDER)}
      Horse.Provider.Abstract,
    {$ELSE}
      {$IFDEF FPC} Horse.Provider.FPC.HTTPApplication
      {$ELSE}      Horse.Provider.Console
      {$ENDIF},
    {$ENDIF}
  {$ENDIF}
{$ENDIF}
```

The `THorseProvider` type-alias chain follows the same structure.

#### Step 1.4: Update PATCH-HORSE-1 messages

Replace the current "incompatible" block with a tighter one that distinguishes architectural impossibility from artificial limitation:

- **Architecturally impossible (always fatal):** `HORSE_PROVIDER_CROSSSOCKET` + any `HORSE_HOST_*`. Host owns the socket; self-hosted transport cannot coexist.
- **No longer fatal:** `HORSE_PROVIDER_CROSSSOCKET` + `HORSE_APPTYPE_VCL` / `_DAEMON` / `_LCL` — the cross-product units in Layer 3 make these combinations valid.

`HORSE_NOPROVIDER` stays unchanged — same escape hatch.

#### Files for Layer 1

| File | Change |
|---|---|
| `patches/horse/src/Horse.pas` | Legacy alias block + rewritten chain + updated PATCH-HORSE-1; tagged `PATCH-HORSE-2`. |
| `patches/horse/doc/providers.md` | § 6 *Selecting your defines* updated with the three-namespace table and legacy alias mapping. |
| `patches/horse/doc/providers.pt-BR.md` | Same in Portuguese. |
| `patches/horse/doc/deployment.md` | Define references updated in the cheatsheet tables. |
| `patches/horse/doc/deployment.pt-BR.md` | Same in Portuguese. |

### Layer 2 — Five new cross-product Provider units

All new units live in `horse-provider-crosssocket/src/` (alongside the existing `Horse.Provider.CrossSocket.pas`). Each is a thin wrapper that:

1. Inherits from `THorseProviderAbstract`.
2. Holds (or instantiates on demand) the existing `THorseCrossSocketServer` for the transport.
3. Adds the shape-specific lifecycle integration that today the user has to write by hand (per `doc/providers.md §8`).

The shared CrossSocket transport code is *not* duplicated — these units delegate to the existing `Horse.Provider.CrossSocket.pas` infrastructure (request bridge, response bridge, worker pool, context pool, all of it). They only add the *shape* layer.

#### 2.1 `Horse.Provider.CrossSocket.VCL.pas` — Delphi

Class: `THorseProviderCrossSocketVCL = class(THorseProviderAbstract)`

Adds:
- A convenience `TfrmHorseVCLHost` form base class with `Port` and `OnHorseListen` properties, that auto-calls `Listen` on `FormCreate` and `StopListen` on `FormClose`. Users inherit from it instead of copy-pasting the recipe in `doc/providers.md §8.2`.
- Same `Listen` / `StopListen` semantics as the existing CrossSocket provider but explicitly documented as non-blocking (IsConsole=False at runtime).

#### 2.2 `Horse.Provider.CrossSocket.Daemon.pas` — Delphi Windows Service

Class: `THorseProviderCrossSocketDaemon = class(THorseProviderAbstract)`

Adds:
- A convenience `THorseCrossSocketService` class descended from `Vcl.SvcMgr.TService`, with `ServiceStart` / `ServiceStop` pre-wired to spawn a worker thread for `Listen` and clean-drain on stop. This is the §8.4 recipe codified.
- The SCM-handling code is otherwise the user's project.

#### 2.3 `Horse.Provider.CrossSocket.FPC.Daemon.pas` — FPC Linux daemon

Class: `THorseProviderCrossSocketFPCDaemon = class(THorseProviderAbstract)`

Adds:
- A `THorseCrossSocketDaemonApp` helper that wires `BaseUnix.fpSignal(SIGTERM)` and `fpSignal(SIGINT)` to `StopListen` at startup. Users call `THorseCrossSocketDaemonApp.Run(@Setup);` and the helper handles signal binding + the blocking `Listen` call.
- This is the §8.5 recipe codified.

#### 2.4 `Horse.Provider.CrossSocket.FPC.LCL.pas` — Lazarus GUI

Class: `THorseProviderCrossSocketFPCLCL = class(THorseProviderAbstract)`

Adds:
- A convenience `TfrmHorseLCLHost` form base class (mirror of the Delphi VCL one) for Lazarus projects.
- Pre-wires the §8.6 pattern.

#### 2.5 `Horse.Provider.CrossSocket.FPC.HTTPApplication.pas` — FPC standalone HTTP app

Class: `THorseProviderCrossSocketFPCHTTPApplication = class(THorseProviderAbstract)`

Adds:
- The same signal-handler wrapper as the FPC Daemon unit (since HTTPApplication shape is functionally identical to Daemon when CrossSocket owns the loop — per `doc/providers.md §8.7`).
- A `THorseCrossSocketHTTPApp` helper exposing the same minimal-binary recipe.

#### Files for Layer 2

| File | Purpose |
|---|---|
| `patches/horse-provider-crosssocket/src/Horse.Provider.CrossSocket.VCL.pas` | NEW — Delphi VCL composition. |
| `patches/horse-provider-crosssocket/src/Horse.Provider.CrossSocket.Daemon.pas` | NEW — Delphi Windows Service composition. |
| `patches/horse-provider-crosssocket/src/Horse.Provider.CrossSocket.FPC.Daemon.pas` | NEW — FPC Linux daemon composition. |
| `patches/horse-provider-crosssocket/src/Horse.Provider.CrossSocket.FPC.LCL.pas` | NEW — Lazarus LCL composition. |
| `patches/horse-provider-crosssocket/src/Horse.Provider.CrossSocket.FPC.HTTPApplication.pas` | NEW — FPC HTTPApplication composition. |

Each unit is estimated at 80–150 lines. Estimated total: ~500–700 lines.

The CrossSocket package's `boss.json` version is bumped to `1.0.5` and requires `horse >= 3.1.98` (the version that ships PATCH-HORSE-2).

### Layer 3 — Documentation reconciliation

`doc/providers.md §8` (and `.pt-BR.md`) currently documents the seven shapes as recipes the user assembles manually. Each subsection's "Define" line is updated:

- §8.1 Console: define `HORSE_PROVIDER_CROSSSOCKET` (was `HORSE_CROSSSOCKET`).
- §8.2 VCL: define `HORSE_PROVIDER_CROSSSOCKET` **+** `HORSE_APPTYPE_VCL`. Use `TfrmHorseVCLHost` base class. The hand-written recipe stays as the longhand alternative.
- §8.3 Linux daemon (Delphi): same as §8.5 since Delphi-on-Linux uses `Horse.Provider.CrossSocket.FPC.Daemon` semantics via cross-compile — clarify which unit applies.
- §8.4 Windows Service: define `HORSE_PROVIDER_CROSSSOCKET` + `HORSE_APPTYPE_DAEMON`. Inherit from `THorseCrossSocketService`.
- §8.5 Linux daemon (FPC): define `HORSE_PROVIDER_CROSSSOCKET` + `HORSE_APPTYPE_DAEMON`. Use `THorseCrossSocketDaemonApp.Run`.
- §8.6 LCL: define `HORSE_PROVIDER_CROSSSOCKET` + `HORSE_APPTYPE_LCL`. Use `TfrmHorseLCLHost`.
- §8.7 FPC HTTPApplication: define `HORSE_PROVIDER_CROSSSOCKET` (no `HORSE_APPTYPE_*` — HTTPApplication is the FPC default).

The compatibility matrix in §5 changes its `⚠` cells (CrossSocket × VCL/Daemon/LCL/HTTPApplication) to `✔` — they're now first-class supported combinations.

The deployment cheatsheet (`doc/deployment.md` + `.pt-BR.md`) gets the same define updates and a note that the hand-written recipes still work (for projects that prefer not to use the convenience base classes).

### Layer 4 — `PATCH-HORSE-2` tag and CHANGELOG

The combined change ships as **PATCH-HORSE-2** in the `freitasjca/horse` fork's next release. Bump:

- `freitasjca/horse` → `v3.1.98` (the patch ships PATCH-HORSE-2; boss.json version updated).
- `freitasjca/horse-provider-crosssocket` → `v1.0.5` (ships the five new cross-product units, requires horse >= 3.1.98).
- `patches/horse-provider-crosssocket/doc/pr-crosssocket-provider-description-v1.md` gets a new section describing PATCH-HORSE-2.

## Backwards compatibility

- Every existing `.dproj` / `.lpi` that sets `HORSE_CROSSSOCKET`, `HORSE_VCL`, `HORSE_DAEMON`, `HORSE_LCL`, `HORSE_APACHE`, `HORSE_ISAPI`, `HORSE_CGI`, `HORSE_FCGI` continues to compile unchanged — the alias block in Step 1.2 translates them.
- Existing user code calling `THorse.Listen` / `StopListen` / etc. is unchanged.
- The `Horse.Provider.CrossSocket.pas` unit (Console shape) is untouched; it remains the unit selected when only `HORSE_PROVIDER_CROSSSOCKET` is set without an `HORSE_APPTYPE_*`.
- No `THorseProviderAbstract` interface changes; all five new units fit the existing class hierarchy.

The only "breaking" change is that PATCH-HORSE-1's mutual-exclusion messages now allow combinations that were previously fatal. Any code that *relied* on those being fatal (which would be very unusual) would behave differently. None known.

## What is explicitly NOT in scope

- **No new sample projects.** The `horse-provider-crosssocket/samples/` tree gets only the existing Console example plus an integration test suite. Sample projects for each shape (VCL form, Service, LCL form, etc.) are a follow-up PR.
- **No transport/shape factoring at the class level.** The cross-product units are monolithic wrappers, not a clean separation of `TTransportBase` × `TShapeBase`. That refactor remains a Horse 4.0 candidate.
- **No automated tests for every shape.** Verification is manual (see §Verification below). Adding scripted tests for every shape is a follow-up.
- **No deprecation warnings on legacy defines.** Old defines work without complaint. A future minor version can add `{$MESSAGE HINT}` once the new names are well-known.

## Files to modify — complete list

### `freitasjca/horse` (canonical patched copy in `patches/horse/`)

| File | Change |
|---|---|
| `patches/horse/src/Horse.pas` | Legacy aliases + rewritten chain + updated PATCH-HORSE-1 + new PATCH-HORSE-2 tag. ~80 lines net change. |
| `patches/horse/doc/providers.md` | § 6 (defines table) + § 5 (compatibility matrix) updated. |
| `patches/horse/doc/providers.pt-BR.md` | Same in Portuguese. |
| `patches/horse/doc/deployment.md` | Define references updated in tables and per-shape sections. |
| `patches/horse/doc/deployment.pt-BR.md` | Same in Portuguese. |
| `patches/horse/boss.json` | Version bump to `3.1.98`. |

### `freitasjca/horse-provider-crosssocket` (canonical patched copy in `patches/horse-provider-crosssocket/`)

| File | Change |
|---|---|
| `patches/horse-provider-crosssocket/src/Horse.Provider.CrossSocket.VCL.pas` | NEW |
| `patches/horse-provider-crosssocket/src/Horse.Provider.CrossSocket.Daemon.pas` | NEW |
| `patches/horse-provider-crosssocket/src/Horse.Provider.CrossSocket.FPC.Daemon.pas` | NEW |
| `patches/horse-provider-crosssocket/src/Horse.Provider.CrossSocket.FPC.LCL.pas` | NEW |
| `patches/horse-provider-crosssocket/src/Horse.Provider.CrossSocket.FPC.HTTPApplication.pas` | NEW |
| `patches/horse-provider-crosssocket/boss.json` | Version bump to `1.0.5`; require `horse >= 3.1.98`. |
| `patches/horse-provider-crosssocket/doc/pr-crosssocket-provider-description-v1.md` | New §"PATCH-HORSE-2 and the cross-product units" describing the change for upstream review. |
| `patches/horse-provider-crosssocket/doc/middleware-compatibility.md` *(if affected)* | No change expected — middleware uses `THorseRequest` / `THorseResponse`, not the Provider class directly. |

### Reuse from the existing codebase

- `THorseProviderAbstract` (`patches/horse/src/Horse.Provider.Abstract.pas`) — the base class every cross-product unit inherits from. Its `Listen` / `StopListen` / `ListenWithConfig` / `Execute` virtuals are exactly what the new units need to override.
- `THorseCrossSocketServer` and `THorseWorkerPool` (in `horse-provider-crosssocket/src/Horse.Provider.CrossSocket.Server.pas`, `…WorkerPool.pas`) — the existing transport infrastructure. The new units instantiate or compose these rather than reimplementing.
- `TRequestBridge` / `TResponseBridge` (`horse-provider-crosssocket/src/Horse.Provider.CrossSocket.Request.pas` / `…Response.pas`) — unchanged; the new units route requests through the same bridges.
- `THorseContextPool` (`horse-provider-crosssocket/src/Horse.Provider.CrossSocket.Pool.pas`) — unchanged; same pool serves every cross-product unit.

The `THorseProviderCrossSocket` class in the existing `Horse.Provider.CrossSocket.pas` is the canonical reference for what each new unit's `Listen` / `StopListen` / `Stop` implementation looks like. The new units differ only in their lifecycle wrapper (TForm, TService, signal handler) — the CrossSocket transport calls are essentially the same.

## Verification

End-to-end testing exercises both the alias layer and each cross-product unit. None of these require new test infrastructure — they extend the existing 32-test suite or run as standalone sample compilations.

1. **Backwards-compat: legacy define still works**
   - Build `patches/horse-provider-crosssocket/samples/tests/HorseCSTestServer.dproj` with the old `HORSE_CROSSSOCKET` set in its `.dproj`. Should compile and pass 88/89 (the documented cookie limitation remains).
2. **Backwards-compat: same project with new define**
   - Change the `.dproj` to set `HORSE_PROVIDER_CROSSSOCKET` instead. Should compile and produce a byte-identical binary; same 88/89 test result.
3. **Architecturally-impossible combination still fails**
   - Build a throwaway project with both `HORSE_PROVIDER_CROSSSOCKET` and `HORSE_HOST_APACHE`. Should fail compilation with the PATCH-HORSE-1 "Apache/IIS/CGI/FCGI own the socket" `{$MESSAGE FATAL}` text.
4. **Previously-fatal combination now compiles: CrossSocket × VCL**
   - Build a VCL Forms project that sets `HORSE_PROVIDER_CROSSSOCKET` + `HORSE_APPTYPE_VCL` and inherits from `TfrmHorseVCLHost`. Should compile. At runtime, the form should accept HTTP requests on the configured port.
5. **CrossSocket × Windows Service**
   - Build a Service Application that sets `HORSE_PROVIDER_CROSSSOCKET` + `HORSE_APPTYPE_DAEMON` and inherits from `THorseCrossSocketService`. `sc start`, send a request, `sc stop` — verify clean drain.
6. **CrossSocket × FPC Daemon**
   - Build an FPC console project that sets the same two defines, using `THorseCrossSocketDaemonApp.Run`. Run, send a request, send `SIGTERM` — verify the process exits with code 0 within a few seconds.
7. **Legacy samples still work**
   - Build the unmodified `horse/samples/delphi/Console/Console.dproj`, `VCL/VCL.dproj`, `Daemon/Daemon.dproj`, `Apache/Apache.dproj`. All should compile and run as today. Confirms full backwards compat.

For the docs: open `doc/providers.md` in a Markdown previewer, verify § 5 compatibility matrix now shows `✔` (not `⚠`) in the CrossSocket × VCL/Daemon/LCL/HTTPApplication cells, and § 6 shows the three-namespace table.

## Rollout

Single release cycle covers both repositories:

1. Apply Layer 1 changes to `freitasjca/horse`. Build the local test suite. Tag `v3.1.98`.
2. Apply Layer 2 changes to `freitasjca/horse-provider-crosssocket`. Build and run the cross-product integration tests on at least one combination per shape (manually, in the IDE). Tag `v1.0.5`.
3. Apply Layer 3 doc changes in both repos in the same PR.
4. Open an upstream PR against `HashLoad/horse` carrying the Layer 1 + Layer 3 changes. The cross-product units (Layer 2) stay in the provider repo since they're CrossSocket-specific.
5. After the upstream PR lands, no further version bumps; existing CrossSocket consumers pick up the new units via Boss.
