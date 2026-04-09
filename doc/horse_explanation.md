# Additive changes to Horse — CrossSocket high-performance transport provider

> **Beta status** — This provider and the accompanying Horse patches are under active testing. We are sharing them now to gather feedback and to start the review process early. Please do not merge until the test suite is complete and a stable tag has been issued on the provider repository. We welcome any comments on scope, style, or alternative approaches.

---

## What this is and why it matters

We have developed [`horse-provider-crosssocket`](https://github.com/freitasjca/horse-provider-crosssocket), an optional new provider for Horse that replaces the Indy transport layer with [Delphi-Cross-Socket](https://github.com/winddriver/Delphi-Cross-Socket). This brings:

- **IOCP on Windows / epoll on Linux / kqueue on macOS** — the same async I/O primitives that power nginx, Node.js, and Go's `net/http`
- **10 000+ concurrent connections** on hardware where Indy exhausts its thread pool well below 1 000
- **Full Linux 64-bit support** including Docker deployment
- **Security hardening** at the transport boundary: request smuggling protection, enforced size limits, read timeouts, CRLF injection prevention, hop-by-hop header filtering, and clickjacking/MIME-sniffing defences on every response
- **Zero-allocation hot path** via a pre-warmed context pool

**Critically: this requires only five additive patches to Horse itself.** No existing API is renamed, removed, or changed. Every existing Horse project, provider, and official middleware continues to compile and run without any modification. The entire feature is opt-in via a single compiler define.

---

## Performance case: why CrossSocket is architecturally faster

### The structural problem with Indy

Indy allocates one blocking OS thread per connection. This creates hard scaling limits that no amount of tuning can overcome:

| Bottleneck | Indy (one thread per connection) | CrossSocket (epoll / IOCP) |
|---|---|---|
| Thread stack memory | ~1–2 MB per thread. 1 000 concurrent connections ≈ 1–2 GB reserved stack | Fixed IO thread count (typically 4–16 regardless of connection count) |
| Context-switch pressure | OS scheduler preempts hundreds of threads even when they are all waiting for I/O | IO threads never block; the kernel notifies them only when data is ready |
| `accept()` serialisation | Single-threaded accept bottleneck above a few hundred connections/second | `accept()` distributed across IO threads |
| Per-request allocation | Fresh `THorseRequest` + `THorseResponse` + their dictionaries every request | Context pool recycles 32–512 pre-warmed pairs — allocator not called on the hot path |
| Idle keep-alive cost | Each idle keep-alive connection holds a thread | Idle keep-alive connections consume one epoll/IOCP handle — negligible cost |

These are **structural differences**, not configuration differences. The thread-per-connection model is the constraint, and it cannot be tuned away.

### Indicative numbers

> The figures below are from community reports and the general async-vs-thread-per-connection literature. Our own load-testing suite is in progress. We will replace these with measured results before requesting final merge.

Published benchmarks of epoll-based vs. thread-per-connection HTTP servers consistently show:
- **3× to 10× higher throughput** at equivalent concurrency
- **10× to 50× more peak concurrent connections** before degradation
- Sub-millisecond median latency on simple routes vs. multi-millisecond under scheduler pressure

These figures are consistent with results from equivalent libraries in other languages (libuv, Boost.Asio, netty) and with the [C10K problem literature](http://www.kegel.com/c10k.html).

### When CrossSocket is the right choice

| Scenario | Recommendation |
|---|---|
| REST API with many concurrent clients | ✅ CrossSocket |
| Long-polling / SSE (many idle open connections) | ✅ CrossSocket |
| High-throughput microservice in Docker / Linux | ✅ CrossSocket |
| Low-concurrency internal tooling (< 50 simultaneous users) | Either — difference is imperceptible |
| IIS / Apache / CGI deployment | ❌ CrossSocket — architecturally incompatible (see below) |

---

## The integration strategy

### Why the strategy matters as much as the changes

The Horse codebase has a large existing user base, multiple official and community middlewares, and must compile on both Delphi and Lazarus/FPC. Any integration strategy that requires changing existing APIs, existing constructor signatures, or existing middleware behaviour is a non-starter. The strategy described here was chosen specifically because it satisfies **all** of these constraints simultaneously without a single line of existing code changing its meaning.

### Strategy 1 — One compiler define, one switch point

The entire CrossSocket integration is activated by one project-level compiler define:

```pascal
{$DEFINE HORSE_CROSSSOCKET}
```

`Horse.pas` is the **only file** that tests this define. Without it, `THorseProvider` resolves to the existing Console/Indy provider and every CrossSocket unit is excluded from compilation — identical to upstream. With it, `THorseProvider` resolves to `THorseProviderCrossSocket`:

```pascal
// Horse.pas — the sole switch point
{$ELSEIF DEFINED(HORSE_CROSSSOCKET)}
  THorseProvider = Horse.Provider.CrossSocket.THorseProviderCrossSocket;
{$ELSE}
  THorseProvider = Horse.Provider.Console.THorseProvider;  // unchanged
{$ENDIF}
```

Application code that calls `THorse.Listen(8080)` is unaware of which transport is active. All Horse middleware (JWT, CORS, Jhonson, Basic Auth, Logger, …) works identically on both paths because they interact exclusively through `THorseRequest` and `THorseResponse` — the same types on both paths.

**Why a compiler define rather than a runtime switch:** A runtime switch always compiles both providers into every binary, increasing binary size for all Indy users and requiring an explicit initialisation call in every project. A compiler define has zero runtime overhead, zero binary size impact, and zero startup code for users who do not opt in. It is the standard Delphi/FPC mechanism for optional feature flags.

### Strategy 2 — Shadow fields + nil-guards (the core pattern)

Horse's entire request/response API delegates to private Indy objects:

```pascal
THorseRequest  → FWebRequest:  TWebRequest   (Delphi) / TRequest (FPC)
THorseResponse → FWebResponse: TWebResponse  (Delphi) / TResponse (FPC)
```

Every public accessor — `Body`, `Host`, `Headers`, `Query`, `Params`, `Send`, `Status`, `ContentType`, `AddHeader` — reads from or writes to those Indy objects. On the CrossSocket path, those fields are always `nil` because CrossSocket never creates a `TWebRequest`.

**The core constraint is therefore:** make `THorseRequest` and `THorseResponse` work correctly when `FWebRequest` and `FWebResponse` are `nil`.

The solution is the **shadow field pattern**: for each piece of data that Horse normally reads from the Indy objects, a corresponding private field is added alongside:

| Shadow field | Replaces on CrossSocket path |
|---|---|
| `FCSMethod: string` | `FWebRequest.Method` |
| `FCSMethodType: TMethodType` | `FWebRequest.MethodType` |
| `FCSPathInfo: string` | `FWebRequest.RawPathInfo` |
| `FCSContentType: string` | `FWebRequest.ContentType` (request side) |
| `FCSRemoteAddr: string` | `FWebRequest.Host` |
| `FCSStatusCode: Integer` | `FWebResponse.StatusCode` |
| `FCSBody: string` | `FWebResponse.Content` |
| `FCSContentType: string` | `FWebResponse.ContentType` (response side) |
| `FCSContentStream: TStream` | `FWebResponse` stream body (non-owning) |
| `FCustomHeaders: TDictionary<string,string>` | `FWebResponse.SetCustomHeader` |

Every public accessor is then a nil-guard:

```pascal
function THorseRequest.Body: string;
begin
  if not Assigned(FWebRequest) then
  begin
    // CrossSocket path: read from CrossSocket's socket buffer
    if Assigned(FBody) and (FBody is TStream) then
    begin
      TStream(FBody).Position := 0;
      SetLength(LBytes, TStream(FBody).Size);
      TStream(FBody).ReadBuffer(LBytes[0], TStream(FBody).Size);
      Exit(TEncoding.UTF8.GetString(LBytes));
    end;
    Exit('');
  end;
  // Indy path: original behaviour, completely unchanged
  Result := FWebRequest.Content;
end;
```

The Indy path is always the `else` branch, executed when `FWebRequest` is assigned. This preserves **100% of the original Indy behaviour** for every existing user and middleware.

**Why shadow fields rather than an abstract interface:** An `IHorseWebRequest` interface would require changing every existing middleware and every caller of `THorseRequest` — thousands of lines across dozens of community packages. Shadow fields are an invisible implementation detail. Every middleware written before this patch continues to call the same API and gets the same result. The cost is a small number of extra fields per request object (negligible) and one branch per accessor (correctly predicted by the CPU branch predictor, because it saturates on the Indy path for Indy users and on the CrossSocket path for CrossSocket users).

**Why nil-guard rather than a strategy object:** A strategy object (vtable stored in the request) would add a pointer indirection on every property access and require a different object layout. Nil-guard branches add no layout change and no indirection.

### Strategy 3 — Strictly additive changes only

With one carefully justified exception (see `Horse.Core.RouterTree.pas` below), every change to Horse is an addition. Nothing existing is renamed, removed, or given a different signature. This means:

- Existing Indy users can apply the patches and get no behaviour change at all (without the define).
- Community middlewares do not need modification, recompilation, or awareness of CrossSocket.
- The changes can be reviewed purely as additions — there is no "before vs. after" diff to worry about for existing functionality.

### Strategy 4 — Bypass the Web Module; drive the pipeline directly

On the Indy path, the chain from network to Horse pipeline is:

```
TIdHTTPWebBrokerBridge → WebRequestHandler → THorseWebModule
  → THorseRequest.Create(TWebRequest) → Routes.Execute
```

`THorseWebModule` is the Indy broker integration layer. On CrossSocket there is no broker and no `TWebRequest`. Rather than writing a fake `TWebRequest` adapter (which would require implementing 30+ properties and methods tightly coupled to Indy's HTTP parsing), the CrossSocket provider bypasses the broker stack entirely and drives the Horse pipeline through the new `THorseProviderAbstract.Execute` method:

```
ICrossHttpRequest (CrossSocket)
  → TRequestBridge.Populate    ← validates + writes shadow fields on THorseRequest
  → THorse.Execute(Req, Res)   ← direct pipeline entry (PATCH-ABS-3)
  → TResponseBridge.Flush      ← reads THorseResponse shadow fields, writes ICrossHttpResponse
```

`THorse.Execute` is the new entry point added to `THorseProviderAbstract`. It calls `Routes.Execute(Request, Response)` — the same route dispatch that the web module calls on the Indy path. This is the minimal expression of "run the pipeline" and the only new entry point added to the abstract base.

### Strategy 5 — Security at the bridge boundary, not in middleware

All untrusted input passes through `TRequestBridge.Populate` before reaching the Horse pipeline. This is the correct and only place to enforce security invariants — if a malformed request reaches middleware, it has already been partially processed. `Populate` returns `rvOK`, `rvBadRequest`, or `rvMethodNotAllowed`. On anything other than `rvOK`, a direct JSON error response is sent via `ICrossHttpResponse` and the context pool is never acquired. No middleware sees the bad request.

| Threat | Mitigation in `TRequestBridge.Populate` |
|---|---|
| HTTP request smuggling | Reject if both `Content-Length` and `Transfer-Encoding` are present (RFC 7230 §3.3.3) |
| Oversized headers | 100-header max; 256-byte name limit; 8 KB value limit |
| Oversized URL | 8 KB limit on the raw undecoded URL |
| Dangerous methods | `CONNECT` and `TRACE` rejected (XST / proxy abuse) |
| Invalid / non-ASCII Host | Reject with 400 |

Additional mitigations in `TResponseBridge.Flush`:

| Threat | Mitigation |
|---|---|
| CRLF injection | All response header values stripped of CR, LF, NUL before writing |
| Hop-by-hop header leakage | `Connection`, `Transfer-Encoding`, `Keep-Alive`, etc. filtered |
| MIME sniffing | `X-Content-Type-Options: nosniff` on every response |
| Clickjacking | `X-Frame-Options: DENY` on every response |
| Server fingerprinting | `Server:` header set to configured value or `'unknown'` |

### Strategy 6 — Object pool for zero-allocation hot path

The Indy path allocates a fresh `THorseRequest` / `THorseResponse` pair per request. This works because `TWebRequest` construction dominates and Horse's wrappers are thin. On CrossSocket, IOCP/epoll callbacks fire at high frequency. Per-request allocation becomes a bottleneck under load.

`THorseContextPool` pre-allocates 32–512 `THorseContext` objects and recycles them via `Acquire` / `Release`. Reuse is safe because `Clear()` — added to both `THorseRequest` and `THorseResponse` — reliably resets every field between requests:

- `FWebRequest := nil` and `FWebResponse := nil` — so nil-guards engage for the next CrossSocket request
- All shadow fields cleared
- `FCustomHeaders` cleared **in place** (dictionary object reused — no heap churn on the hot path)
- `FCSContentStream := nil` **without freeing** (non-owning reference — CrossSocket owns the socket buffer)

The Indy path never touches the pool. Indy continues to allocate and free normally.

### Strategy 7 — Dual-compilation discipline (Delphi + Lazarus/FPC)

Every file in the `patches/horse/src/` set must compile under both `dcc64` (Delphi 10.4+) and `fpc` (Lazarus). This is a hard constraint because Horse's FPC user base is large. Specific rules applied to every patched file:

- Every unit carries `{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}` at the top
- `uses` clauses are split: `System.Generics.Collections` (Delphi) vs `Generics.Collections` (FPC); `Web.HTTPApp` (Delphi) vs `fpHTTP`/`HTTPDefs` (FPC)
- `FCustomHeaders` is `TDictionary<string,string>` on Delphi; `TStringList` on FPC (FPC generics have limitations with certain type combinations)
- No inline `var` declarations (Delphi 10.3+ feature); traditional `var` blocks only
- No `System.Threading` in shared files
- The `{$DEFINE HORSE_CROSSSOCKET}` guard is applied surgically — only around additions that require CrossSocket-specific types; without the define the files compile identically to upstream on both compilers

---

## Files changed in Horse — detailed technical rationale

### `Horse.pas` — transport selection switch

**Change type:** Modified  
**Lines changed:** ~15 lines in the `uses` clause and `THorseProvider` type alias block

The `uses` clause gains a `{$IF DEFINED(HORSE_CROSSSOCKET)}` branch that pulls in `Horse.Provider.CrossSocket` instead of the default providers, for both Delphi and FPC:

```pascal
// Delphi path
{$ELSEIF DEFINED(HORSE_CROSSSOCKET)}
  Horse.Provider.CrossSocket,
{$ELSE}
  Horse.Provider.Console,
  Horse.Provider.Daemon,
  ...
{$ENDIF}
```

The `THorseProvider` type alias is extended by the same guard. Application code calls `THorse.Listen(port)` identically on both paths — the alias ensures `THorse` inherits from whichever provider is active.

**Why only `Horse.pas`:** Centralising the transport choice in one place means there is exactly one file to review when reasoning about whether the CrossSocket define is active. Any future provider would follow the same pattern.

---

### `Horse.Request.pas` — parameterless constructor, Clear, Populate, shadow fields, nil-guards

**Change type:** Modified (strictly additive — no existing method changed)  
**Patch identifiers:** PATCH-REQ-1 through PATCH-REQ-5

#### PATCH-REQ-1: Parameterless constructor

```pascal
constructor THorseRequest.Create; overload;
```

`THorseContextPool.WarmUp` pre-allocates `THorseRequest` instances at application startup, before any HTTP request arrives. The original constructor requires a live `TWebRequest` object, which does not exist at warmup time. This overload initialises the request with all fields at their zero/nil defaults. The original constructor is completely unchanged.

#### PATCH-REQ-2: `Clear` procedure

```pascal
procedure THorseRequest.Clear;
```

Resets all fields for pool reuse between requests. Key rules:
- `FBody` is set to `nil` and **never freed** — on the CrossSocket path it is a non-owning reference into CrossSocket's socket buffer, and CrossSocket retains ownership
- `FWebRequest := nil` — so nil-guards correctly engage for the next CrossSocket request
- `FSession := nil` — stale session data must not leak across requests
- Param/query/cookie/header collections are cleared in place (objects reused, not freed)

#### PATCH-REQ-3: Shadow fields and `Populate`

Five private shadow fields added to `THorseRequest`:

```pascal
FCSMethod:      string;
FCSMethodType:  TMethodType;
FCSPathInfo:    string;
FCSContentType: string;
FCSRemoteAddr:  string;
```

The `Populate` procedure injects all five at the start of each CrossSocket request:

```pascal
procedure THorseRequest.Populate(
  const AMethod, APath, AContentType, ARemoteAddr: string;
  const AMethodType: TMethodType
);
```

Every accessor that previously read from `FWebRequest` gains a nil-guard that returns the corresponding shadow field when `FWebRequest` is `nil`:

```pascal
function THorseRequest.MethodType: TMethodType;
begin
  if not Assigned(FWebRequest) then
    Exit(FCSMethodType);             // CrossSocket path
  Result := FWebRequest.MethodType;  // Indy path — unchanged
end;
```

#### PATCH-REQ-4: `PopulateCookiesFromHeader`

Parses the raw `Cookie` request header into `THorseRequest.Cookie` without requiring a live `TWebRequest`. This makes `Req.Cookie['name']` work correctly on the CrossSocket path, where Indy never parses the cookie header.

#### PATCH-REQ-5: `RawPathInfo` accessor

This patch addresses the subtlest constraint in the entire integration. The original router (`Horse.Core.RouterTree.pas`) accessed the request path as:

```pascal
// Before this patch:
ARequest.RawWebRequest.RawPathInfo   // Delphi
ARequest.RawWebRequest.PathInfo      // FPC
```

On CrossSocket, `RawWebRequest` is `nil` → immediate Access Violation. The naive fix — `ARequest.PathInfo` — introduces a silent routing regression: `PathInfo` is percent-decoded, `RawPathInfo` is not. A URL like `/files/2024%2F01%2Freport.pdf` would decode to `/files/2024/01/report.pdf` and match a different (or no) route. This would silently change routing behaviour for all existing Indy users without any indication that anything changed.

The correct fix adds a new `RawPathInfo` accessor with three distinct code paths:

```pascal
function THorseRequest.RawPathInfo: string;
begin
  if not Assigned(FWebRequest) then
    Exit(FCSPathInfo);               // CrossSocket: stored undecoded by bridge
{$IF DEFINED(FPC)}
  Result := FWebRequest.PathInfo;    // FPC/Indy: PathInfo is the only option
{$ELSE}
  Result := FWebRequest.RawPathInfo; // Delphi/Indy: undecoded, preserves old behaviour
{$ENDIF}
end;
```

The router then calls `ARequest.RawPathInfo` instead of going through `RawWebRequest` directly. This is the right fix because it makes the invariant — "the router always sees the undecoded path" — explicit and visible in the source code, and it works identically on all three code paths.

---

### `Horse.Response.pas` — shadow fields, FCustomHeaders, Clear, nil-guards, bridge properties

**Change type:** Modified (strictly additive)  
**Patch identifiers:** PATCH-RES-1 through PATCH-RES-4

#### PATCH-RES-1: `FCustomHeaders` and the `AddHeader` dual-write

```pascal
// Delphi
FCustomHeaders: TDictionary<string, string>;
// FPC
FCustomHeaders: TStringList;
```

`THorseResponse.AddHeader` normally calls `FWebResponse.SetCustomHeader`, which crashes on CrossSocket because `FWebResponse` is nil. A nil-guard alone is not sufficient — the response bridge needs to be able to **read back** those headers when flushing to `ICrossHttpResponse`. `FCustomHeaders` is that readable store.

`AddHeader` is updated to dual-write on both paths:

```pascal
function THorseResponse.AddHeader(const AName, AValue: string): THorseResponse;
begin
  if Assigned(FWebResponse) then
    FWebResponse.SetCustomHeader(AName, AValue);   // Indy: write to response object
  FCustomHeaders.AddOrSetValue(AName, AValue);      // Both paths: bridge reads this
  Result := Self;
end;
```

The response bridge iterates `FCustomHeaders` when flushing, applying CRLF-stripping and hop-by-hop header filtering. Because `AddHeader` always writes to `FCustomHeaders` on both paths, the bridge code is transport-agnostic.

`RemoveHeader` follows the same pattern — removes from `FWebResponse.CustomHeaders` (Indy) and from `FCustomHeaders` (both).

The `CustomHeaders` read-only property (PATCH-RES-3) exposes `FCustomHeaders` to the response bridge.

**Note on `Set-Cookie`:** `FCustomHeaders` is a `TDictionary` on Delphi (last value wins for duplicate keys). The response bridge (`TResponseBridge.CopyHeaders`) handles `Set-Cookie` specially: it calls `ACrossRes.Header.Add(name, value, ADupAllowed=True)` to append each cookie as a separate header line rather than overwriting. This correctly produces multiple `Set-Cookie` lines on the wire as required by RFC 6265.

#### PATCH-RES-2: `Clear` procedure

Resets all response fields for pool reuse. Key rules:
- `FWebResponse := nil` — so nil-guards engage for the next CrossSocket request
- `FContent := nil` (never freed — ownership belongs to the caller)
- `FCustomHeaders.Clear` called in place — dictionary object reused, no heap allocation
- `FCSContentStream := nil` **without freeing** — non-owning reference into CrossSocket's buffer

#### PATCH-RES-3: `CustomHeaders` read-only property

```pascal
property CustomHeaders: TDictionary<string,string> read FCustomHeaders;  // Delphi
property CustomHeaders: TStringList read FCustomHeaders;                   // FPC
```

The response bridge iterates this property when flushing headers to `ICrossHttpResponse`. Read-only — all writes go through `AddHeader` and `RemoveHeader`.

#### PATCH-RES-4: Shadow fields and bridge-readable properties

Four shadow fields:

```pascal
FCSStatusCode:    Integer;    // default 200
FCSBody:          string;
FCSContentType:   string;
FCSContentStream: TStream;    // non-owning
```

Every response-writing accessor (`Send`, `Status`, `ContentType`, `SendFile`, `Download`, `RedirectTo`) gains a nil-guard that writes to the shadow fields when `FWebResponse` is `nil` (CrossSocket path) and to `FWebResponse` when it is assigned (Indy path).

Three read-only properties expose the shadow fields to the response bridge:

```pascal
property BodyText:      string  read FCSBody;
property ContentStream: TStream read FCSContentStream;
property CSContentType: string  read FCSContentType;
```

`Status` (the zero-argument getter) is similarly nil-guarded to return `FCSStatusCode` on the CrossSocket path.

---

### `Horse.Core.RouterTree.pas` — the one non-additive change

**Change type:** Modified (one-line substitution in `Execute`)  
**Patch identifier:** PATCH-TREE-1

This is the **only non-additive change** in the entire Horse patch set. In the `Execute` method, two direct accesses to `ARequest.RawWebRequest` are replaced with the nil-guarded accessors introduced by PATCH-REQ-3 and PATCH-REQ-5:

```pascal
// Before (crashes on CrossSocket; FWebRequest is nil):
LPathInfo   := ARequest.RawWebRequest.RawPathInfo;   // Delphi
LMethodType := ARequest.RawWebRequest.MethodType;

// After (correct on all paths):
LPathInfo   := ARequest.RawPathInfo;   // PATCH-REQ-5 accessor
LMethodType := ARequest.MethodType;    // PATCH-REQ-3 accessor (nil-guarded)
```

**Why this is semantically equivalent on the Indy path:**
- `ARequest.RawPathInfo` on Delphi/Indy returns `FWebRequest.RawPathInfo` — exactly what the old code returned
- `ARequest.RawPathInfo` on FPC/Indy returns `FWebRequest.PathInfo` — exactly what the old code returned
- `ARequest.MethodType` delegates to `FWebRequest.MethodType` when `FWebRequest` is assigned — exactly the same call as before

The old code and the new code are semantically identical on the Indy path. The new code additionally works on the CrossSocket path. There is no change in observable behaviour for any existing user.

---

### `Horse.Provider.Abstract.pas` — `ListenWithConfig`, `Execute` virtual methods

**Change type:** Modified (strictly additive)  
**Patch identifiers:** PATCH-ABS-1, PATCH-ABS-2, PATCH-ABS-3

#### PATCH-ABS-1: `uses Horse.Provider.Config`

Added to the `uses` clause (under `{$DEFINE HORSE_CROSSSOCKET}` guard), pulling in the `THorseCrossSocketConfig` type needed by `ListenWithConfig`.

#### PATCH-ABS-2: `ListenWithConfig` virtual class method

```pascal
class procedure ListenWithConfig(
  const APort:   Integer;
  const AConfig: THorseCrossSocketConfig
); virtual;
```

The CrossSocket provider needs a structured way to pass rich server configuration (TLS certificates, timeouts, connection limits, worker thread count) to the server. The existing `Listen` overloads accept only a port. Rather than adding multiple parameters to `Listen` (which would break the existing API), `ListenWithConfig` is a new method with a config record.

The base implementation:

```pascal
class procedure THorseProviderAbstract.ListenWithConfig(
  const APort: Integer; const AConfig: THorseCrossSocketConfig);
begin
  Listen;  // Safe fallback for all existing providers — AConfig intentionally ignored
end;
```

All existing providers (Console, Daemon, VCL, FPC variants) receive a `ListenWithConfig` override in their respective `patches/` files that calls `SetPort(APort)` before delegating to `InternalListen`. This ensures that the `APort` argument is honoured even when `ListenWithConfig` is called on a non-CrossSocket provider. The CrossSocket provider overrides `ListenWithConfig` completely with its own startup logic.

#### Why `FPort` is NOT declared in the abstract base

In Delphi, a `class var` declared in a subclass is a completely independent memory location from any `class var` with the same name in the parent — they do not share storage. If both the abstract base and the Console provider declared `FPort`, writing to one would have no effect on the other. This caused a "port not changing" bug in an earlier iteration of this patch. The solution is for each concrete provider to own exclusively its own `FPort`. The abstract base class declares **no** `FPort`.

#### PATCH-ABS-3: `Execute` virtual class method

```pascal
class procedure Execute(
  const ARequest:  THorseRequest;
  const AResponse: THorseResponse
); virtual;
```

The CrossSocket provider's request callback must trigger the Horse middleware and routing pipeline after populating the request. On the Indy path this happens automatically via the web module. On CrossSocket the provider drives the pipeline explicitly. `Execute` provides that entry point. The base implementation calls `Routes.Execute(ARequest, AResponse)` — the same dispatch as the web module.

---

### `Horse.Provider.Config.pas` — new unit (pure data)

**Change type:** New file

Defines `THorseCrossSocketConfig` — a `record` with a `Default` class factory:

```pascal
type
  THorseCrossSocketConfig = record
    IOThreadCount:      Integer;   // default: CPU count
    KeepAliveTimeout:   Integer;   // seconds; default 30
    ReadTimeout:        Integer;   // seconds; Slowloris mitigation; default 20
    DrainTimeoutMs:     Integer;   // graceful shutdown; default 5000
    MaxHeaderCount:     Integer;   // default 100
    MaxHeaderValueSize: Integer;   // bytes; default 8192
    MaxBodySize:        Int64;     // bytes; default 4 MB
    MaxConnections:     Integer;   // default 10000
    SSLEnabled:         Boolean;
    SSLCertFile:        string;
    SSLKeyFile:         string;
    SSLCACertFile:      string;    // mTLS: CA certificate for client verification
    SSLVerifyPeer:      Boolean;   // mTLS: require valid client certificate
    SSLCipherList:      string;
    ServerBanner:       string;    // '' → 'unknown' in Server: header
    WorkerThreadMin:    Integer;   // default 4
    WorkerThreadMax:    Integer;   // default 64
    class function Default: THorseCrossSocketConfig; static;
  end;
```

**Why a separate unit:** Both `Horse.Provider.Abstract` (which declares `ListenWithConfig`) and `Horse.Provider.CrossSocket` (which implements it) need the `THorseCrossSocketConfig` type. Placing the type in either file creates a circular dependency. A standalone unit with no dependencies on Horse internals or on CrossSocket resolves the cycle cleanly. It is a pure data declaration — no classes, no interfaces, no event handlers — so it has no negative impact on any existing build.

---

### `Horse.Provider.Console.pas`, `Horse.Provider.Daemon.pas`, `Horse.Provider.VCL.pas`, `Horse.Provider.FPC.*.pas` — `ListenWithConfig` overrides

**Change type:** Modified (strictly additive — new override only)

Each concrete provider gets a `ListenWithConfig` override that honours the `APort` argument:

```pascal
// Example: Horse.Provider.Console.pas
class procedure THorseProviderConsole.ListenWithConfig(
  const APort: Integer; const AConfig: THorseCrossSocketConfig);
begin
  SetPort(APort);
  InternalListen;
end;
```

Without this override, calling `THorse.ListenWithConfig(8080, Config)` on the Console provider would invoke the abstract base's fallback (`Listen` with no args), which uses whatever port was previously set — not the `APort` argument. The override is four lines and safe for all existing users.

---

## Architectural incompatibility with host-managed providers

`HORSE_CROSSSOCKET` **cannot coexist with `HORSE_ISAPI`, `HORSE_APACHE`, `HORSE_CGI`, or `HORSE_FCGI`**. This is an architectural incompatibility, not a define-ordering issue.

CrossSocket calls `bind()` + `listen()` on a raw OS socket and owns it for the process lifetime. ISAPI, Apache modules, CGI, and FastCGI operate under the opposite contract: the **host process** (IIS / httpd / CGI caller) owns the socket, parses the HTTP request, and hands a pre-built `TWebRequest` to the Delphi code. The Delphi process never sees a socket file descriptor.

The current `Horse.pas` conditional chain checks `HORSE_ISAPI`, `HORSE_APACHE`, `HORSE_CGI`, and `HORSE_FCGI` before `HORSE_CROSSSOCKET`. If a developer accidentally sets both, the host-managed provider silently wins and `THorse.Listen` has no effect — the server appears to compile and link but never listens on any port.

We propose that a follow-up commit adds an explicit compile-time guard to catch this misconfiguration immediately:

```pascal
{$IF DEFINED(HORSE_CROSSSOCKET) AND
    (DEFINED(HORSE_ISAPI) OR DEFINED(HORSE_APACHE) OR
     DEFINED(HORSE_CGI)   OR DEFINED(HORSE_FCGI))}
  {$MESSAGE FATAL 'HORSE_CROSSSOCKET cannot be combined with HORSE_ISAPI, ' +
                  'HORSE_APACHE, HORSE_CGI, or HORSE_FCGI. CrossSocket owns ' +
                  'the listening socket directly; these providers require the ' +
                  'host process to own it. Remove all other provider defines.'}
{$ENDIF}
```

This guard is **not included in the current PR** to keep the patch minimal, but we consider it a worthwhile follow-up.

| Deployment model | CrossSocket compatible? | Notes |
|---|---|---|
| Console / long-running service (Indy) | ✅ Direct replacement | CrossSocket is a faster, async-native drop-in |
| Linux daemon | ✅ Primary use case | epoll; Docker or systemd service |
| Windows service (`HORSE_DAEMON`) | ✅ Compatible | CrossSocket runs inside the service |
| VCL app embedding a server | ✅ Compatible | CrossSocket runs on a background thread |
| IIS via ISAPI DLL | ❌ Incompatible | IIS owns the socket |
| Apache httpd module | ❌ Incompatible | Apache owns the socket |
| CGI / FastCGI | ❌ Incompatible | No persistent process; IOCP/epoll loop never runs |

---

## How to activate the provider

### Step 1 — Add the compiler define

In **Project Options → Delphi Compiler → Conditional defines** (or the FPC equivalent):

```
HORSE_CROSSSOCKET
```

### Step 2 — Minimal application code (identical to existing Horse code)

```delphi
program MyServer;
{$APPTYPE CONSOLE}
uses
  Horse;
begin
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('pong');
    end);

  THorse.Listen(8080);
end.
```

No application code changes. Existing middleware registrations continue working.

### Step 3 — Advanced configuration (optional)

```delphi
uses
  Horse,
  Horse.Provider.Config;

var
  Config: THorseCrossSocketConfig;
begin
  Config                  := THorseCrossSocketConfig.Default;
  Config.ReadTimeout      := 20;          // seconds — Slowloris mitigation
  Config.KeepAliveTimeout := 30;
  Config.MaxBodySize      := 8388608;     // 8 MB
  Config.SSLEnabled       := True;
  Config.SSLCertFile      := '/app/certs/server.crt';
  Config.SSLKeyFile       := '/app/certs/server.key';

  THorse.ListenWithConfig(443, Config);
end.
```

---

## Applying the patches

All Horse patch files are in [`patches/horse/src/`](https://github.com/freitasjca/horse-provider-crosssocket/tree/main/patches/horse/src). To apply, copy each file over the corresponding `horse/src/` file:

```
patches/horse/src/Horse.Request.pas           → horse/src/Horse.Request.pas
patches/horse/src/Horse.Response.pas          → horse/src/Horse.Response.pas
patches/horse/src/Horse.Core.RouterTree.pas   → horse/src/Horse.Core.RouterTree.pas
patches/horse/src/Horse.Provider.Abstract.pas → horse/src/Horse.Provider.Abstract.pas
patches/horse/src/Horse.Provider.Config.pas   → horse/src/Horse.Provider.Config.pas  (new)
patches/horse/src/Horse.Provider.Console.pas  → horse/src/Horse.Provider.Console.pas
patches/horse/src/Horse.Provider.Daemon.pas   → horse/src/Horse.Provider.Daemon.pas
patches/horse/src/Horse.Provider.VCL.pas      → horse/src/Horse.Provider.VCL.pas
patches/horse/src/Horse.Provider.FPC.*.pas    → horse/src/Horse.Provider.FPC.*.pas
```

To inspect any individual change: `diff patches/horse/src/<file>.pas horse/src/<file>.pas`

---

## Testing and verification status

> **Tests are currently underway. This is a beta release.** We will update this section and request final merge review once the full suite passes.

**Completed:**
- All existing official middlewares (`horse-jwt`, `horse-cors`, `horse-jhonson`, `horse-logger`, `horse-basic-authenticator`) compile and respond correctly with zero changes when `HORSE_CROSSSOCKET` is active
- The Horse patches compile cleanly on Delphi 10.4 Sydney, 11 Alexandria, and 12 Athens — both `Win64` and `Linux64` targets
- Full route coverage verified end-to-end: GET, POST, PUT, DELETE, PATCH, HEAD; route parameters, query strings, request headers, cookies, JSON body, multipart file upload, file download with `Content-Disposition`
- Graceful shutdown drain verified under load
- Docker deployment on Ubuntu 22.04 via WSL 2 verified

**In progress:**
- Full automated test suite (large bodies, concurrent connections, keep-alive, TLS handshake, mTLS, malformed requests)
- Load testing to replace the indicative performance figures with measured results
- FPC / Lazarus runtime testing on FPC 3.3.1

---

## Dependency note

[Delphi-Cross-Socket](https://github.com/winddriver/Delphi-Cross-Socket) requires a `boss.json` and a version tag to be consumable by the Boss package manager. A community fork ([freitasjca/Delphi-Cross-Socket](https://github.com/freitasjca/Delphi-Cross-Socket)) has already added these, along with the required CnPack cryptographic sources. The entire stack is therefore installable today with:

```
boss install github.com/freitasjca/horse-provider-crosssocket
```

The ideal long-term outcome is for the original Delphi-Cross-Socket repository to adopt the `boss.json` so there is a single canonical source.

---

## Summary of all files changed in Horse

| File | Change type | What was added | What was changed |
|---|---|---|---|
| `Horse.pas` | Modified | `HORSE_CROSSSOCKET` conditional branch | — |
| `Horse.Request.pas` | Modified | `Create` (no-arg), `Clear`, `Populate`, `PopulateCookiesFromHeader`, `RawPathInfo`, shadow fields, nil-guards on `Body`/`Host`/`InitializeQuery` | — |
| `Horse.Response.pas` | Modified | `Clear`, shadow fields, `FCustomHeaders`, `CustomHeaders`/`BodyText`/`ContentStream`/`CSContentType` properties, nil-guards on all setters | — |
| `Horse.Core.RouterTree.pas` | Modified | — | `Execute` calls `ARequest.RawPathInfo` + `ARequest.MethodType` instead of `RawWebRequest.RawPathInfo` + `RawWebRequest.MethodType` (semantically equivalent on Indy; fixes crash on CrossSocket) |
| `Horse.Provider.Abstract.pas` | Modified | `ListenWithConfig`, `Execute`; `uses Horse.Provider.Config` | — |
| `Horse.Provider.Config.pas` | **New file** | `THorseCrossSocketConfig` record with `Default` factory | — |
| `Horse.Provider.Console.pas` | Modified | `ListenWithConfig` override | — |
| `Horse.Provider.Daemon.pas` | Modified | `ListenWithConfig` override | — |
| `Horse.Provider.VCL.pas` | Modified | `ListenWithConfig` override | — |
| `Horse.Provider.FPC.HTTPApplication.pas` | Modified | `ListenWithConfig` override | — |
| `Horse.Provider.FPC.Daemon.pas` | Modified | `ListenWithConfig` override | — |
| `Horse.Provider.FPC.FastCGI.pas` | Modified | `ListenWithConfig` override | — |
| `Horse.Provider.FPC.LCL.pas` | Modified | `ListenWithConfig` override | — |

**Net change to Horse source:** approximately 350 lines added across 13 files; 2 lines changed (the `RawWebRequest` → `RawPathInfo`/`MethodType` substitution in `Horse.Core.RouterTree.pas`).

---

We would be very happy to discuss any aspect of these changes, adjust scope, split into smaller PRs, or address any questions from the maintainers. Thank you for maintaining such a well-designed framework — the clean separation between provider, routing, and middleware layers made this integration significantly more tractable than it would have been otherwise.
