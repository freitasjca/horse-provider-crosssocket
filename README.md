# Horse.Provider.CrossSocket

> High-performance, security-hardened [CrossSocket](https://github.com/winddriver/Delphi-Cross-Socket) provider for the [Horse](https://github.com/HashLoad/horse) web framework.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Delphi](https://img.shields.io/badge/Delphi-10.4%2B-red.svg)](https://www.embarcadero.com/products/delphi)
[![Horse](https://img.shields.io/badge/Horse-3.x-blue.svg)](https://github.com/HashLoad/horse)
[![Boss](https://img.shields.io/badge/Boss-compatible-green.svg)](https://github.com/HashLoad/boss)

---

## Why?

Horse's default provider is built on [Indy](https://www.indyproject.org/), which uses a **one-thread-per-connection** model. Under load this means thread-pool exhaustion, high memory consumption, and known vulnerability to slow-HTTP (Slowloris) attacks.

This provider replaces the Indy transport layer with [Delphi-Cross-Socket](https://github.com/winddriver/Delphi-Cross-Socket), which uses **IOCP on Windows** and **epoll on Linux** — the same async I/O model used by nginx and Node.js. The Horse routing, middleware, and application code are **completely unchanged**.

| | Horse + Indy | Horse + CrossSocket |
|---|:---:|:---:|
| Concurrency model | 1 thread per connection | IOCP / epoll |
| Slowloris resistance | ✗ | ✓ |
| Object pool (zero alloc on hot path) | ✗ | ✓ |
| Zero-copy request body | ✗ | ✓ |
| Linux first-class support | ⚠ unstable | ✓ |
| OpenSSL 3.x native | ✗ | ✓ |
| gzip / deflate receive | manual | automatic |
| Enforced request size limits | ✗ | ✓ |
| HTTP request-smuggling protection | ✗ | ✓ |
| Graceful shutdown drain | ✓ | ✓ |

---

## Table of Contents

- [Requirements](#requirements)
- [Required Changes to Horse Source](#required-changes-to-horse-source)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [HTTPS / TLS](#https--tls)
- [Mutual TLS (mTLS)](#mutual-tls-mtls)
- [Advanced Configuration](#advanced-configuration)
- [Worker Pool](#worker-pool)
- [Architecture](#architecture)
- [Security Model](#security-model)
- [Default Limits Reference](#default-limits-reference)
- [Compatibility](#compatibility)
- [File Reference](#file-reference)
- [Contributing](#contributing)
- [License](#license)

---

## Requirements

| Dependency | Version | Notes |
|---|---|---|
| Delphi | 10.4 Sydney+ | Requires `System.Threading`, inline `var` |
| Horse *(fork)* | 3.x + patches | See [Required Changes to Horse Source](#required-changes-to-horse-source) |
| [Delphi-Cross-Socket](https://github.com/winddriver/Delphi-Cross-Socket) | latest | Transport layer |
| OpenSSL | 1.1.x or 3.x | Only required for HTTPS |
| [Boss](https://github.com/HashLoad/boss) | any | Optional — for automatic dependency install |

> **Horse fork required.** This provider needs three additive changes to Horse that do not exist upstream yet (see the section below). Until a PR is merged into `HashLoad/horse`, the `boss.json` of this repo declares a dependency on `github.com/your-org/horse` — the maintained fork — instead of `github.com/HashLoad/horse`. Boss resolves the fork transparently; nothing in your application code changes.

---

## Required Changes to Horse Source

This provider calls methods and accesses properties that **do not exist in the current Horse source**. The project will not compile against an unmodified `HashLoad/horse`.

### Delivery strategy — maintaining a patched fork

Since the upstream PR may take time to be reviewed and merged, the recommended approach is to maintain a public fork of Horse that contains the patches and to point this provider's `boss.json` at that fork. Boss resolves GitHub dependencies by owner/repo path, so switching from upstream to a fork is a single-line change in `boss.json` and is completely invisible to consumers of the provider.

**Step 1 — Fork Horse on GitHub**

```
https://github.com/HashLoad/horse  →  Fork  →  github.com/your-org/horse
```

**Step 2 — Apply the three patches** (described in full below) on a branch named `crosssocket-patches` and merge it into `main` of your fork.

**Step 3 — Tag a semver release on your fork**

```bash
git tag v3.1.0-crosssocket.1
git push origin v3.1.0-crosssocket.1
```

Use the upstream version as the base (`v3.1.0`) and append a pre-release qualifier (`.crosssocket.1`) so consumers can see exactly which upstream commit was patched.

**Step 4 — Declare the fork in this provider's `boss.json`**

```json
{
  "name": "horse-provider-crosssocket",
  "version": "1.0.0",
  "mainsrc": "src/",
  "browsingpath": "src/",
  "projects": [],
  "dependencies": {
    "github.com/your-org/horse": ">=3.1.0-crosssocket.1",
    "github.com/winddriver/Delphi-Cross-Socket": ">=1.0.0"
  }
}
```

Because Boss resolves dependencies by the exact GitHub path in the key, `github.com/your-org/horse` and `github.com/HashLoad/horse` are treated as **separate packages**. A project that already depends on upstream Horse will have both resolved into `modules/` in separate subdirectories. To avoid this, consumers who adopt this provider should also update their own `boss.json` to point at the fork:

```json
"dependencies": {
  "github.com/your-org/horse": ">=3.1.0-crosssocket.1"
}
```

This is a one-line change. Application code, middleware, and routes are **unchanged** because the fork adds only new methods — it does not rename, remove, or alter the signature of anything that exists upstream.

**Step 5 — When the upstream PR is merged**

Once `HashLoad/horse` has merged the patches, update `boss.json` to switch back:

```json
"github.com/HashLoad/horse": ">=3.2.0"
```

Commit and tag a new provider release. Consumers run `boss update` and the fork dependency is replaced automatically.

---

### What the three patches add

Every change is strictly additive — no existing method is removed, renamed, or given a different signature. All existing Horse projects continue to compile and run without modification.

> **Compatibility guarantee:** adding overloads and new methods to Horse does not break any existing compiled binary or source file. The `{$DEFINE HORSE_NOPROVIDER}` define that activates this provider is the only change a consuming project ever needs to make.

---

### Change 1 — `Horse.Request.pas`

**Why:** The object pool (`Pool.pas`) calls `THorseRequest.Create` with no arguments at startup to pre-warm contexts. The current constructor requires a `TWebRequest` parameter, which does not exist outside the WebBroker/Indy pipeline. The pool also calls `FRequest.Clear` and writes directly to `FRequest.Body`, `FRequest.Session`, `FRequest.Method`, `FRequest.PathInfo`, `FRequest.RawPathInfo`, `FRequest.RemoteAddr`, and `FRequest.ContentType` during the mandatory pool reset cycle.

**Add to the `interface` section — `public` block:**

```delphi
{ Parameterless constructor — used by THorseContextPool.WarmUp.
  Must initialise all internal collections to safe defaults.
  The existing Create(AWebRequest) overload is UNCHANGED. }
constructor Create; overload;

{ Fast field wipe for pool reuse — no Free/Create on the hot path.
  Called by THorseContext.Reset between every request.
  IMPORTANT: must NOT free Body — it is a non-owning stream reference. }
procedure Clear;
```

**Add to the `implementation` section:**

```delphi
constructor THorseRequest.Create;
begin
  inherited Create;
  { Initialise the same internal collections the full constructor does,
    but without a TWebRequest source. Adjust field names to match the
    actual private declarations in your Horse version. }
  FParams  := THorseCoreParam.New(Self);
  FHeaders := THorseCoreParam.New(Self);
  FQuery   := THorseCoreParam.New(Self);
  FSession := nil;
  FBody    := nil;
end;

procedure THorseRequest.Clear;
begin
  FMethod      := '';
  FPathInfo    := '';
  FRawPathInfo := '';
  FRemoteAddr  := '';
  FContentType := '';
  { DO NOT Free FBody — it is a non-owning reference into CrossSocket's
    socket buffer. Setting it to nil is correct; freeing it would corrupt
    the live connection. }
  FBody    := nil;
  FSession := nil;
  FParams.Clear;
  FHeaders.Clear;
  FQuery.Clear;
end;
```

**Fields and properties accessed by this provider in `THorseRequest`:**

| Identifier | Kind | Used in |
|---|---|---|
| `Create` (no args) | constructor | `Pool.pas` — pool warm-up |
| `Clear` | procedure | `Pool.pas` — pool reset |
| `Body` | read/write property (`TStream`) | `Pool.pas`, `Request.pas` |
| `Session` | write property | `Pool.pas` — must be nil on reset |
| `Method` | read/write property (`string`) | `Pool.pas`, `Request.pas` |
| `MethodType` | write property (`TMethodType`) | `Request.pas` |
| `PathInfo` | read/write property (`string`) | `Pool.pas`, `Request.pas` |
| `RawPathInfo` | read/write property (`string`) | `Pool.pas`, `Request.pas` |
| `RemoteAddr` | read/write property (`string`) | `Pool.pas`, `Request.pas` |
| `ContentType` | read/write property (`string`) | `Pool.pas`, `Request.pas` |
| `SetFieldByName` | method | `Request.pas` — header population |
| `Query.Add` | method on param collection | `Request.pas` — query string |

---

### Change 2 — `Horse.Response.pas`

**Why:** The response bridge (`Response.pas`) reads `AHorseRes.CustomHeaders` to iterate and forward response headers, reads `AHorseRes.ContentStream` to support stream bodies, and writes `FResponse.Content`, `FResponse.ContentType`, and `FResponse.ContentStream` during the pool reset.

**Add to the `interface` section — `public` block:**

```delphi
{ Expose the custom-header map for direct iteration by the response bridge.
  TResponseBridge.CopyHeaders iterates this in a single O(n) pass.
  The existing AddHeader/SetCustomHeader methods write into this map —
  they are UNCHANGED. }
property CustomHeaders: TDictionary<string, string>
    read FCustomHeaders;

{ Non-owning stream body. Set by a handler that wants to send a large
  or pre-built TStream without copying it to a string.
  CrossSocket calls SendStream on this if assigned and Size > 0.
  DO NOT free this stream from within Horse — the caller owns it. }
property ContentStream: TStream
    read FContentStream write FContentStream;

{ Fast field wipe for pool reuse. Called by THorseContext.Reset.
  Must NOT free ContentStream — it is a non-owning reference. }
procedure Clear;
```

**Add the backing fields to the `private` section** (if not already present):

```delphi
private
  FCustomHeaders:  TDictionary<string, string>;
  FContentStream:  TStream;   // non-owning reference — never freed here
```

**Add to the `implementation` section:**

```delphi
procedure THorseResponse.Clear;
begin
  FStatus        := Integer(THTTPStatus.OK);
  FContent       := '';
  FContentType   := '';
  { DO NOT Free FContentStream — caller owns it. }
  FContentStream := nil;
  if Assigned(FCustomHeaders) then
    FCustomHeaders.Clear   // wipe entries, keep the TDictionary object alive
  else
    FCustomHeaders := TDictionary<string, string>.Create;
end;
```

**Fields and properties accessed by this provider in `THorseResponse`:**

| Identifier | Kind | Used in |
|---|---|---|
| `Clear` | procedure | `Pool.pas` — pool reset |
| `Status` | read/write property (`Integer`) | `Pool.pas`, `Provider.pas` |
| `Content` | read/write property (`string`) | `Pool.pas`, `Response.pas` |
| `ContentType` | read/write property (`string`) | `Pool.pas`, `Response.pas`, `Provider.pas` |
| `ContentStream` | read/write property (`TStream`) | `Pool.pas`, `Response.pas` |
| `CustomHeaders` | read property (`TDictionary<string,string>`) | `Response.pas` |
| `Send` | method | `Provider.pas` — error responses |

---

### Change 3 — `Horse.Provider.Abstract.pas`

**Why:** `THorseProviderCrossSocket` exposes `ListenWithConfig(APort, AConfig)` as a class method. The abstract base class `THorseProvider` must declare a virtual version of this method so the compiler knows the signature. The default implementation simply calls `Listen(APort)`, so all existing providers (Console, VCL, Daemon, CGI, Apache) compile and run without any modification.

**Add `Horse.Provider.Config.pas`** (new file — prevents a circular unit reference between the abstract base and the CrossSocket provider):

```delphi
unit Horse.Provider.Config;

{ Shared configuration types for Horse providers.
  Placed in a separate unit so Horse.Provider.Abstract.pas has no
  compile-time dependency on Horse.Provider.CrossSocket.Server.pas. }

interface

type
  THorseCrossSocketConfig = record
    KeepAliveTimeout: Integer;
    ReadTimeout:      Integer;
    DrainTimeoutMs:   Integer;
    MaxHeaderSize:    Integer;
    MaxBodySize:      Int64;
    MaxConnections:   Integer;
    SSLEnabled:       Boolean;
    SSLCertFile:      string;
    SSLKeyFile:       string;
    SSLKeyPassword:   string;
    SSLCACertFile:    string;
    SSLVerifyPeer:    Boolean;
    SSLCipherList:    string;
    ServerBanner:     string;

    class function Default: THorseCrossSocketConfig; static;
  end;

implementation

class function THorseCrossSocketConfig.Default: THorseCrossSocketConfig;
begin
  Result.KeepAliveTimeout := 30;
  Result.ReadTimeout      := 20;
  Result.DrainTimeoutMs   := 5000;
  Result.MaxHeaderSize    := 8192;
  Result.MaxBodySize      := 4 * 1024 * 1024;
  Result.MaxConnections   := 10000;
  Result.SSLEnabled       := False;
  Result.SSLCertFile      := '';
  Result.SSLKeyFile       := '';
  Result.SSLKeyPassword   := '';
  Result.SSLCACertFile    := '';
  Result.SSLVerifyPeer    := False;
  Result.SSLCipherList    := '';
  Result.ServerBanner     := '';
end;

end.
```

**Modify `Horse.Provider.Abstract.pas`** — add to `uses` and to the `THorseProvider` class:

```delphi
uses
  Horse.Provider.Config;   // ← add this

type
  THorseProvider = class
  public
    class procedure Listen(APort: Integer); virtual; abstract;
    class procedure Stop; virtual; abstract;

    { ADD — default implementation falls back to plain Listen.
      CrossSocket provider overrides this to consume the full config.
      All existing providers inherit this no-op and are unaffected. }
    class procedure ListenWithConfig(
      APort:         Integer;
      const AConfig: THorseCrossSocketConfig
    ); virtual;
  end;
```

**Add to the `implementation` section:**

```delphi
class procedure THorseProvider.ListenWithConfig(
  APort:         Integer;
  const AConfig: THorseCrossSocketConfig
);
begin
  { Default: ignore the config and fall back to plain Listen.
    Indy, VCL, CGI, Apache, Daemon providers all inherit this. }
  Listen(APort);
end;
```

---

### Summary of Horse source changes

| File | Change | Risk to existing code |
|---|---|---|
| `Horse.Request.pas` | Add `Create` overload (no params) | Zero — new overload, original untouched |
| `Horse.Request.pas` | Add `Clear` procedure | Zero — new method |
| `Horse.Response.pas` | Add `CustomHeaders` property | Zero — exposes existing field |
| `Horse.Response.pas` | Add `ContentStream` property | Zero — new field + property |
| `Horse.Response.pas` | Add `Clear` procedure | Zero — new method |
| `Horse.Provider.Abstract.pas` | Add `ListenWithConfig` virtual class method | Zero — default delegates to `Listen` |
| `Horse.Provider.Config.pas` | New file — shared config record | Zero — new file |

All seven changes are purely additive. No existing method, property, constructor, or destructor is modified.

---

## Installation

### Using Boss (recommended)

```bash
boss install github.com/your-org/horse-provider-crosssocket
```

Boss resolves `horse-provider-crosssocket` and its two transitive dependencies — the patched Horse fork and Delphi-Cross-Socket — and injects all source paths into your `.dproj` automatically.

If your project already has a `boss.json`, ensure it does **not** also declare `github.com/HashLoad/horse` as a direct dependency, otherwise Boss will resolve both and the compiler may pick the wrong `Horse.Request.pas`. Use only the fork:

```json
{
  "dependencies": {
    "github.com/your-org/horse-provider-crosssocket": ">=1.0.0"
  }
}
```

The patched Horse fork is pulled in automatically as a transitive dependency of the provider — you do not need to declare it separately.

### Manual

1. Clone this repository, the patched Horse fork, and Delphi-Cross-Socket:
   ```bash
   git clone https://github.com/your-org/horse-provider-crosssocket
   git clone https://github.com/your-org/horse          # patched fork
   git clone https://github.com/winddriver/Delphi-Cross-Socket
   ```
2. Add to your project's search path **in this order** (patched Horse before any other Horse source):
   - `horse/src/`
   - `horse-provider-crosssocket/src/`
   - `Delphi-Cross-Socket/Net/`
   - `Delphi-Cross-Socket/Utils/`
   - `Delphi-Cross-Socket/OpenSSL/`
3. Do **not** add the original `HashLoad/horse/src/` to the search path. The compiler must find the patched `Horse.Request.pas`, `Horse.Response.pas`, and `Horse.Provider.Abstract.pas` from your fork.

---

## Quick Start

The only two changes vs a standard Horse project are:

1. Add `{$DEFINE HORSE_NOPROVIDER}` before the `uses` clause — this tells Horse not to load its default Indy provider.
2. Add `Horse.Provider.CrossSocket` to `uses`.

The `THorse.Listen` call stays **identical**.

```delphi
program MyAPI;

{$APPTYPE CONSOLE}
{$DEFINE HORSE_NOPROVIDER}  // ← disable the default Indy provider

uses
  Horse,
  Horse.Provider.CrossSocket;  // ← add this

begin
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('pong');
    end);

  THorse.Listen(9000);  // ← unchanged
end.
```

That is all. Every existing middleware (`horse-jwt`, `horse-cors`, `horse-jhonson`, etc.) continues to work without modification because the provider only replaces the transport layer.

---

## HTTPS / TLS

Use `ListenWithConfig` and populate the `SSLEnabled` fields on `THorseCrossSocketConfig`:

```delphi
uses
  Horse,
  Horse.Provider.CrossSocket,
  Horse.Provider.CrossSocket.Server;  // THorseCrossSocketConfig

var
  Cfg: THorseCrossSocketConfig;
begin
  THorse.Get('/ping', ...);

  Cfg                := THorseCrossSocketConfig.Default;
  Cfg.SSLEnabled     := True;
  Cfg.SSLCertFile    := 'cert.pem';
  Cfg.SSLKeyFile     := 'key.pem';
  Cfg.SSLKeyPassword := '';           // leave empty if key has no passphrase

  THorseProviderCrossSocket.ListenWithConfig(9443, Cfg);
end.
```

The provider enforces a modern AEAD-only cipher list by default (TLS 1.2 + TLS 1.3, forward secrecy, no RC4 / 3DES / export). To override it, set `Cfg.SSLCipherList` to your own OpenSSL cipher string.

---

## Mutual TLS (mTLS)

To require clients to present a certificate:

```delphi
Cfg.SSLEnabled    := True;
Cfg.SSLCertFile   := 'server-cert.pem';
Cfg.SSLKeyFile    := 'server-key.pem';
Cfg.SSLCACertFile := 'ca-cert.pem';   // CA that signed client certs
Cfg.SSLVerifyPeer := True;            // reject clients without a valid cert
```

---

## Advanced Configuration

`THorseCrossSocketConfig.Default` provides production-safe values out of the box. Every field can be overridden:

```delphi
var Cfg := THorseCrossSocketConfig.Default;

// Timeouts
Cfg.KeepAliveTimeout := 30;     // seconds; 0 = disable keep-alive
Cfg.ReadTimeout      := 20;     // seconds — mitigates slow-HTTP attacks
Cfg.DrainTimeoutMs   := 5000;   // ms to wait for in-flight requests on Stop

// Size limits
Cfg.MaxHeaderSize    := 8192;           // bytes (default: 8 KB)
Cfg.MaxBodySize      := 4 * 1024 * 1024; // bytes (default: 4 MB)

// Connection ceiling — prevents file-descriptor exhaustion DoS
Cfg.MaxConnections   := 10000;

// Suppress Server: header (default: 'unknown')
Cfg.ServerBanner     := '';

THorseProviderCrossSocket.ListenWithConfig(9000, Cfg);
```

### Custom error logging

Worker-pool exceptions (and unhandled pipeline exceptions) are routed to a pluggable callback. The default writes to `ErrOutput`. Override it after `Listen`:

```delphi
THorseProviderCrossSocket.Listen(9000);

THorseWorkerPool.Instance.OnTaskError :=
  procedure(const E: Exception; ATaskIndex: Int64)
  begin
    MyLogger.Error('[Task #%d] %s: %s', [ATaskIndex, E.ClassName, E.Message]);
  end;
```

---

## Worker Pool

CrossSocket's IO threads must never block. For CPU-bound handlers, offload work to the built-in worker pool:

```delphi
THorse.Post('/report',
  procedure(Req: THorseRequest; Res: THorseResponse)
  begin
    // Capture what you need before the closure — do NOT capture Req/Res directly.
    // Req.Body is a non-owning stream that CrossSocket may release after the
    // handler returns. Copy the data you need first.
    var Payload := Req.Body.ReadToEnd;

    THorseWorkerPool.Instance.Submit(
      procedure
      begin
        // Heavy CPU work here — runs on a worker thread
        var Report := BuildReport(Payload);
        // For async reply, capture the CrossSocket response interface
        // before submitting (see samples/async_reply.dpr)
      end
    );

    // Fast, synchronous acknowledgement back to the IO thread
    Res.Status(THTTPStatus.Accepted);
    Res.Send('{"status":"queued"}');
  end);
```

The worker pool is bounded at **4 096 queued tasks** by default. When the queue is full, `Submit` raises `EHorseException(503)` so the caller can send an appropriate response. The pool starts 4 worker threads and can grow to 64.

> **Important:** Never use `Req.Body` inside a worker-pool closure without copying it first. The stream is a non-owning reference into CrossSocket's socket buffer and may be released when the pipeline returns.

---

## Architecture

```
CrossSocket (IOCP / epoll)
        │
        │  ICrossHttpRequest / ICrossHttpResponse
        ▼
┌────────────────────────────────────────────┐
│  TRequestBridge.Populate                   │
│  · method allowlist                        │
│  · Host validation                         │
│  · CL + TE smuggling check (RFC 7230)      │
│  · header count / size limits              │
│  · URL length limit                        │
│  · query-string size limits                │
└───────────────────┬────────────────────────┘
                    │  validated ICrossHttpRequest
                    ▼
        THorseContextPool.Acquire
        (pre-warmed, no heap alloc)
                    │
                    ▼
┌────────────────────────────────────────────┐
│  THorse.Execute                            │
│  full middleware + routing pipeline        │
│  (horse-jwt, horse-cors, etc. unchanged)   │
└───────────────────┬────────────────────────┘
                    │  THorseResponse
                    ▼
┌────────────────────────────────────────────┐
│  TResponseBridge.Flush                     │
│  · CRLF-strip all header values            │
│  · hop-by-hop header filter                │
│  · security headers injected               │
│  · single UTF-8 encode, async send         │
└───────────────────┬────────────────────────┘
                    │
        THorseContextPool.Release
        (Reset — never Free)
```

---

## Security Model

This provider was designed with a layered defence-in-depth approach. Every protection is enforced by default and cannot be accidentally disabled.

### Input validation (before the Horse pipeline is entered)

| Protection | Default | RFC / standard |
|---|---|---|
| HTTP method allowlist (`GET POST PUT DELETE PATCH HEAD OPTIONS`) | enforced | — |
| `TRACE` / `CONNECT` rejected | always | XST / proxy safety |
| CL + TE both present → 400 | always | RFC 7230 §3.3.3 |
| Unknown `Transfer-Encoding` → 400 | always | RFC 7230 |
| Missing / non-printable `Host` → 400 | always | RFC 7230 §5.4 |
| URL length limit | 8 KB | — |
| Header count limit | 100 | — |
| Header name limit | 256 B | — |
| Header value limit | 8 KB | — |
| Query-string key limit | 2 KB | — |
| Query-string value limit | 2 KB | — |

### Transport

| Protection | Default |
|---|---|
| `ReadTimeout` enforced | 20 s |
| `MaxBodySize` enforced | 4 MB |
| `MaxHeaderSize` enforced | 8 KB |
| `MaxConnections` ceiling | 10 000 |
| TLS 1.2 + 1.3, AEAD-only ciphers | when SSL enabled |
| Mutual TLS (client cert) | opt-in |
| `Server:` header suppressed | `unknown` |

### Response output

| Protection | Default |
|---|---|
| CRLF stripped from all header values | always |
| Hop-by-hop headers blocked | always |
| `X-Content-Type-Options: nosniff` | always |
| `X-Frame-Options: DENY` | always |
| `Referrer-Policy: strict-origin-when-cross-origin` | always |
| `Cache-Control: no-store` | always |

### Object pool

The context pool resets **every field** between requests — including `Session`, `Body`, `RemoteAddr`, and all middleware-injected values — before returning an object to the pool. A failed reset discards the context rather than returning it dirty.

In `DEBUG` builds, fields are written with sentinel poison values before being cleared, turning silent data-leakage bugs into immediate and obvious failures during development.

### `X-Forwarded-For`

`Req.RemoteAddr` is always the **real socket peer** (`PeerAddr`). `X-Forwarded-For` is forwarded as a header and never silently replaces `RemoteAddr`, because that would allow any client to spoof its IP address. If you run behind a trusted reverse proxy, add a middleware that validates the XFF chain against your known proxy CIDR:

```delphi
THorse.Use(
  procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
  begin
    // Only trust XFF if the real peer is your known proxy IP
    if Req.RemoteAddr = '10.0.0.1' then
      Req.RemoteAddr := Req.Headers['X-Forwarded-For'].Split([','])[0].Trim;
    Next;
  end);
```

---

## Default Limits Reference

| Constant | Value | Defined in |
|---|---|---|
| `DEFAULT_READ_TIMEOUT` | 20 s | `Server.pas` |
| `DEFAULT_KEEP_ALIVE_TIMEOUT` | 30 s | `Server.pas` |
| `DEFAULT_MAX_HEADER_SIZE` | 8 192 B | `Server.pas` |
| `DEFAULT_MAX_BODY_SIZE` | 4 194 304 B (4 MB) | `Server.pas` |
| `DEFAULT_MAX_CONNECTIONS` | 10 000 | `Server.pas` |
| `DEFAULT_DRAIN_TIMEOUT_MS` | 5 000 ms | `Server.pas` |
| `MAX_HEADER_COUNT` | 100 | `Request.pas` |
| `MAX_HEADER_NAME_LEN` | 256 B | `Request.pas` |
| `MAX_HEADER_VALUE_LEN` | 8 192 B | `Request.pas` |
| `MAX_URL_LEN` | 8 192 B | `Request.pas` |
| `MAX_QUERY_KEY_LEN` | 2 048 B | `Request.pas` |
| `MAX_QUERY_VALUE_LEN` | 2 048 B | `Request.pas` |
| `POOL_MAX_SIZE` | 512 contexts | `Pool.pas` |
| `POOL_WARMUP_SIZE` | 32 contexts | `Pool.pas` |
| `WORKER_POOL_MIN_THREADS` | 4 | `WorkerPool.pas` |
| `WORKER_POOL_MAX_THREADS` | 64 | `WorkerPool.pas` |
| `MAX_QUEUE_DEPTH` | 4 096 tasks | `WorkerPool.pas` |
| `SHUTDOWN_DRAIN_MS` | 5 000 ms | `WorkerPool.pas` |

---

## Compatibility

All existing Horse middleware and application code is compatible without modification. The provider replaces only the socket transport layer.

| Feature | Status |
|---|---|
| `THorse.Get / Post / Put / Delete / Patch` | ✓ full |
| `THorse.Use` (middleware chain) | ✓ full |
| `horse-jwt` | ✓ |
| `horse-cors` | ✓ |
| `horse-basic-auth` | ✓ |
| `horse-jhonson` (JSON) | ✓ |
| `horse-logger` | ✓ |
| `horse-exception` | ✓ |
| `horse-octet-stream` (file serve) | ✓ |
| `EHorseException` structured errors | ✓ |
| Path parameters (`/user/:id`) | ✓ |
| `Req.Params` / `Req.Query` / `Req.Headers` | ✓ |
| `Req.Body` (TStream) | ✓ zero-copy |
| `Res.Send` / `Res.Status` / `Res.AddHeader` | ✓ |
| SSL / TLS | ✓ OpenSSL 3.x |
| Mutual TLS | ✓ |
| Windows (IOCP) | ✓ |
| Linux (epoll) | ✓ |
| macOS (kqueue) | ✓ via CrossSocket |
| VCL / Apache / CGI / ISAPI providers | not applicable — separate providers |

---

## File Reference

```
src/
├── Horse.Provider.CrossSocket.pas          Main provider — THorseProviderCrossSocket
├── Horse.Provider.CrossSocket.Server.pas   TCrossHttpServer wrapper + THorseCrossSocketConfig
├── Horse.Provider.CrossSocket.Pool.pas     Thread-safe context object pool
├── Horse.Provider.CrossSocket.Request.pas  ICrossHttpRequest → THorseRequest bridge + validation
├── Horse.Provider.CrossSocket.Response.pas THorseResponse → ICrossHttpResponse bridge
└── Horse.Provider.CrossSocket.WorkerPool.pas  CPU-bound worker thread pool

samples/
└── server.dpr                              Minimal working server example
```

### Unit responsibilities

**`Horse.Provider.CrossSocket`**
Entry point. `THorseProviderCrossSocket.Listen(port)` or `ListenWithConfig(port, config)`. Wires CrossSocket's `OnRequest` callback to the validation → pool → pipeline → flush cycle. Tracks in-flight requests for graceful shutdown.

**`Horse.Provider.CrossSocket.Server`**
Wraps `TCrossHttpServer`. Owns `THorseCrossSocketConfig` (all timeouts, size limits, SSL settings). `Stop` is synchronous — it waits up to `DrainTimeoutMs` for active requests to finish before returning.

**`Horse.Provider.CrossSocket.Pool`**
Pre-allocates `THorseContext` objects at startup and reuses them across requests via `Acquire` / `Release`. `Reset` explicitly wipes every security-sensitive field. In `DEBUG` builds, poison values detect partial-reset bugs immediately.

**`Horse.Provider.CrossSocket.Request`**
`TRequestBridge.Populate` validates and translates `ICrossHttpRequest` into `THorseRequest`. Returns `rvOK`, `rvBadRequest`, or `rvMethodNotAllowed` — the pipeline is never entered for invalid requests.

**`Horse.Provider.CrossSocket.Response`**
`TResponseBridge.Flush` translates `THorseResponse` into the CrossSocket response. Strips CRLF from all header values, blocks hop-by-hop headers, and injects default security headers.

**`Horse.Provider.CrossSocket.WorkerPool`**
Fixed-size worker thread pool for CPU-bound tasks. Bounded queue (4 096), pluggable error callback, named threads, graceful drain on shutdown.

---

## Contributing

Pull requests are welcome. Please:

- Target the `main` branch.
- Add a `{SEC-N}` tag in the comment block if your change addresses a security concern.
- Run the existing test suite before opening a PR (`boss build` / `dcc32`).
- For new security-relevant behaviour, add a note to the **Security Model** section of this README.

---

## License

MIT — see [LICENSE](LICENSE).

---

## Related projects

- [Horse](https://github.com/HashLoad/horse) — the web framework
- [Delphi-Cross-Socket](https://github.com/winddriver/Delphi-Cross-Socket) — the async socket library
- [Boss](https://github.com/HashLoad/boss) — the Delphi package manager
- [horse-jwt](https://github.com/HashLoad/horse-jwt) — JWT middleware
- [horse-cors](https://github.com/HashLoad/horse-cors) — CORS middleware
