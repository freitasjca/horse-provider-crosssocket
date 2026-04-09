## Additive changes to support CrossSocket high‑performance provider

> ⚠️ **Beta status** – This provider and the accompanying Horse patches are currently under active testing. They are not yet production‑hardened for all deployment scenarios. We are sharing them now to gather feedback from the community and to start the review process early. Please do not merge until the test suite is complete and a stable tag has been issued on the provider repository.

---

### Context

We have developed a new provider for Horse, [horse-provider-crosssocket](https://github.com/freitasjca/horse-provider-crosssocket), that replaces the Indy transport layer with [Delphi‑Cross‑Socket](https://github.com/winddriver/Delphi-Cross-Socket). This brings **IOCP/epoll async I/O**, **security hardening** (request smuggling protection, enforced size limits, read timeouts, object pooling, CRLF-stripping on response headers) and **full Linux 64‑bit support** including Docker deployment.

The provider requires four **strictly additive** patches to Horse itself. No existing method is altered or removed, so **all existing Horse projects, providers, and official middlewares continue to compile and run without any changes**.

---

### Performance characteristics

#### Why CrossSocket is architecturally faster than Indy

The Indy provider that Horse uses by default allocates **one blocking OS thread per connection**. Under concurrent load this creates three well-known bottlenecks:

| Bottleneck | Indy (one thread per connection) | CrossSocket (epoll / IOCP) |
|---|---|---|
| Thread overhead | Each thread consumes ~1–2 MB of stack. 1 000 concurrent connections = ~1–2 GB reserved stack space | Fixed IO thread count — default is CPU core count, typically 4–16 threads regardless of connection count |
| Context switching | OS scheduler switches between hundreds or thousands of threads under load, burning CPU cycles that never touch application code | IO threads never block; the kernel notifies them only when data is ready — near-zero idle CPU |
| `accept()` serialisation | Indy calls `accept()` on a single thread, which becomes a bottleneck above ~a few hundred connections/sec | CrossSocket distributes `accept()` across IO threads |
| Memory allocation per request | Default Horse/Indy path allocates a new `THorseRequest` + `THorseResponse` + their dictionaries on every request | Context object pool (`THorseContextPool`) pre-warms 32 contexts and recycles them — the allocator is not invoked on the hot path |
| Keep-alive under load | Each keep-alive connection holds a thread for its entire lifetime, even when idle | Idle keep-alive connections consume no thread — the epoll/IOCP handle is cheap |

These are **structural differences**, not tuning differences. No amount of Indy configuration closes the gap under high concurrency because the thread-per-connection model is the constraint.

#### Indicative numbers from the community

> ⚠️ The figures below are drawn from community reports and general benchmarks of epoll-based vs. thread-per-connection HTTP servers. **Our own load-testing suite is still in progress** (see Testing and verification). We will replace this section with measured results from our own test harness before requesting final merge.

General async I/O HTTP servers (nginx, Go `net/http`, Node.js) consistently outperform thread-per-connection servers (classic Apache prefork, Indy-based servers) by **3× to 10× on throughput** and **10× to 50× on peak concurrent connections** at equivalent hardware, according to published benchmarks and the [C10K problem literature](http://www.kegel.com/c10k.html).

For Delphi specifically, the Delphi-Cross-Socket library author and community members report:

- Handling **10 000+ concurrent keep-alive connections** on a single modest server that would exhaust Indy's thread pool well below 1 000.
- **Sub-millisecond** median response latency on simple routes (comparable to nginx for static content) vs. multi-millisecond latency under Indy at the same concurrency due to scheduler pressure.

These figures are consistent with what the epoll/IOCP architecture predicts and with results from equivalent libraries in other languages (libuv, Boost.Asio, netty).

#### What the CrossSocket provider adds on top

Beyond the transport layer, this provider contributes additional performance work that is independent of CrossSocket itself:

- **Object pool** (`THorseContextPool`) — 32 pre-warmed `THorseRequest`/`THorseResponse` pairs recycled via `Clear` instead of `Free`/`Create`. Pool capacity scales to 512 under burst load. The allocator is bypassed entirely on the hot path.
- **Worker thread pool** (`THorseWorkerPool`) — 4 to 64 threads for CPU-bound route handlers, preventing any single slow handler from blocking an IO thread and stalling unrelated connections.
- **Pre-validation before pool acquisition** — malformed requests (bad Host, smuggling attempt, disallowed method) are rejected before a context object is even taken from the pool, so attack traffic never touches the application layer.
- **`TDictionary`-backed headers** — header lookup is O(1) vs. the O(n) linear scan of `TStringList` used in the default Horse path.

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

For advanced configuration (timeouts, SSL, worker pool, body size limits):

```delphi
var
  Config: THorseCrossSocketConfig;
begin
  Config                  := THorseCrossSocketConfig.Default;
  Config.ReadTimeout      := 20;          // seconds – Slowloris mitigation
  Config.KeepAliveTimeout := 30;          // seconds
  Config.MaxBodySize      := 8388608;     // 8 MB
  Config.SSLEnabled       := True;
  Config.SSLCertFile      := '/app/certs/server.crt';
  Config.SSLKeyFile       := '/app/certs/server.key';

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

#### Why a compile-time error would be better than silent wrong behaviour

The current `Horse.pas` conditional chain checks `HORSE_ISAPI`, `HORSE_APACHE`, `HORSE_CGI`, and `HORSE_FCGI` **before** `HORSE_CROSSSOCKET` in the `THorseProvider` type alias block. If a developer accidentally sets both `HORSE_CROSSSOCKET` and `HORSE_ISAPI`, the ISAPI provider silently wins: `THorse` inherits from `THorseProvider.ISAPI`, the CrossSocket unit is compiled but its `THorseProviderCrossSocket` class is never used, and `THorse.Listen` has no effect. The server appears to compile and link successfully but never actually listens on any port.

We therefore propose that a future commit adds an explicit compile-time guard to catch this misconfiguration immediately:

```pascal
// Proposed addition to Horse.pas — catches the impossible combination
// at compile time with a clear error message instead of silent wrong
// behaviour at runtime.
{$IF DEFINED(HORSE_CROSSSOCKET) AND
    (DEFINED(HORSE_ISAPI) OR DEFINED(HORSE_APACHE) OR
     DEFINED(HORSE_CGI)  OR DEFINED(HORSE_FCGI))}
  {$MESSAGE FATAL 'HORSE_CROSSSOCKET cannot be combined with HORSE_ISAPI, ' +
                  'HORSE_APACHE, HORSE_CGI, or HORSE_FCGI. CrossSocket owns ' +
                  'the listening socket directly; these providers require the ' +
                  'host process (IIS/Apache/CGI caller) to own it. ' +
                  'Remove all other provider defines and keep only ' +
                  'HORSE_CROSSSOCKET.'}
{$ENDIF}
```

This guard is **not included in the current PR** to keep the patch minimal and focused, but we consider it a worthwhile follow-up and would be happy to add it if the maintainers agree.

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

Both packages ship a `boss.json` that tells Boss exactly which paths to expose. Understanding what Boss does — and does not — do with each field is important for a correct project setup.

#### What Boss adds automatically

Boss distinguishes between two path fields in `boss.json`:

| Field | What Boss does with it |
|---|---|
| `mainsrc` | Added to the **compiler Search Path** in your `.dproj` — units here are found by `uses` clauses |
| `browsingpath` | Added to the **IDE Browsing Path only** — used for code completion and navigation, but the compiler does **not** search these paths |

Has you can see on `boss.json`, BOSS installs the following packages:

**`horse-provider-crosssocket`** → Boss automatically adds:
```
..\..\..\..\modules\horse-provider-crosssocket\src
```

**`delphi-cross-socket`** (freitasjca fork)  → Boss automatically adds:
```
..\..\..\..\modules\Delphi-Cross-Socket
..\..\..\..\modules\Delphi-Cross-Socket\Net
..\..\..\..\modules\Delphi-Cross-Socket\Utils
..\..\..\..\modules\Delphi-Cross-Socket\DelphiToFPC
..\..\..\..\modules\Delphi-Cross-Socket\CnPack
```

**`horse`** (freitasjca fork)  → Boss automatically adds:
```
..\..\..\..\modules\horse\src
```

All paths above assume the standard Boss `modules\` layout at the project root. Adjust if your project uses a different Boss base directory.


---

### Changes overview

All modifications are in separate commits and are fully backward‑compatible. Detailed rationale and full code is in the [provider's README](https://github.com/freitasjca/horse-provider-crosssocket#required-changes-to-horse-source).

#### 1. `Horse.Request.pas`

- **Parameterless constructor** `THorseRequest.Create` – allows the context pool to pre‑allocate request objects at startup before any real request arrives. The existing constructor that accepts a `TWebRequest` is completely unchanged.
- **`Clear` procedure** – fast field‑wipe for object reuse between requests (zero‑allocation hot path). Resets `FBody`, `FSession`, `FWebRequest`, clears param dictionaries, and re‑creates `FSessions`.  
  ⚠️ `FBody` is a **non‑owning reference** into the CrossSocket receive buffer and is **never freed** by `Clear`.
- **`Populate` procedure** – injects per‑request shadow fields (method, method type, path, content‑type, remote address) directly, bypassing the `FWebRequest` delegation that would crash when `FWebRequest` is `nil`.
- **`PopulateCookiesFromHeader` procedure** – parses the raw `Cookie` request header into the `THorseRequest.Cookie` collection without requiring a live `TWebRequest`.

#### 2. `Horse.Response.pas`

- **`CustomHeaders` property** – read‑only exposure of the internal `FCustomHeaders` dictionary, allowing the response bridge to iterate all application‑set headers in a single pass for efficient forwarding.
- **`ContentStream` property** – supports zero‑copy stream responses (large files, generated content) without intermediate string copies.
- **`BodyText` property** – exposes the shadow string body field set when `FWebResponse` is `nil`.
- **`CSContentType` property** – exposes the shadow content‑type field for the same reason.
- **`Clear` procedure** – resets `FStatus`, `FContent`, `FContentType`, `FContentStream`, clears `FCustomHeaders`, and sets shadow fields to their defaults, mirroring the request‑side pooling contract.

#### 3. `Horse.Provider.Abstract.pas`

- **`ListenWithConfig` virtual class method** – a new virtual method that accepts a `THorseCrossSocketConfig` record (timeouts, size limits, SSL/mTLS settings, IO thread count, etc.). The base implementation simply calls the existing `Listen` overload, so **all existing providers are completely unaffected**.
- **`Execute` virtual class method** – runs the Horse middleware + route pipeline for a given `THorseRequest` / `THorseResponse` pair, allowing providers that bypass `TWebRequest` to invoke the full Horse pipeline. The base implementation calls `Routes.Execute(ARequest, AResponse)`.
- **`Port` class property** – exposes the inherited port class variable so the no‑argument `Listen` override in the CrossSocket provider can read the port set by the caller.

#### 4. New unit `Horse.Provider.Config.pas`

- Defines `THorseCrossSocketConfig` – a `record` holding all configurable server settings: IO thread count, keep‑alive and read timeouts, graceful‑drain timeout, header and body size limits, connection ceiling, SSL/TLS certificate paths, mTLS CA certificate and peer‑verify flag, cipher list, and server banner suppression.
- Placed in its own file to **avoid circular unit references** between `Horse.Provider.Abstract` and `Horse.Provider.CrossSocket`.
- Ships safe defaults aligned with common web server conventions (8 KB header limit, 4 MB body limit, 30 s keep‑alive, 20 s read timeout, `Server:` header suppressed).

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

**A community fork** ([github.com/freitasjca/Delphi-Cross-Socket](https://github.com/freitasjca/Delphi-Cross-Socket)) has already completed steps 1,2 and 3: it ships a `boss.json` with `"version": "1.0.0"` and the `mainsrc`/`browsingpath` fields correctly declared, and it adds FPC 3.3.1 support with zero source changes to the original library. This fork is what `horse-provider-crosssocket` currently depends on. The entire stack is therefore installable today with:

```
boss install github.com/freitasjca/horse-provider-crosssocket
```

The ideal long‑term outcome is for the **original repository** to adopt the `boss.json` so there is a single canonical source. The timeline for that depends on the original repository admin. Until then, the fork is the supported path.

---

### Testing and verification

> ⚠️ **Tests are currently underway. This is a beta release.** The items below describe the verification work in progress and the coverage already achieved. We will update this section and request final merge review once the full suite passes.

**Completed:**
- All existing official middlewares (`horse-jwt`, `horse-cors`, `horse-jhonson`, `horse-logger`, etc.) compile and respond correctly without any changes when the CrossSocket provider is active.
- The four additive Horse patches compile cleanly against Horse 3.x on Delphi 10.4 Sydney, 11 Alexandria, and 12 Athens with both `Win64` and `Linux64` targets.
- Basic routing (GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS), middleware chain, route parameters, query strings, request headers, cookies, and JSON body parsing have been verified end‑to‑end.
- Graceful shutdown drain (in‑flight request counter, `DrainTimeoutMs`) verified under load.
- Docker deployment on Ubuntu 22.04 via WSL 2 verified.

**In progress:**
- Full automated test suite covering edge cases (large bodies, concurrent connections, keep‑alive, TLS handshake, mTLS, malformed requests).
- Load testing to quantify throughput improvement over the Indy provider — results will replace the indicative figures in the Performance section above.
- FPC / Lazarus compilation verified; runtime testing on FPC 3.3.1 is ongoing.

---

### Summary of files changed in Horse

| File | Change type | Description |
|---|---|---|
| `Horse.pas` | Modified | Added `HORSE_CROSSSOCKET` conditional branch in `uses` and `THorseProvider` alias |
| `Horse.Request.pas` | Modified | Added parameterless constructor, `Clear`, `Populate`, `PopulateCookiesFromHeader` |
| `Horse.Response.pas` | Modified | Added `CustomHeaders`, `ContentStream`, `BodyText`, `CSContentType`, `Clear` |
| `Horse.Provider.Abstract.pas` | Modified | Added `ListenWithConfig`, `Execute`, `Port` |
| `Horse.Provider.Config.pas` | **New file** | `THorseCrossSocketConfig` record with safe defaults |

---

We would be very happy to discuss any aspect of these changes, adjust scope, or split into smaller PRs if preferred. Thank you for maintaining such a fantastic framework!
