## Additive changes to support CrossSocket high‑performance provider

> This provider and the accompanying Horse patches are covered by an automated integration test suite (32 tests) covering all HTTP methods, routing, cookies, body handling, concurrent-request pool isolation, error paths, large responses, RawWebRequest adapter verification, CORS middleware compatibility, body double-read idempotency (PATCH-REQ-9), and response bridge shadow-field precedence (COMPAT-1). All 32 tests pass. A stable tag has been issued on the provider repository. We welcome any comments on scope, style, or alternative approaches.

---

### Context

We have developed a new provider for Horse, [horse-provider-crosssocket](https://github.com/freitasjca/horse-provider-crosssocket), that replaces the Indy transport layer with [Delphi‑Cross‑Socket](https://github.com/winddriver/Delphi-Cross-Socket). This brings **IOCP/epoll async I/O**, **security hardening** (request smuggling protection, enforced size limits, read timeouts, object pooling, CRLF-stripping on response headers) and **full Linux 64‑bit support** including Docker deployment.

The provider requires patches to Horse itself. **Seventeen existing methods across `THorseRequest` and `THorseResponse` are modified**: each gains a `{$IF DEFINED(HORSE_CROSSSOCKET)}` nil-guard branch that handles the CrossSocket path (where `FWebRequest`/`FWebResponse` are always nil). No existing method is removed, renamed, or given a different signature, and the Indy code path inside each method is unchanged. The full list of modified methods is in the summary table below. **All existing Horse projects, providers, and official middlewares continue to compile and run without any changes**.

---

### Performance characteristics

#### Why CrossSocket is architecturally faster than Indy

The Indy provider that Horse uses by default allocates **one blocking OS thread per connection**. Under concurrent load this creates three well-known bottlenecks:

| Bottleneck | Indy (one thread per connection) | CrossSocket (epoll / IOCP) |
|---|---|---|
| Thread overhead | Each thread consumes ~1–2 MB of stack. 1 000 concurrent connections = ~1–2 GB reserved stack space | Fixed IO thread pool sized once at startup — default `CPUCount*2+1` (logical CPUs): e.g. 9 on a 4-core, 17 on an 8-core. Independent of connection count; overridable via `THorseCrossSocketConfig.IoThreads` |
| Context switching | OS scheduler switches between hundreds or thousands of threads under load, burning CPU cycles that never touch application code | IO threads never block; the kernel notifies them only when data is ready — near-zero idle CPU |
| `accept()` serialisation | Indy calls `accept()` on a single thread, which becomes a bottleneck above ~a few hundred connections/sec | CrossSocket distributes `accept()` across IO threads |
| Memory allocation per request | Default Horse/Indy path allocates a new `THorseRequest` + `THorseResponse` + their dictionaries on every request | Context object pool (`THorseContextPool`) pre-warms 32 contexts and recycles them — the allocator is not invoked on the hot path |
| Keep-alive under load | Each keep-alive connection holds a thread for its entire lifetime, even when idle | Idle keep-alive connections consume no thread — the epoll/IOCP handle is cheap |

These are **structural differences**, not tuning differences. No amount of Indy configuration closes the gap under high concurrency because the thread-per-connection model is the constraint.

#### Measured results

> The figures below are from this repository's own benchmark ladder (`bombardier`, Release builds, one isolated server at a time, identical Horse app + routes per provider). Run on PC1 — 28 logical CPUs, WSL2 / Ubuntu 22 — over loopback. Loopback microbenchmarks exaggerate absolute throughput vs. a real network, but the **relative scaling between providers** is the architectural point. Full data and methodology: `bench/results/bench-analysis-report.md` §7.4–7.5 and the visual summary `bench/results/nodelay-linux-considerations.html`.

**Same Horse app, bare route, all NODELAY-fixed:**

| Concurrency | Horse+Indy | Horse+CrossSocket | Horse+mORMot |
|---|---|---|---|
| **c=100** | 13 736 RPS · P50 6.76 ms | **41 265 RPS · P50 2.19 ms** (≈ 3× Indy) | 68 059 RPS · P50 0.58 ms (≈ 5× Indy) |
| **c=500** | 12 688 RPS · P99 108.8 ms | **108 192 RPS · P99 21.9 ms** (≈ 8.5× Indy) | 144 140 RPS · P99 20.9 ms |

Key observations, all with **0 5xx / 0 errors**:

- **The async advantage widens with concurrency** — exactly what the epoll/IOCP model predicts. CrossSocket goes from ~3× Indy at c=100 to ~8.5× at c=500, because Indy's thread-per-connection model degrades under oversubscription while the fixed IO-thread pool does not.
- **Tail latency is the sharpest difference:** at c=500 CrossSocket's P99 is **21.9 ms vs. Indy's 108.8 ms** (~5× better) — the practical impact of not allocating a thread per connection.
- Indy stays *error-free* at c=500 only after raising `MaxConnections`/`ListenQueue` (now the library default); CrossSocket needs no such tuning to stay clean.

These results are consistent with general async-vs-thread-per-connection benchmarks (nginx / Go `net/http` / Node.js vs. Apache prefork) and the [C10K problem literature](http://www.kegel.com/c10k.html). A separate cross-OS finding: on the same box, **mORMot ran ≈ 9× its Windows throughput on Linux** (§7.5) — a reminder that absolute numbers are platform-bound while the provider ordering holds.

#### What the CrossSocket provider adds on top

Beyond the transport layer, this provider contributes additional performance work that is independent of CrossSocket itself:

- **Object pool** (`THorseContextPool`) — 32 pre-warmed `THorseRequest`/`THorseResponse` pairs recycled via `Clear` instead of `Free`/`Create`. Pool capacity scales to 512 under burst load. The allocator is bypassed entirely on the hot path.
- **Worker thread pool** (`THorseWorkerPool`) — 4 to 64 threads for CPU-bound route handlers, preventing any single slow handler from blocking an IO thread and stalling unrelated connections.
- **Pre-validation before pool acquisition** — malformed requests (bad Host, smuggling attempt, disallowed method) are rejected before a context object is even taken from the pool, so attack traffic never touches the application layer.
- **`TCP_NODELAY` on every accepted connection** — the server's `OnConnected` hook disables Nagle (`TSocketAPI.SetTcpNoDelay`). Without it, on Linux loopback the keep-alive request/response ping-pong stalls on the kernel's ~40 ms delayed-ACK timer (a flat ~44 ms/request floor); with it, latency is determined by the handler, not the TCP stack. Matches nginx/Go/mORMot defaults; CrossSocket sets `SO_KEEPALIVE` on accept but not `TCP_NODELAY`, so the provider adds it.

#### When CrossSocket is the right choice

| Scenario | Recommendation |
|---|---|
| REST API with many concurrent clients | ✅ CrossSocket — thread-per-connection does not scale |
| Long-polling or SSE (many idle open connections) | ✅ CrossSocket — idle connections are free |
| High-throughput microservice in Docker / Linux | ✅ CrossSocket — epoll is the native Linux async primitive |
| Low-concurrency internal tooling (< 50 simultaneous users) | Either — Indy is simpler and the performance difference is imperceptible |
| IIS / Apache / CGI deployment | ❌ CrossSocket — architecturally incompatible (see below) |

---

### How to activate the provider

The CrossSocket provider is selected at compile time via a project‑level conditional define. **No code changes are needed in the application itself** beyond registering routes and calling `Listen`.

#### Step 1 — Set the define

In **Project Options → Delphi Compiler → Conditional defines** (or the equivalent in Lazarus / FPC project settings), add:

```
HORSE_CROSSSOCKET
```

> ⚠️ `HORSE_CROSSSOCKET` must be the **only active provider define** and is **architecturally incompatible** with `HORSE_ISAPI`, `HORSE_APACHE`, `HORSE_CGI`, and `HORSE_FCGI`. See [Architectural incompatibility with host-managed providers](#architectural-incompatibility-with-host-managed-providers) below. Do not combine it with `HORSE_DAEMON` or `HORSE_VCL` either — those defines are checked before `HORSE_CROSSSOCKET` in the `THorseProvider` type alias chain inside `Horse.pas` and will silently take precedence.

#### Step 2 — Minimal application code

```delphi
program MyServer;

{$APPTYPE CONSOLE}

uses
  Horse,
  Horse.Provider.Config;

begin
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('pong');
    end);

  // Simple start on port 8080 with all defaults
  THorse.Listen(8080);
end.
```

For advanced configuration (TLS, body size limits, compression):

```delphi
var
  Config: THorseCrossSocketConfig;
begin
  Config              := THorseCrossSocketConfig.Default;
  Config.MaxBodySize  := 8388608;    // 8 MB
  Config.Compressible := True;       // enable gzip for compressible responses
  Config.SSLEnabled   := True;
  Config.SSLCertFile  := '/app/certs/server.crt';
  Config.SSLKeyFile   := '/app/certs/server.key';

  // ReadTimeout and KeepAliveTimeout fields exist in the record but are
  // currently reserved — CrossSocket does not yet expose these as server-
  // level properties.  Set them now; they will activate automatically once
  // the underlying API is available.

  THorse.ListenWithConfig(443, Config);
end.
```

---

### Architectural incompatibility with host-managed providers

`HORSE_CROSSSOCKET` **cannot coexist with `HORSE_ISAPI`, `HORSE_APACHE`, `HORSE_CGI`, or `HORSE_FCGI`**, and this is not merely a define-ordering problem that could be fixed by reordering the `{$ELSEIF}` chain. The incompatibility is architectural and fundamental to how each deployment model owns the network socket.

#### The core conflict: who owns the listening socket?

CrossSocket is a **self-hosted transport**. When `THorse.Listen` or `THorse.ListenWithConfig` is called, CrossSocket calls `bind()` + `listen()` on a raw OS socket and drives all I/O through its own epoll (Linux) or IOCP (Windows) event loop. The process **owns** the socket for its entire lifetime.

ISAPI, Apache modules, CGI, and FastCGI operate under a fundamentally different contract: the **host process** (IIS, Apache httpd, the CGI caller) owns the socket, accepts the connection, reads the raw HTTP bytes, and hands a pre-parsed `TWebRequest` to the Delphi code. The Delphi process never sees a socket file descriptor at all.

These two models are mutually exclusive at the OS level:

| | CrossSocket | ISAPI / Apache / CGI / FCGI |
|---|---|---|
| Socket ownership | Delphi process via `bind()` + `listen()` | Host process (IIS / httpd / caller) |
| I/O model | epoll / IOCP event loop — fully async | Synchronous: host reads request, calls handler, reads response |
| Entry point | `main()` — long-running process | DLL export (`HttpExtensionProc`) or short-lived process |
| `TWebRequest` available | Never — socket buffer only | Always — host has already parsed headers |
| `TCrossHttpServer.Start()` | Meaningful — binds the port | Meaningless — there is no port to bind |

#### Compile-time guard against incompatible define combinations (PATCH-HORSE-1)

The patched `Horse.pas` (PATCH-HORSE-1) adds `{$MESSAGE FATAL}` guards that fire a hard compile error whenever `HORSE_CROSSSOCKET` is combined with any define that would silently take precedence over it:

```pascal
{$IF DEFINED(HORSE_CROSSSOCKET)}
  {$IF DEFINED(HORSE_ISAPI)}
    {$MESSAGE FATAL 'HORSE_CROSSSOCKET is incompatible with HORSE_ISAPI — remove one define. ...'}
  {$ENDIF}
  // ... repeated for HORSE_APACHE, HORSE_CGI, HORSE_FCGI,
  //     HORSE_DAEMON, HORSE_LCL, HORSE_VCL, HORSE_NOPROVIDER
{$ENDIF}
```

Each message names both conflicting defines and explains the architectural reason. The guard block is inside `{$IF DEFINED(HORSE_CROSSSOCKET)}` so it compiles away entirely for Indy projects. Without this guard, a misconfigured project compiles cleanly but runs the wrong provider with no diagnostic.

#### Define-namespace normalisation and cross-product Provider × Application-type units (PATCH-HORSE-2)

PATCH-HORSE-2 reorganises the Horse compile-time configuration into **three orthogonal axes** with explicit namespaces, and ships five new convenience units so every architecturally-compatible Provider × Application-type combination becomes expressible.

**Three define namespaces:**

| Axis | Prefix | Examples |
|---|---|---|
| A · Provider (transport library) | `HORSE_PROVIDER_*` | `HORSE_PROVIDER_CROSSSOCKET` (mORMot reserved) |
| B · Application type (binary shape) | `HORSE_APPTYPE_*` | `HORSE_APPTYPE_VCL`, `HORSE_APPTYPE_DAEMON`, `HORSE_APPTYPE_LCL` |
| C · Host-managed runtime | `HORSE_HOST_*` | `HORSE_HOST_APACHE`, `HORSE_HOST_ISAPI`, `HORSE_HOST_CGI`, `HORSE_HOST_FCGI` |

Axis C wins outright when set (no Provider involved). Axes A and B compose freely, subject to platform support (VCL is Delphi-only; LCL is FPC-only).

**Legacy aliases preserve every existing project.** An alias block at the top of `Horse.pas` translates each old define to its new namespaced counterpart, so `.dproj` / `.lpi` files setting `HORSE_CROSSSOCKET`, `HORSE_VCL`, `HORSE_DAEMON`, `HORSE_LCL`, `HORSE_APACHE`, `HORSE_ISAPI`, `HORSE_CGI`, `HORSE_FCGI` continue to compile unchanged.

**PATCH-HORSE-1 narrows accordingly.** It now fails compilation only for combinations that are genuinely impossible:

| Forbidden combination | Reason |
|---|---|
| `HORSE_PROVIDER_*` + any `HORSE_HOST_*` | Host owns the socket; self-hosted transport cannot coexist |
| `HORSE_APPTYPE_VCL` + FPC | VCL is Delphi-only; suggests `HORSE_APPTYPE_LCL` |
| `HORSE_APPTYPE_LCL` + non-FPC | LCL is FPC/Lazarus-only; suggests `HORSE_APPTYPE_VCL` |
| `HORSE_HOST_ISAPI` + FPC | ISAPI requires Delphi |
| `HORSE_NOPROVIDER` + anything else | The escape hatch is mutually exclusive |

Combinations previously flagged as fatal (e.g. `HORSE_CROSSSOCKET` + `HORSE_VCL`) now compile and resolve to the new cross-product units below.

**Five new cross-product Provider units** (in `horse-provider-crosssocket/src/`, all inheriting from `THorseProviderCrossSocket` so they reuse the entire transport / pool / bridge infrastructure):

| Unit | Selected by | Convenience class |
|---|---|---|
| `Horse.Provider.CrossSocket.VCL` | `HORSE_PROVIDER_CROSSSOCKET` + `HORSE_APPTYPE_VCL` | `TfrmHorseVCLHost` — VCL form base with `Port` + auto-wired `FormCreate`/`FormClose` |
| `Horse.Provider.CrossSocket.Daemon` | `HORSE_PROVIDER_CROSSSOCKET` + `HORSE_APPTYPE_DAEMON` (Delphi — cross-platform) | `THorseCrossSocketService` *(MSWINDOWS — TService base with worker-thread `Listen` + drain on `ServiceStop`)* &nbsp;OR&nbsp; `THorseCrossSocketLinuxDaemonApp.Run` *(non-Windows — POSIX SIGTERM/SIGINT handlers + blocking `Listen`)*. Picked by `{$IFDEF MSWINDOWS}` inside the unit — same defines select the right helper per build target. |
| `Horse.Provider.CrossSocket.FPC.Daemon` | `HORSE_PROVIDER_CROSSSOCKET` + `HORSE_APPTYPE_DAEMON` (FPC) | `THorseCrossSocketDaemonApp.Run` — installs `fpSignal(SIGTERM/SIGINT)` + blocks on `Listen` |
| `Horse.Provider.CrossSocket.FPC.LCL` | `HORSE_PROVIDER_CROSSSOCKET` + `HORSE_APPTYPE_LCL` | `TfrmHorseLCLHost` — Lazarus mirror of the VCL form base |
| `Horse.Provider.CrossSocket.FPC.HTTPApplication` | (referenced explicitly when desired) | `THorseCrossSocketHTTPApp.Run` — alias of Daemon runner for projects organised around HTTPApplication vocabulary |

Each new unit is small (~80–150 lines) because they delegate all transport behaviour to the existing `Horse.Provider.CrossSocket`. They add only the shape-specific lifecycle wiring that users previously wrote by hand following the recipes in `doc/providers.md §8`.

The selection happens in a two-stage `{$IFDEF}` chain in `Horse.pas`:

1. **Stage 1 — Axis C wins outright.** Any `HORSE_HOST_*` define selects the host-managed provider, ignoring Axes A and B.
2. **Stage 2 — Axis A × Axis B compose.** When `HORSE_PROVIDER_CROSSSOCKET` is set, the `HORSE_APPTYPE_*` define picks the matching cross-product unit (or the existing console-shape unit if no `HORSE_APPTYPE_*` is set). When `HORSE_PROVIDER_CROSSSOCKET` is *not* set, the default Provider (Indy on Delphi, `fphttpserver` on FPC) is used, and `HORSE_APPTYPE_*` selects from the Indy-side units already in Horse.

The `boss.json` version of `horse-provider-crosssocket` is bumped to `1.0.5` and requires `horse >= 3.1.98` (the release that ships PATCH-HORSE-2). Existing consumers pinned to `1.0.4` continue working without picking up the new units; consumers that bump get the cross-product units automatically via Boss.

#### What CrossSocket replaces vs. what it cannot replace

| Deployment model | Replace with CrossSocket? | Notes |
|---|---|---|
| Console / long-running service (Indy) | ✅ Direct replacement | CrossSocket is a faster, async-native drop-in |
| Linux daemon | ✅ Primary use case | epoll; deploy in Docker or as a systemd service |
| Windows service (`HORSE_DAEMON`) | ✅ Compatible | CrossSocket runs; combine with a Windows service wrapper |
| VCL app embedding a server | ✅ Compatible | CrossSocket runs on a background thread; VCL main thread unaffected |
| IIS via ISAPI DLL | ❌ Incompatible | IIS owns the socket; CrossSocket cannot bind |
| Apache httpd module | ❌ Incompatible | Apache owns the socket; CrossSocket cannot bind |
| CGI / FastCGI | ❌ Incompatible | No persistent process; CrossSocket's event loop never runs |

---

### Required search paths when using Boss

Each repository ships a `boss.json` that tells Boss which paths to expose. Boss distinguishes between two path fields:

| Field | What Boss does with it |
|---|---|
| `mainsrc` | Added to the **compiler Search Path** in your `.dproj` — units here are resolved by `uses` clauses at build time |
| `browsingpath` | Added to the **IDE Browsing Path** — used for code completion and Find Declaration navigation |

The three repositories declare the following:

**`horse-provider-crosssocket`** (`boss.json`):
```json
"mainsrc":     "src/",
"browsingpath": "src/;modules/Delphi-Cross-Socket/CnPack/Common;modules/Delphi-Cross-Socket/CnPack/Crypto"
```

**`delphi-cross-socket`** (freitasjca fork — `boss.json`):
```json
"mainsrc":     "Net/",
"browsingpath": "Net/;Utils/;CnPack/Common/;CnPack/Crypto/"
```

**`horse`** (freitasjca fork): `mainsrc: "src/"`.

Resolving against the standard Boss `modules\` layout at the project root, the union of paths visible after `boss install` is:

| Path | Source | Visibility |
|---|---|---|
| `modules\horse\src` | `horse.mainsrc` | Compiler + IDE |
| `modules\horse-provider-crosssocket\src` | `horse-provider-crosssocket.mainsrc` | Compiler + IDE |
| `modules\Delphi-Cross-Socket\Net` | `delphi-cross-socket.mainsrc` | Compiler + IDE |
| `modules\Delphi-Cross-Socket\Utils` | `delphi-cross-socket.browsingpath` | IDE only |
| `modules\Delphi-Cross-Socket\CnPack\Common` | both browsingpaths | IDE only |
| `modules\Delphi-Cross-Socket\CnPack\Crypto` | both browsingpaths | IDE only |

The CnPack paths are declared in `browsingpath` rather than `mainsrc` because only a small subset of the OpenSSL/HTTP-2 code in CrossSocket pulls them in. Projects that build a non-TLS profile (or a profile that excludes the CnPack-dependent units) do not need the compiler to walk those directories. Projects that *do* hit CnPack at compile time should mirror the same two CnPack directories into their own `.dproj` Search Path — most concrete sample projects in `horse-provider-crosssocket/samples/` already do.


---

### Changes overview

All modifications are in separate commits and are fully backward‑compatible. Detailed rationale and full code is in the [provider's README](https://github.com/freitasjca/horse-provider-crosssocket#required-changes-to-horse-source).

#### 1. `Horse.Request.pas`

- **Parameterless constructor** `THorseRequest.Create` – allows the context pool to pre‑allocate request objects at startup before any real request arrives. The existing constructor that accepts a `TWebRequest` is completely unchanged.
- **`Clear` procedure** (PATCH-REQ-2) – fast field‑wipe for object reuse between requests (zero‑allocation hot path). Sets `FBody`, `FWebRequest`, `FSession` to `nil`, wipes the CrossSocket shadow fields (`FCSMethod`, `FCSMethodType`, `FCSPathInfo`, `FCSContentType`, `FCSRemoteAddr`, `FBodyString`), frees the per-request `FCSRawWebRequest` adapter, clears the param-collection dictionaries in place (`FHeaders`, `FParams`) or rebuilds them lazily (`FQuery`, `FContentFields`, `FCookie`), and calls `FSessions.Clear` rather than `FreeAndNil` so the `THorseSessions` instance is reused across pool recycles (PATCH-SES-1 — see `Horse.Session.pas`).  
  ⚠️ `FBody` is a **non‑owning reference** into the CrossSocket receive buffer and is **never freed** by `Clear`.
- **`Populate` procedure** (PATCH-REQ-3) – injects per‑request shadow fields (method, method type, path, content‑type, remote address) directly, bypassing the `FWebRequest` delegation that would crash when `FWebRequest` is `nil`.
- **`PopulateCookiesFromHeader` procedure** (PATCH-REQ-4) – parses the raw `Cookie` request header into the `THorseRequest.Cookie` collection without requiring a live `TWebRequest`. Kept for any future provider whose transport does not pre-parse cookies; the CrossSocket bridge itself uses CrossSocket's already-parsed `TRequestCookies` collection instead and so does not invoke this method.
- **Nil-guard branches added to 9 existing accessors** (`Body`, `Host`, `MethodType`, `PathInfo`, `ContentType`, `InitializeQuery`, `InitializeCookie`, `InitializeContentFields`, `Headers`) so each method returns the corresponding shadow field when `FWebRequest = nil`. The Indy code path inside each method is byte-for-byte identical to the upstream.

#### 2. `Horse.Response.pas`

- **`CustomHeaders` property** (PATCH-RES-3) – read‑only exposure of the internal `FCustomHeaders` store, allowing the response bridge to iterate all application‑set headers in a single pass for efficient forwarding.
- **`ContentStream` property** (PATCH-RES-4) – read-only accessor that exposes the `FCSContentStream` shadow field, supporting zero‑copy stream responses (large files, generated content) without intermediate string copies.
- **`BodyText` property** (PATCH-RES-4) – exposes the shadow string body field (`FCSBody`) set when `FWebResponse` is `nil`.
- **`CSContentType` property** (PATCH-RES-4) – exposes the shadow content‑type field (`FCSContentType`) for the same reason.
- **`Clear` procedure** (PATCH-RES-2) – resets the shadow fields to their defaults (`FCSStatusCode := 200`, `FCSBody := ''`, `FCSContentType := ''`, `FCSContentStream := nil`), clears `FCustomHeaders` in place (the dictionary object is reused — no heap churn), frees the per-request `FCSRawWebResponse` adapter, sets `FWebResponse := nil`, and resets `FContent` — mirroring the request-side pooling contract.
- **`SetCSRawWebResponse` procedure** (PATCH-RES-6) – assigns a `TWebResponse` adapter so `RawWebResponse` returns a non‑nil object for middleware that calls `Res.RawWebResponse.SetCustomHeader` (e.g. Horse.CORS). Ownership transfers to `THorseResponse`; freed by `Clear` on pool release.
- **`EnsureCustomHeaders` private helper** (PATCH-RES-7) – lazy allocator for `FCustomHeaders`. The dictionary (Delphi) or string-list (FPC) is no longer created in the constructor; instead `AddHeader` calls `EnsureCustomHeaders` on first use, so any Indy/ISAPI/CGI request that never calls `AddHeader` pays zero allocation cost for this field.
- **Nil-guard branches added to 8 existing setters** (`Send`, `Status`, `ContentType`, `AddHeader`, `RemoveHeader`, `RedirectTo`, `SendFile`, `Download`) so each method writes to the corresponding shadow field when `FWebResponse = nil`. The Indy code path inside each method is byte-for-byte identical to the upstream.
- **Known limitation:** `FCustomHeaders` is a `TDictionary<string,string>` (Delphi) / `TStringList` (FPC), which stores one value per key. Multiple `AddHeader('Set-Cookie', ...)` calls will keep only the last value. Applications requiring multiple cookies in one response should compose them into a single header value for now.

#### 3. `Horse.Provider.Abstract.pas`

- **`ListenWithConfig` virtual class method** – a new virtual method that accepts a `THorseCrossSocketConfig` record (timeouts, size limits, SSL/mTLS settings, IO thread count, etc.). The base implementation raises an exception so that any concrete provider which forgets to override it is caught immediately at runtime rather than silently using the wrong port. All existing concrete providers (Console, VCL, Daemon, FPC.*) already override `ListenWithConfig` and call `SetPort(APort)` before their own `Listen` — they are completely unaffected.
- **`Execute` virtual class method** – runs the Horse middleware + route pipeline for a given `THorseRequest` / `THorseResponse` pair, allowing providers that bypass `TWebRequest` to invoke the full Horse pipeline. The base implementation calls `Routes.Execute(ARequest, AResponse)`.

No `Port` class property is added to the abstract base. The submitted file contains a code comment explaining why: in Delphi, `class var` in a subclass is a completely independent memory location from the parent class, so a shared `FPort` in the abstract base would cause silent port-not-changing bugs. Each concrete provider declares its own `FPort` and `Port` independently.

#### 4. New units `Horse.Provider.RawInterfaces.pas` and `Horse.Provider.RawAdapters.pas`

- **`IHorseRawRequest`** (~15 methods) and **`IHorseRawResponse`** (~1 method) — lightweight interfaces capturing the subset of `TWebRequest`/`TWebResponse` that middleware actually uses.
- **`TInterfacedWebRequest`** and **`TInterfacedWebResponse`** — generic `TWebRequest`/`TWebResponse` subclasses that delegate all 30+ abstract method stubs to the interfaces. New providers implement the small interface and get full `TWebRequest`/`TWebResponse` compatibility for free — no boilerplate duplication.
- **Compiler-version guard:** `GetIntegerVariable`/`SetIntegerVariable` return `Int64` on Delphi 10.2+ and `Integer` on XE7/FPC, controlled by `{$IF CompilerVersion >= 32.0}`.

#### 5. New unit `Horse.Provider.Config.pas`

- Defines `THorseCrossSocketConfig` – a `record` holding all configurable server settings: IO thread count, keep‑alive and read timeouts (reserved for future use), graceful‑drain timeout, header and body size limits, connection ceiling (reserved), compression settings, SSL/TLS certificate paths, mTLS CA certificate and peer‑verify flag, cipher list, and server banner suppression.
- Placed in its own file to **avoid circular unit references** between `Horse.Provider.Abstract` and `Horse.Provider.CrossSocket`.
- Ships safe defaults aligned with common web server conventions (8 KB header limit, 4 MB body limit, `Server:` header suppressed).
- Fields `IoThreads`, `Compressible`, `MinCompressSize`, and all SSL fields are active today. Fields `KeepAliveTimeout`, `ReadTimeout`, `MaxConnections`, and `SSLKeyPassword` are reserved — they are present in the record and populated by `Default` so applications can set them now, but CrossSocket does not yet expose the corresponding server‑level API.

---

### Why these changes are necessary

- The CrossSocket provider drives I/O directly through epoll (Linux) or IOCP (Windows) and never creates a `TWebRequest` or `TWebResponse`. The parameterless constructor and `Clear` methods allow request/response objects to be reused from a pre‑allocated pool without the allocator being invoked on the hot path.
- `CustomHeaders` is the only way to read back headers previously set via the existing `AddHeader` method. Exposing it as a read‑only property enables the response bridge to forward all custom headers in one dictionary iteration.
- `ListenWithConfig` gives the provider a structured way to pass rich server configuration (timeouts, SSL, connection limits) without altering the existing zero‑argument `Listen` signature that all current providers use.
- `Horse.Provider.Config` must be a standalone unit because both `Horse.Provider.Abstract` (which declares `ListenWithConfig`) and `Horse.Provider.CrossSocket` (which implements it) need the `THorseCrossSocketConfig` type — placing it in either file creates a circular dependency.

---

### Note on Dependencies

The [Delphi‑Cross‑Socket](https://github.com/winddriver/Delphi-Cross-Socket) library, which this provider relies on, currently requires some maintenance to be fully compatible with the Boss package manager. The repository maintainer will need to:

1. Add a `boss.json` file to the root of the repository.
2. Create a version tag (e.g., `v1.0.0`) so that Boss can resolve and pin the dependency correctly.
3. Bundle or declare dependencies on the **CnPack** cryptographic library. The required files are:

   | Path | Purpose |
   |---|---|
   | `CnPack\Common\CnPack.inc` | Compiler switches shared by all CnPack units |
   | `CnPack\Crypto\CnNative.pas` | Low‑level integer / byte helpers |
   | `CnPack\Crypto\CnConsts.pas` | Shared constants |
   | `CnPack\Crypto\CnMD5.pas` | MD5 hash |
   | `CnPack\Crypto\CnSHA1.pas` | SHA‑1 hash |
   | `CnPack\Crypto\CnSHA2.pas` | SHA‑256 / SHA‑512 |
   | `CnPack\Crypto\CnSHA3.pas` | SHA‑3 / Keccak |
   | `CnPack\Crypto\CnSM3.pas` | SM3 (Chinese national standard) |
   | `CnPack\Crypto\CnAES.pas` | AES block cipher |
   | `CnPack\Crypto\CnDES.pas` | DES / 3DES |
   | `CnPack\Crypto\CnBase64.pas` | Base64 codec |
   | `CnPack\Crypto\CnKDF.pas` | Key derivation functions |
   | `CnPack\Crypto\CnRandom.pas` | Cryptographically secure RNG |
   | `CnPack\Crypto\CnPemUtils.pas` | PEM encoding / decoding |
   | `CnPack\Crypto\CnFloat.pas` | Floating‑point helpers used by cipher code |

**Current install model** — `horse-provider-crosssocket` no longer pulls Delphi-Cross-Socket through Boss. Delphi-Cross-Socket is installed manually (clone the upstream repo, add search paths), the same way `horse-provider-mormot` documents the mORMot2 install. CnPack is fetched separately from [`cnpack/cnvcl`](https://github.com/cnpack/cnvcl) (or, for the cherry-pick variant, just the 15 files listed above). This matches the convention already used for mORMot2 in `horse-provider-mormot`.

**Why the manual path now?** The upstream `winddriver/Delphi-Cross-Socket` is actively maintained and changes frequently. A Boss-installable wrapper inevitably drifts behind upstream between fork syncs, and three previously fork-only bug fixes (`PATCH-IOCP-1` shutdown cascade, the `TCrossHttpClient` zero-body parser hang, and the `_OnBodyEnd` nil-guard) have already been merged into upstream as of 2026-Q2 — they no longer justify maintaining a fork as the default install target. The community fork ([github.com/freitasjca/Delphi-Cross-Socket](https://github.com/freitasjca/Delphi-Cross-Socket)) remains a **supported alternative** for users who need mTLS server-mode APIs (`SetCACertificate(File)` + `SetVerifyPeer(Boolean)`, shipped pre-applied in fork release `v1.0.3`) or prefer one fewer clone, with the explicit trade-off that the fork lags upstream commits between syncs.

The ideal long-term outcome is for the **original repository** to merge an upstream PR with the mTLS additions, after which the fork's only remaining differentiator (bundled CnPack convenience) becomes a much smaller value proposition. An upstream mTLS PR is in preparation.

---

### Testing and verification

**Automated integration test suite — 32 tests, all passing (Delphi 12 Athens, Win64 Release):**
- HTTP methods: GET, POST, PUT, DELETE, PATCH, HEAD
- Routing: single path parameter, two path parameters in one pattern, query string parsing
- Cookies: `Set-Cookie` response headers, `Cookie` request header echo
- Body: JSON echo, multipart file upload, file download, custom request header echo
- Error paths: 404, explicit 4xx/5xx status codes with JSON body
- Response integrity: `Content-Type` header, 65 536-byte large response without truncation
- **Pool regression suite** (guard for FIX-POOL-1): nil-body POST, 64 KB body, sequential body isolation, 4 concurrent POST requests with unique body markers
- **RawWebRequest adapter** (PATCH-REQ-8): verifies method, host, pathInfo, headers, remoteAddr via `Req.RawWebRequest`
- **CORS compatibility:** `OPTIONS` preflight returns 204 + `Access-Control-Allow-Origin`; `GET` returns route body (Horse.CORS integration)
- **PATCH-REQ-9 double-read:** `Req.Body` called twice returns identical cached string (`"equal":true`)
- **COMPAT-1 shadow-field precedence:** `Res.RawWebResponse.Content` written before `Res.Send` — shadow field wins, no response corruption

**Also completed:**
- Official middleware compatibility — no middleware source changes required:
  - **`horse-cors`**: confirmed working — `Req.RawWebRequest.Method` works via PATCH-REQ-8 adapter; `Res.RawWebResponse.SetCustomHeader` works via PATCH-RES-6 adapter (inherited `TWebResponse.CustomHeaders` is merged into the response by `TResponseBridge.CopyHeaders`); CORS preflight included in the 32-test suite.
  - **`horse-jhonson`**: works via `Res.Send` / `Res.ContentType`, which is the path the upstream code already uses. The `[COMPAT-1]` fallback in `TResponseBridge.Flush` / `WriteBody` additionally reads `Res.RawWebResponse.Content` / `.ContentType` when the shadow fields are empty — fully active on FPC (where `TInterfacedWebResponse` inherits `TResponse` without stubbing `Content`), dormant on Delphi (where `TInterfacedWebResponse.SetContent` is a stub, so writes via `Res.RawWebResponse.Content := X` are dropped). Nothing in the official `horse-jhonson` source path depends on the dormant Delphi case; extending the Delphi adapter to capture `SetContent` is tracked as an enhancement.
  - **`horse-jwt`**, **`horse-logger`**, **`horse-basic-authenticator`**: these middlewares operate on `THorseRequest`/`THorseResponse` public API only (`Req.Headers`, `Req.Body`, `Res.Send`, `Res.Status`) — all nil-guarded via PATCH-REQ/RES shadow fields; no compatibility issues identified.
- All Horse patches compile cleanly against Horse 3.x on Delphi 10.4 Sydney, 11 Alexandria, and 12 Athens with both `Win64` and `Linux64` targets.
- Graceful shutdown drain (in‑flight request counter, `DrainTimeoutMs`) verified under load.
- Docker deployment on Ubuntu 22.04 via WSL 2 verified.

**Planned before final merge:**
- Load testing (wrk/k6) to replace the indicative throughput figures with measured results.
- FPC / Lazarus runtime testing on FPC 3.3.1 (compilation verified; end-to-end runtime test pending).
- TLS handshake and mTLS end-to-end verification.

---

### Summary of files changed in Horse

| File | Change type | Description |
|---|---|---|
| `Horse.pas` | Modified | Added `HORSE_CROSSSOCKET` conditional branch in `uses` and `THorseProvider` alias; added PATCH-HORSE-1: `{$MESSAGE FATAL}` guard block that fires a compile error when `HORSE_CROSSSOCKET` is combined with any incompatible define. **PATCH-HORSE-2** further reorganises the chain into three orthogonal namespaces (`HORSE_PROVIDER_*` / `HORSE_APPTYPE_*` / `HORSE_HOST_*`) with a legacy-alias block for full backwards compatibility, narrows PATCH-HORSE-1 to only architecturally-impossible combinations, and wires the new cross-product CrossSocket × Application-type units into the chain |
| `Horse.Request.pas` | Modified | Added parameterless constructor, `Clear`, `Populate`, `PopulateCookiesFromHeader`, shadow fields; nil-guards added to `Body`, `Host`, `MethodType`, `PathInfo`, `ContentType`, `InitializeQuery`, `InitializeCookie`, `InitializeContentFields`, `Headers`; added `FBodyString` + `SetBodyString` + `Body: string` nil-guard (PATCH-REQ-9); added `Method: string` accessor (PATCH-REQ-10) |
| `Horse.Response.pas` | Modified | Added `CustomHeaders`, `ContentStream`, `BodyText`, `CSContentType`, `Clear`, `SetCSRawWebResponse`, shadow fields; nil-guards added to `Send`, `Status`, `ContentType`, `AddHeader`, `RemoveHeader`, `RedirectTo`, `SendFile`, `Download` |
| `Horse.Provider.Abstract.pas` | Modified | Added `ListenWithConfig`, `Execute`; added `MaxConnections` no-op property raised to abstract base (PATCH-ABS-4) for source compatibility when switching to `HORSE_CROSSSOCKET` |
| `Horse.Session.pas` | Modified | Added `Clear` procedure (PATCH-SES-1): in-place wipe of `FSessions` dictionary for pool reuse — no allocation on hot path |
| `Horse.Provider.Config.pas` | **New file** | `THorseCrossSocketConfig` record with safe defaults |
| `Horse.Provider.RawInterfaces.pas` | **New file** | `IHorseRawRequest` + `IHorseRawResponse` interfaces |
| `Horse.Provider.RawAdapters.pas` | **New file** | `TInterfacedWebRequest` / `TInterfacedWebResponse` generic adapters |

---

We would be very happy to discuss any aspect of these changes, adjust scope, or split into smaller PRs if preferred. Thank you for maintaining such a fantastic framework!
