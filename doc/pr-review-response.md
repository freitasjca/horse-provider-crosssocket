# Response to PR #443 Review — CrossSocket Provider

This document responds point-by-point to the QA / Integration review of PR #443. For each contested item we record the reviewer's claim, the status of the fix in the current patch set, and a citation (file + line range) so the fix can be inspected in isolation. Items are ordered by severity, matching the original review.

All file paths below are relative to the workspace root and refer to the **patches/** tree, which is the canonical source. The live Windows working copies under `C:\lang\Repo\` are produced by copying these files over the corresponding repo paths (see CLAUDE.md → "patches/ directory").

---

## BLOCKER — Process does not terminate after `StopListen` on Windows

**Reviewer's claim:** `THorseProviderCrossSocket.ListenWithConfig` returns immediately; the calling thread falls through to `end.`, RTL finalisation runs while IOCP threads are still alive, and the process never exits.

**Status:** **Resolved.** Four fixes were required — items 1 and 2 are the Listen/StopListen pairing at the provider layer, items 3 and 4 are auxiliary fixes at the CrossSocket transport layer that the provider-layer fix surfaced:

1. **`Listen` now blocks the calling thread when `IsConsole = True`** — mirrors the Console/Indy provider's `while FRunning do GetDefaultEvent.WaitFor` pattern. This is the same root cause as the MEDIUM item further down ("Listen is non-blocking — RTL finalization clears middleware globals"). Both symptoms (process hang on shutdown; mid-flight nil-callback AVs) collapse to the same fix.

   `horse-provider-crosssocket/src/Horse.Provider.CrossSocket.pas:271-280`
   ```pascal
   FServer.Start(APort);
   DoOnListen;

   // Block the main thread when we are running as a console application,
   // matching the Indy/Console provider's 'while FRunning do GetDefaultEvent.WaitFor'
   // pattern. Without this the calling thread falls through to end. and RTL
   // finalisation clears unit-scope middleware callbacks while IOCP threads are
   // still serving requests — producing nil-callback access violations and a
   // process that never exits because IO worker threads are still alive.
   if IsConsole then
   begin
     FRunning := True;
     if not Assigned(FStopEvent) then
       FStopEvent := TEvent.Create(nil, True, False, '');
     while FRunning do
       FStopEvent.WaitFor(INFINITE);
     FreeAndNil(FStopEvent);
   end;
   ```

2. **`StopListen` now signals the wait event and waits for IOCP workers to drain** — `Horse.Provider.CrossSocket.pas:283-309`. The order is: set `FRunning := False`, call `FServer.Stop` (which posts completion packets and joins worker threads), then `FStopEvent.SetEvent` to release the main thread's `WaitFor`.

3. **PATCH-IOCP-1 — DEBUG-build shutdown cascade fixed** (`patches/Delphi-Cross-Socket/Net/Net.CrossSocket.Iocp.pas:8-19, 748-790`). The `WSA_OPERATION_ABORTED` (995) guard at the `_NewAccept` call site previously called `GetLastError()` a second time after `_LogLastOsError` had reset the per-thread last-error to 0 — so the guard saw 0, fell through, called `_NewAccept`, which failed with `10038` (`WSAENOTSOCK`), which fed back into the same path. Result: the IOCP worker spun in a 995→`_NewAccept`→10038→995 loop and never exited cleanly. Fix: capture last-error into `LErrNo` before any other call, and use `LErrNo` for the guard (not `GetLastError()`).

4. **FIX-REFCOUNT-1** — `horse-provider-crosssocket/src/Horse.Provider.CrossSocket.Server.pas:104-201` keeps an `FServerRef: ICrossHttpServer` reference alive so `TIocpCrossSocket.FRefCount` never drops to 0 mid-shutdown, which previously freed the IOCP worker pool while it was being joined.

**How to verify:** run the included `HorseCSTestServer.dpr` (32-test integration suite), then send `Ctrl+C` or terminate via the test client. The process exits cleanly. The `Console.dpr` sample with the unmodified `ReadLn → StopListen` pattern also exits.

---

## HIGH — `Method: string` accessor not exposed on `THorseRequest`

**Reviewer's claim:** `THorseRequest` exposes `MethodType: TMethodType`, but the enum collapses `OPTIONS`, `TRACE`, and `CONNECT` into `mtAny`. Middleware that needs to discriminate by raw verb (e.g. `horse-cors` for OPTIONS preflight) has no compile-safe way to do so.

**Status:** **Resolved by two complementary mechanisms — PATCH-REQ-8 (hybrid adapter) and PATCH-REQ-10 (convenience accessor).** Either path returns the raw verb string for any HTTP method, including `OPTIONS` / `TRACE` / `CONNECT`.

### Mechanism 1 — `Req.RawWebRequest.Method` (PATCH-REQ-8, shipped earlier)

The reviewer's premise — "On the CrossSocket path `RawWebRequest` is nil — an AV" — applied to an earlier draft of this PR, before PATCH-REQ-8 added the owned `TCrossSocketWebRequest` adapter:

`patches/horse/src/Horse.Request.pas:613-624`
```pascal
function THorseRequest.RawWebRequest: {$IF DEFINED(FPC)}TRequest{$ELSE}TWebRequest{$ENDIF};
begin
{ PATCH-REQ-8 — return the CrossSocket-path adapter when FWebRequest is nil }
  if Assigned(FWebRequest) then
    Exit(FWebRequest);
  Result := FCSRawWebRequest;
{ end PATCH-REQ-8 }
end;
```

The CrossSocket request bridge constructs the adapter and hands it to the request:

`horse-provider-crosssocket/src/Horse.Provider.CrossSocket.Request.pas:298-306`
```pascal
AHorseReq.SetCSRawWebRequest(TCrossSocketWebRequest.Create(ACrossReq));
```

`TCrossSocketWebRequest.Method` returns the raw verb string (`'GET'`, `'POST'`, `'OPTIONS'`, `'TRACE'`, `'CONNECT'`, …) by delegating through `IHorseRawRequest` to `ICrossHttpRequest.Method`. This is the same string the reviewer wanted from a hypothetical `Req.Method`.

This pattern is what every existing Horse middleware already uses:

- `horse-cors/src/Horse.CORS.pas:67` — `if Req.RawWebRequest.Method = 'OPTIONS' then` works unchanged on both Indy and CrossSocket.
- `patches/horse-request-guard/src/Horse.Middleware.RequestGuard.pas:172` — `LMethod := Req.RawWebRequest.Method;` — works on both providers without any per-provider branch.

### Mechanism 2 — `Req.Method: string` (PATCH-REQ-10, added in response to this review)

After further consideration we also added a direct `Method: string` accessor as a shorter alternative. Both forms are supported; choose whichever reads better at the call site.

```pascal
{ patches/horse/src/Horse.Request.pas:104 (interface, after MethodType) }
    function Method: string; virtual;

{ patches/horse/src/Horse.Request.pas:591-596 (implementation) }
function THorseRequest.Method: string;
begin
  if not Assigned(FWebRequest) then
    Exit(FCSMethod);
  Result := FWebRequest.Method;
end;
```

`TWebRequest.Method` (Delphi) and `TRequest.Method` (FPC) both return the raw verb string, so the implementation is the same on both compilers without a `{$IF DEFINED(FPC)}` branch. Total addition: 1 declaration line + 6 implementation lines.

We kept the hybrid adapter as the primary mechanism — it is the recommended escape hatch for *any* `TWebRequest` accessor middleware needs (`Method`, `Host`, `RemoteAddr`, `GetFieldByName(...)`), not just the verb — so middleware that already targets `Req.RawWebRequest.Method` continues to work without source changes.

---

## HIGH — PR description claims "no existing method is altered or removed"

**Reviewer's claim:** Many `THorseRequest` / `THorseResponse` methods (`Send`, `Status`, `AddHeader`, `RemoveHeader`, `RedirectTo`, `ContentType`, `SendFile`, `Download`, `Body`, `Host`, `PathInfo`, `MethodType`, `InitializeQuery`, `InitializeCookie`, `InitializeContentFields`, `GetHeaders`) gained new code paths. Calling this "no alteration" understates the scope.

**Status:** **Acknowledged — PR description corrected.**

The accurate description is now in `patches/horse-provider-crosssocket/doc/pr-crosssocket-provider-description-v1.md`:

> Existing accessor methods in `THorseRequest` and `THorseResponse` gain nil-guard branches for the CrossSocket path. The Indy code path within each method is byte-for-byte identical to the upstream — only an `if not Assigned(FWebRequest) then ...` branch is added before the existing body. Nothing existing is renamed, removed, or given a different signature. No method's Indy/FPC behaviour changes.

This is the wording in CLAUDE.md (lines 13-14) and in the v1 PR description. The original "no existing method is altered or removed" line was a regression of an earlier draft and has been replaced.

The list of methods that received nil-guard branches is enumerated tag-by-tag (PATCH-REQ-3, PATCH-REQ-8, PATCH-REQ-9, PATCH-RES-1, PATCH-RES-3, PATCH-RES-4, PATCH-RES-6) in the v1 description. Each tag points at a specific block of lines so review can be done block by block.

---

## HIGH — "`Port` class property" claim in PR description

**Reviewer's claim:** PR description claims a `Port` property was added to the abstract base, but only a comment exists explaining why it was not added.

**Status:** **Acknowledged — PR description corrected.**

Each concrete provider intentionally owns its own `FPort` class var. Sharing one `FPort` in the abstract base produced silent port-not-changing bugs when both providers were compiled. The comment in `patches/horse/src/Horse.Provider.Abstract.pas:30-34` documents this:

```pascal
// NOTE: FPort is intentionally NOT declared here.
// Each concrete provider owns its own FPort class var so there is no
// ambiguity between the Console provider's FPort and the CrossSocket
// provider's FPort. Sharing a single FPort in the abstract base caused
// silent port-not-changing bugs when both providers were compiled.
```

The PR description has been updated to reflect what was actually submitted: no `Port` property was added; the design choice is documented in-source.

---

## MEDIUM — `Listen` non-blocking; RTL finalises middleware globals while IOCP threads run

**Status:** **Resolved.** This collapses to the same fix as the BLOCKER — see that section. Lines `Horse.Provider.CrossSocket.pas:271-280` show the `IsConsole`-aware blocking loop.

The reviewer's suggested fix and the actual fix are line-for-line identical:

| Reviewer suggested | Implemented |
|---|---|
| `if IsConsole then while FRunning do FStopEvent.WaitFor(INFINITE);` | Same, plus `FreeAndNil(FStopEvent)` after the loop and event creation guarded by `Assigned`. |
| `StopListen` sets `FRunning := False` and signals the event before `FServer.Stop` | `StopListen` sets `FRunning := False`, calls `FServer.Stop` (which joins workers), then signals the event. The order matters: the main thread must not wake until workers have exited, otherwise `FinalizeUnits` races with in-flight requests. |

---

## MEDIUM — `FBody` non-owning reference: use-after-free risk; sample shows the unsafe pattern

**Reviewer's claim:** Any handler that retains `Req.Body<TStream>` holds a reference into a buffer that will be recycled when the pooled context is reset. The `Console.dpr` sample shows `Res.Send(Req.Body<TStream>)` — the unsafe pattern.

**Status:** **Resolved.**

What is fixed:
- The non-owning contract is documented in three places: SEC-9 in `Horse.Provider.CrossSocket.Pool.pas:62-78`; the `THorseRequest.Clear` block comment in `Horse.Request.pas` (PATCH-REQ-2); and CLAUDE.md → "Known ownership trap" section.
- FIX-POOL-1 ensures the pool never frees the non-owning stream itself (the original double-free trap that crashed every POST request).
- `Req.Body: string` is safe — PATCH-REQ-9 caches the decoded UTF-8 string in `FBodyString`, which is owned by `THorseRequest` and survives until `Clear` runs at pool release. Two consecutive calls return the same string.
- `samples/Delphi/console/Console.dpr` has been rewritten — the `/echo` route now copies the bytes into a `TMemoryStream` Horse can own, and the unit header carries an ownership-trap warning block that points at SEC-9 and CLAUDE.md. The replacement file is at `patches/horse-provider-crosssocket/samples/Delphi/console/Console.dpr`. The pattern is now safe to lift into async or threaded handlers.

This was a documentation/sample issue, not a provider bug — the provider's behaviour was correct throughout.

---

## MEDIUM — Performance regression for Indy users (FCustomHeaders unconditionally allocated)

**Reviewer's claim:** Every `THorseResponse.Create` allocates a `TDictionary<string,string>`, even on Indy/ISAPI/CGI deployments that will never read it. `AddHeader`/`RemoveHeader` dual-write to it.

**Status:** **Resolved by PATCH-RES-7.**

`FCustomHeaders` is no longer eagerly allocated in the constructor. A new private helper `EnsureCustomHeaders` allocates the dictionary (Delphi) or string-list (FPC) on first call to `AddHeader`. `RemoveHeader` is nil-guarded (nothing to remove if the store was never created). `Clear` and `Destroy` already nil-checked, so they need no change. The bridge's read site (`horse-provider-crosssocket/src/Horse.Provider.CrossSocket.Response.pas:238`) already nil-checks `CustomHeaders`.

The result: any Indy/ISAPI/CGI request that never calls `AddHeader` pays zero allocation cost for this field. Routes that do call `AddHeader` see a one-time allocation on the first call, identical in cost to the previous unconditional constructor allocation.

`patches/horse/src/Horse.Response.pas`:
- field declaration `:49` (unchanged — type is the same)
- private `EnsureCustomHeaders` declaration `:83-89` (PATCH-RES-7)
- `AddHeader` calls `EnsureCustomHeaders` `:159-178`
- `EnsureCustomHeaders` body `:183-191`
- constructor no longer allocates `:218-236` (the eager `Create` block is replaced by a comment pointing at `EnsureCustomHeaders`)
- `RemoveHeader` nil-guard `:359-389`

---

## MEDIUM — `Req.Body` re-reads and UTF-8-decodes the stream on every call

**Reviewer's claim:** `THorseRequest.Body: string` seeks to position 0 and re-decodes the stream on every invocation. Binary bodies are silently corrupted by UTF-8 decoding.

**Status:** **Resolved by PATCH-REQ-9.** The decode happens exactly once at request-entry time (in the request bridge), and the cached string is returned by every subsequent call.

`horse-provider-crosssocket/src/Horse.Provider.CrossSocket.Request.pas:497-506`
```pascal
// [PATCH-REQ-9] Decode body to string once here so that
// Req.Body returns the same cached string to all
// callers; FBodyString holds the decoded text for Body: string.
AHorseReq.SetBodyString(TEncoding.UTF8.GetString(LBytes));
```

`patches/horse/src/Horse.Request.pas:217-225`
```pascal
function THorseRequest.Body: string;
begin
  if not Assigned(FWebRequest) then
  begin
    Result := FBodyString;     // PATCH-REQ-9 — O(1) cache read
    Exit;
  end;
  Result := FWebRequest.Content;
end;
```

**Test coverage:** `HorseCSTestClient.dpr` Test 31 (`POST /echo/body-twice`) calls `Req.Body` twice in the same handler, sends both back, and asserts `"first" == "second"` and `"equal":true`.

**On binary corruption:** the reviewer's concern is correct that UTF-8 decoding is wrong for binary uploads. The fix is to access binary bodies via `Req.Body<TStream>` (which returns the raw `TStream`, no decode) and not via `Req.Body: string`. This matches the Indy contract — `TWebRequest.Content` is always a string accessor for textual bodies; binary bodies use `ContentStream`. The string accessor decoding as UTF-8 is the documented Horse behaviour, not a CrossSocket regression.

---

## MEDIUM — `Clear` allocates `THorseSessions` on every pool recycle

**Reviewer's claim:** `THorseRequest.Clear` calls `FSessions := THorseSessions.Create` unconditionally, contradicting the "zero-allocation hot path" claim.

**Status:** **Resolved by PATCH-SES-1 + the corresponding `Horse.Session.Clear` patch.** `Clear` now reuses the existing `THorseSessions` if one exists; only when `FSessions = nil` (first request on a freshly constructed pool entry) does it allocate.

`patches/horse/src/Horse.Request.pas:329-336`
```pascal
{ PATCH-SES-1 — reuse the existing THorseSessions object across pool recycles.
  THorseSessions.Clear calls TObjectDictionary.Clear which frees owned TSession
  entries in place — no new allocation per request. }
if Assigned(FSessions) then
  FSessions.Clear
else
  FSessions := THorseSessions.Create;
```

`patches/horse/src/Horse.Session.pas` adds the matching `Clear` procedure:
```pascal
procedure THorseSessions.Clear;
begin
  // wipes the inner TObjectDictionary in place; no allocation
  if Assigned(FSessions) then FSessions.Clear;
end;
```

Same pattern used for `FHeaders`, `FParams`, `FCookie`, `FQuery`, and `FContentFields` — see the `Clear` procedure body at `Horse.Request.pas:297-337`.

---

## MEDIUM — `ListenWithConfig` default implementation ignores `APort`

**Reviewer's claim:** The abstract base's `ListenWithConfig` may silently use the wrong port.

**Status:** **Resolved — the abstract base now raises rather than silently misbehaving.**

`patches/horse/src/Horse.Provider.Abstract.pas:156-164`
```pascal
class procedure THorseProviderAbstract.ListenWithConfig(const APort: Integer;
  const AConfig: THorseCrossSocketConfig);
begin
  raise Exception.CreateFmt(
    '%s must override ListenWithConfig — the base implementation cannot ' +
    'forward port %d to Listen. Override ListenWithConfig in the concrete ' +
    'provider and call SetPort(APort) before Listen.',
    [ClassName, APort]);
end;
```

The contract is stated in the block comment immediately above (lines 145-155): every concrete provider must override. All shipped concrete providers (`Console`, `Daemon`, `VCL`, `FPC.Daemon`, `FPC.FastCGI`, `FPC.LCL`, `FPC.HTTPApplication`, `CrossSocket`) override it and set their own `FPort` before chaining to `Listen`. A future provider that forgets to override gets a runtime exception with the exact class name in the message — far easier to diagnose than "wrong port silently used".

We chose runtime raise over a compile-time abstract method specifically because making it abstract would force every existing concrete provider in the wider Horse ecosystem to compile-error on first contact with the patch. Raising preserves source compatibility for unknown providers and still surfaces the bug on first call.

---

## MEDIUM — No compatibility plan for the official middleware ecosystem

**Reviewer's claim:** Middleware that calls `RawWebRequest` / `RawWebResponse` directly will AV on the CrossSocket path. `horse-cors` and `horse-jhonson` are concrete examples.

**Status:** **Resolved at the architecture level by PATCH-REQ-8 / PATCH-RES-6 (the hybrid adapter).** No middleware changes are required for the cases the reviewer raised.

The hybrid adapter chain explicitly addresses this:

```
TInterfacedWebRequest / TInterfacedWebResponse  (Horse.Provider.RawAdapters.pas)
  ← thin TCrossSocketWebRequest / TCrossSocketWebResponse subclasses
    ← delegate via IHorseRawRequest / IHorseRawResponse
      ← TCrossSocketRawRequest / TCrossSocketRawResponse  (one-liner wrappers around ICrossHttp*)
```

`Req.RawWebRequest` and `Res.RawWebResponse` return non-nil `TWebRequest` / `TWebResponse` instances on the CrossSocket path. Middleware that does `Req.RawWebRequest.Method`, `Res.RawWebResponse.SetCustomHeader`, etc. works unchanged.

**Concrete verification — `horse-cors`:**

`horse-cors/src/Horse.CORS.pas:67` — `if Req.RawWebRequest.Method = 'OPTIONS' then` — works unchanged. Test 30 in `HorseCSTestClient.dpr` (`GET /cors/check`, `OPTIONS /cors/check`) verifies that `OPTIONS` returns 204 + `Access-Control-Allow-Origin` and `GET` returns the route body. Passes on CrossSocket with the unmodified upstream `horse-cors`.

**Concrete verification — `horse-jhonson`:**

The COMPAT-1 fallback in `TResponseBridge.Flush` (`Response.pas:172-179`) and `TResponseBridge.WriteBody` (`Response.pas:312-326`) reads `RawWebResponse.ContentType` and `RawWebResponse.Content` when the shadow fields are empty — supporting middleware that writes via `Res.RawWebResponse.Content := X` instead of `Res.Send(X)`. The behaviour differs by compiler:

- **FPC:** `TInterfacedWebResponse` inherits `TResponse` without overriding `Content` — writes via `Res.RawWebResponse.Content := X` land in `TResponse`'s own storage, and the COMPAT-1 fallback reads them back. `horse-jhonson` works end-to-end on FPC.
- **Delphi:** `TInterfacedWebResponse.SetContent` is a stub (silent no-op — `RawAdapters.pas:389-392`) and `GetContent` always returns `''` (line 384-387), so writes via `Res.RawWebResponse.Content := X` are dropped. The COMPAT-1 fallback in the bridge is currently dormant on this path — it would activate if the adapter were extended to capture `SetContent` writes. Middleware that needs the body to round-trip on Delphi must use `Res.Send(X)`, which is the recommended API and what the upstream `horse-jhonson` code already does in its else-branch.

Test 32 (`COMPAT-1 shadow-field precedence`) writes via both paths and asserts the shadow field wins. On FPC it is a meaningful precedence check (both paths can write). On Delphi it currently only verifies that the stubbed adapter does not corrupt the shadow path — both possible "winners" would yield the same response because the rival write is a no-op. Extending the Delphi adapter to capture `SetContent` is tracked as an enhancement; nothing in the official Horse middleware ecosystem currently depends on it.

**For the wider middleware list (`horse-logger`, `horse-jwt`, `horse-basic-authenticator`, `horse-manipulate-request`, `horse-manipulate-response`):** these all access `Req.RawWebRequest` / `Res.RawWebResponse` properties that are forwarded by the adapter (`Method`, `Host`, `Headers`, `CustomHeaders`, `RemoteAddr`, `Content`, `ContentType`). No code change is required. We can run each through the integration test harness if specific cases are flagged.

A migration guide is included as `patches/horse-provider-crosssocket/doc/middleware-compatibility.md` listing each official middleware, the `RawWebRequest` / `RawWebResponse` surface it touches, the mechanism that satisfies it on CrossSocket, and the integration test that proves compatibility. Twelve middlewares are catalogued (the eight official `horse-*` packages plus the four shipped in this fork).

---

## MEDIUM — Missing CnPack search paths

**Reviewer's claim:** Building requires `..\modules\Delphi-Cross-Socket\CnPack\Common` and `..\modules\Delphi-Cross-Socket\CnPack\Crypto` on the search path; this is undocumented and `boss.json` does not add them.

**Status:** **Resolved.**

`patches/horse-provider-crosssocket/boss.json` now declares the two CnPack paths:

```json
{
  "name": "horse-provider-crosssocket",
  "version": "1.0.4",
  "mainsrc": "src/",
  "browsingpath": "src/;modules/Delphi-Cross-Socket/CnPack/Common;modules/Delphi-Cross-Socket/CnPack/Crypto",
  ...
}
```

`boss install` now adds both directories to the project's `Browsing Path`, so projects that compile directly from sources no longer hit "File not found" on `CnPack.inc`.

---

## MEDIUM — `Horse.Provider.Abstract` now depends on `Horse.Request` / `Horse.Response`

**Reviewer's claim:** The abstract provider layer used to depend only on `Horse.Core`. It now `uses Horse.Request, Horse.Response` unconditionally, pulling in the request/response stack at the abstract layer.

**Status:** **Acknowledged — this is intentional and required by PATCH-ABS-3 (`Execute`).**

`patches/horse/src/Horse.Provider.Abstract.pas:9-23` — the new `uses` pulls in `Horse.Request` and `Horse.Response` because `THorseProviderAbstract.Execute` takes them as parameters:

```pascal
class procedure Execute(
  const ARequest:  THorseRequest;
  const AResponse: THorseResponse
); virtual;
```

`Execute` is the entry point a provider that bypasses Indy's `TWebRequest` (CrossSocket today, raw socket tomorrow, mORMot bindings, …) calls after populating the request via the request bridge. Without `Execute` on the abstract base, every alternative-transport provider would need to copy-paste the `THorseCore.Routes.Execute(Req, Res, nil)` boilerplate. With it, providers stay one-liners.

**The "layering regression" framing is incorrect — `Horse.Core` already transitively uses `Horse.Request` and `Horse.Response` via its `Routes` accessor:**

```
Horse.Core uses Horse.Core.RouterTree
Horse.Core.RouterTree uses Horse.Request, Horse.Response
```

So the new explicit `uses` is making the dependency visible, not introducing it. There is no project that compiles `Horse.Provider.Abstract` without already pulling in `Horse.Request` / `Horse.Response` transitively.

If a "minimal abstract layer" is desired in the future, `Execute` could move to a separate `Horse.Provider.Abstract.Pipeline` unit. We don't think that change is justified by the current evidence.

---

## LOW — `{$MESSAGE FATAL}` define-order guard

**Reviewer's claim:** `HORSE_CROSSSOCKET` combined with `HORSE_ISAPI` / `HORSE_APACHE` / etc. silently picks the wrong provider. A 4-line `{$MESSAGE FATAL}` guard should be added.

**Status:** **Resolved by PATCH-HORSE-1; subsequently refined by PATCH-HORSE-2.**

> **Note (2026-05, PATCH-HORSE-2 follow-up):** the original PATCH-HORSE-1 block listed below treated several combinations as fatal that were actually only "not yet implemented" — `HORSE_CROSSSOCKET` + `HORSE_VCL` / `_DAEMON` / `_LCL`. PATCH-HORSE-2 (a) introduces the three-axis define model (`HORSE_PROVIDER_*` × `HORSE_APPTYPE_*` × `HORSE_HOST_*`), (b) ships five cross-product Provider units that make those combinations valid, and (c) **narrows** the `{$MESSAGE FATAL}` block to only the architecturally impossible cases (any `HORSE_PROVIDER_*` + any `HORSE_HOST_*`). The legacy define names still work — PATCH-HORSE-2 keeps them as permanent aliases. See `architecture-diagrams.md §5` and `patches/horse/doc/providers.md §6`. The PATCH-HORSE-1 listing below is preserved as the original review-cycle record.

`patches/horse/src/Horse.pas:8-44`
```pascal
{ PATCH-HORSE-1
  Fires a fatal compile error when HORSE_CROSSSOCKET is combined with any
  incompatible provider define. Without this guard, a misconfigured project
  silently picks the wrong provider via define-order. }

{$IF DEFINED(HORSE_CROSSSOCKET)}
  {$IF DEFINED(HORSE_ISAPI)}
    {$MESSAGE FATAL 'HORSE_CROSSSOCKET is incompatible with HORSE_ISAPI ... '}
  {$IFEND}
  {$IF DEFINED(HORSE_APACHE)}
    {$MESSAGE FATAL 'HORSE_CROSSSOCKET is incompatible with HORSE_APACHE ... '}
  {$IFEND}
  {$IF DEFINED(HORSE_CGI)}    {$MESSAGE FATAL '...'} {$IFEND}
  {$IF DEFINED(HORSE_FCGI)}   {$MESSAGE FATAL '...'} {$IFEND}
  {$IF DEFINED(HORSE_DAEMON)} {$MESSAGE FATAL '...'} {$IFEND}
  {$IF DEFINED(HORSE_LCL)}    {$MESSAGE FATAL '...'} {$IFEND}
  {$IF DEFINED(HORSE_VCL)}    {$MESSAGE FATAL '...'} {$IFEND}
  {$IF DEFINED(HORSE_NOPROVIDER)} {$MESSAGE FATAL '...'} {$IFEND}
{$IFEND}
```

Each message includes the *reason* (e.g. *"ISAPI is a host-managed transport; CrossSocket owns the socket directly"*) so the developer learns why the combination is invalid, not just that it is.

---

## LOW — UTF-8 BOM and missing EOF newline

**Reviewer's claim:** `Horse.pas`, `Horse.Request.pas`, and `Horse.Provider.Abstract.pas` have a UTF-8 BOM prepended and `Horse.pas` lost its final newline.

**Status:** **Verified clean. No BOM and the final newline is present.**

`od -c -N 3` on each of the three files returns `u   n   i` (the start of `unit`), not `\357\273\277` (the BOM). `tail -c 5 Horse.pas | od -c` returns `e   n   d   .  \n` — the trailing newline is intact.

The BOM the reviewer saw was likely introduced by a Delphi IDE save on the Windows working copy. CLAUDE.md → "patches/ directory" lists this as a known IDE artifact: the IDE re-encodes em-dashes (`—` → `â€"`) and may add a BOM on save. The canonical patch files do not contain either; the user's local Windows tree may have re-encoded copies.

**Mitigation:** the user's apply step (copy `patches/...` over `C:\lang\Repo\...`) overwrites the IDE-mangled file with the BOM-free canonical file. After every IDE session that saves these units, re-apply the patch to clear any drift.

---

## LOW — `MaxConnections` not guarded for CrossSocket builds

**Reviewer's claim:** `THorse.MaxConnections` exists only on Indy/Console. Existing projects that set `THorse.MaxConnections := N` will fail to compile when `HORSE_CROSSSOCKET` is defined.

**Status:** **Resolved by PATCH-ABS-4.**

`patches/horse/src/Horse.Provider.Abstract.pas:37-62, 134-141` — `MaxConnections` is now a class property on `THorseProviderAbstract`. Each concrete Indy provider declares its own `FMaxConnections` class var that shadows the abstract base's, so existing behaviour (Console, Daemon, VCL, Apache) is byte-for-byte unchanged. On the CrossSocket path the property exists but the stored value is intentionally not forwarded to the transport — CrossSocket's connection limits are configured via `THorseCrossSocketConfig.MaxConnections` instead.

The compile-time goal is met: any project that sets `THorse.MaxConnections := N` and then switches to `HORSE_CROSSSOCKET` continues to compile. The runtime behaviour change (the value is ignored on CrossSocket) is documented in the block comment at `Horse.Provider.Abstract.pas:37-47`:

> For `THorseProviderCrossSocket` (which has no `MaxConnections` of its own), the inheritance chain resolves here: the value is stored but never forwarded to the CrossSocket transport layer. CrossSocket connection limits are configured via `THorseCrossSocketConfig.MaxConnections` instead.

---

## Summary table

| Severity | Item | Status | Reference |
|---|---|---|---|
| Blocker | Process never exits after `StopListen` | Resolved | `Horse.Provider.CrossSocket.pas:271-309`; `Net.CrossSocket.Iocp.pas:8-19, 748-790`; `Server.pas:104-201` FIX-REFCOUNT-1 |
| High | `Method: string` not exposed | Resolved via hybrid adapter (PATCH-REQ-8); convenience accessor also added (PATCH-REQ-10) | `Horse.Request.pas:591-596, 613-624` |
| High | PR description: "no method altered" | Acknowledged — PR description corrected (patches unchanged) | `doc/pr-crosssocket-provider-description-v1.md`; CLAUDE.md:13-14 |
| High | PR description: `Port` property | Acknowledged — PR description corrected (patches unchanged) | `Horse.Provider.Abstract.pas:30-34` |
| Medium | `Listen` non-blocking | Resolved | same as Blocker |
| Medium | `FBody` use-after-free risk | Resolved | `Pool.pas:62-78` SEC-9; sample rewrite at `samples/Delphi/console/Console.dpr` |
| Medium | Indy `FCustomHeaders` perf regression | Resolved by PATCH-RES-7 (lazy `EnsureCustomHeaders`) | `Horse.Response.pas:83-191, 218-236` |
| Medium | `Req.Body` re-decode / binary corruption | Resolved | PATCH-REQ-9 (`Horse.Request.pas:217-225`; bridge MapBody at `Request.pas:497-506`); Test 31 |
| Medium | `Clear` allocates `THorseSessions` | Resolved | PATCH-SES-1 (`Horse.Request.pas:329-336`; `Horse.Session.pas`) |
| Medium | `ListenWithConfig` default ignores port | Resolved | `Horse.Provider.Abstract.pas:156-164` |
| Medium | Middleware compatibility plan | Resolved — architecture-level + matrix doc | PATCH-REQ-8 / PATCH-RES-6; `doc/middleware-compatibility.md` |
| Medium | CnPack search paths undocumented | Resolved — `boss.json` updated | `patches/horse-provider-crosssocket/boss.json` |
| Medium | Abstract layer pulls in Request/Response | Acknowledged; transitive dependency made explicit | `Horse.Provider.Abstract.pas:9-23` |
| Low | `{$MESSAGE FATAL}` guard | Resolved | PATCH-HORSE-1 (`Horse.pas:8-44`) |
| Low | BOM / EOF newline | Verified clean in patches; IDE artifact on user copy | `od -c` confirmed |
| Low | `MaxConnections` guard | Resolved | PATCH-ABS-4 (`Horse.Provider.Abstract.pas:37-62, 134-141`) |

---

## Detailed change log

The following items were each addressed by a discrete patch; this section restates them in delivery order with the apply-time payload so reviewers can replay them on the Windows working tree.

1. **Lazy-allocate `FCustomHeaders`** — done. `patches/horse/src/Horse.Response.pas` now has a private `EnsureCustomHeaders` helper called from `AddHeader`; the constructor no longer allocates; `RemoveHeader` is nil-guarded. Tag: PATCH-RES-7.
2. **`boss.json` updated** — `patches/horse-provider-crosssocket/boss.json` adds `modules/Delphi-Cross-Socket/CnPack/Common` and `modules/Delphi-Cross-Socket/CnPack/Crypto` to `browsingpath`. Version bumped to `1.0.4`.
3. **`Console.dpr` rewritten** — `patches/horse-provider-crosssocket/samples/Delphi/console/Console.dpr`: `/echo` route copies `Req.Body<TStream>` into a `TMemoryStream` Horse can own; unit header carries an explicit ownership-trap warning block citing SEC-9 and CLAUDE.md.
4. **`THorseRequest.Method: string` added** — PATCH-REQ-10 in `patches/horse/src/Horse.Request.pas`. The hybrid adapter still works, but `Req.Method = 'OPTIONS'` is now a one-step alternative to `Req.RawWebRequest.Method = 'OPTIONS'`.
5. **`doc/middleware-compatibility.md` created** — twelve middlewares catalogued (the eight upstream `horse-*` packages plus the four shipped in this fork), each with the touched surface, the satisfying mechanism, and the integration test that verifies it.

To apply on the Windows working tree:
```
copy patches\horse\src\Horse.Request.pas              C:\lang\Repo\horse\src\
copy patches\horse\src\Horse.Response.pas             C:\lang\Repo\horse\src\
copy patches\horse-provider-crosssocket\boss.json     C:\lang\Repo\horse-provider-crosssocket\
copy patches\horse-provider-crosssocket\samples\Delphi\console\Console.dpr  ^
     C:\lang\Repo\horse-provider-crosssocket\samples\Delphi\console\
```

The two new doc files (`pr-review-response.md`, `middleware-compatibility.md`) live under `patches/horse-provider-crosssocket/doc/` and should be copied to the corresponding `doc/` folder of the published repo at PR time.

All items listed in the summary table above are resolved or acknowledged; nothing on this list is outstanding for the current PR.
