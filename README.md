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
| Enforced request size limits ¹ | ✗ | ✓ |
| HTTP request-smuggling protection ¹ | ✗ | ✓ |
| Pre-pipeline input validation ¹ | ✗ | ✓ |
| Security response headers ¹ | ✗ | ✓ |
| Graceful shutdown drain | ✓ | ✓ |

¹ CrossSocket enforces these **before** the Horse pipeline via `TRequestBridge.Populate` and `TResponseBridge.Flush`. Equivalent middleware for the Indy path is provided in the [Security Model](#security-model) section.

---

## Table of Contents

- [Requirements](#requirements)
- [Required Changes to Horse Source](#required-changes-to-horse-source)
- [Applying the Patches](#applying-the-patches)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [HTTPS / TLS](#https--tls)
- [Mutual TLS (mTLS)](#mutual-tls-mtls)
- [Advanced Configuration](#advanced-configuration)
- [Worker Pool](#worker-pool)
- [Architecture](#architecture)
- [Security Model](#security-model)
  - [Equivalent protection on Indy](#equivalent-protection-on-indy)
- [CI / CD](#ci--cd)
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
| [Horse](https://github.com/HashLoad/horse) | 3.2.0+ | Pulled in by `boss install` of this package. The last released tag is `v3.2.0` (Mar 30, 2026); subsequent improvements continue on `master` without a release tag yet — Boss will resolve `>=3.2.0` to the tagged release. If your build needs an unreleased addition that lives only on `master`, pin to the branch explicitly with `"github.com/HashLoad/horse": "master"` in your application's `boss.json`. |
| [Delphi-Cross-Socket](https://github.com/winddriver/Delphi-Cross-Socket) | latest | Transport layer — install from upstream (`winddriver`); the [`freitasjca/Delphi-Cross-Socket >= 1.0.3`](https://github.com/freitasjca/Delphi-Cross-Socket/releases/tag/v1.0.3) fork is a supported alternative for mTLS-server-mode users (see [Mutual TLS (mTLS)](#mutual-tls-mtls)) |
| [CnPack](https://github.com/cnpack/cnvcl) (Crypto units) | latest | Required by Delphi-Cross-Socket — install separately. See [Installation](#installation) |
| OpenSSL | 1.1.x or 3.x | Only required for HTTPS |
| [Boss](https://github.com/HashLoad/boss) | any | Recommended — pulls in Horse automatically |

> **Horse is now upstream.** Earlier releases of this provider depended on a patched Horse fork (`freitasjca/horse`) because the required additive changes had not yet landed in `HashLoad/horse`. **The patches have since been merged upstream**, so `boss.json` now declares the dependency directly against `github.com/HashLoad/horse` — no fork is involved in the install path. The [Required Changes to Horse Source](#required-changes-to-horse-source) section below is kept as historical reference describing **what** was added; on a current `HashLoad/horse` checkout the changes are already in place.

> **Delphi-Cross-Socket is installed manually.** Unlike Horse, Delphi-Cross-Socket is **not** pulled in by `boss install` — clone it directly and add the search paths (see [Installation](#installation)). Three bug fixes that were previously fork-only — `PATCH-IOCP-1` (DEBUG-build shutdown cascade), the `TCrossHttpClient` zero-body parser hang, and the `_OnBodyEnd` nil-guard — have all been merged into `winddriver/Delphi-Cross-Socket` upstream as of 2026-Q2, so the upstream mainline is now correct for general use. Only the mTLS server-mode API (`SetCACertificateFile` / `SetVerifyPeer`) remains fork-only — that's what the fork release [`freitasjca/Delphi-Cross-Socket v1.0.3`](https://github.com/freitasjca/Delphi-Cross-Socket/releases/tag/v1.0.3) ships, ready-to-use without manual patching.

---

## Required Changes to Horse Source

> **Status: MERGED UPSTREAM.** The additive changes documented below are now present in `HashLoad/horse` and `boss install horse-provider-crosssocket` resolves the dependency against the upstream repository directly. The section is retained as **historical reference** so contributors understand *what* was added and *why* — useful when reading the patched files in `patches/horse/src/` (kept for archive purposes), when diagnosing a build that picks up an older Horse version that pre-dates the merge, or when contributing further provider-level changes that may need parallel additions to Horse itself.
>
> If your `boss.json` was previously pinned to `github.com/freitasjca/horse`, switch it to `github.com/HashLoad/horse` — application code, middleware, and routes are unchanged.

### What the Horse patches add

No existing method is removed, renamed, or given a different signature. Existing accessor methods in `THorseRequest` and `THorseResponse` gain nil-guard branches for the CrossSocket path, but the Indy code path within each is unchanged. All existing Horse projects continue to compile and run without modification.

> **Compatibility guarantee:** adding overloads and new methods to Horse does not break any existing compiled binary or source file. The `{$DEFINE HORSE_CROSSSOCKET}` define that activates this provider is the only project-level change a consuming project ever needs to make.

---

### Change 1 — `Horse.Request.pas`

**Why:** The object pool (`Pool.pas`) calls `THorseRequest.Create` with no arguments at startup to pre-warm contexts. The current constructor requires a `TWebRequest` parameter, which does not exist outside the WebBroker/Indy pipeline. The pool also calls `FRequest.Clear` during the pool reset cycle. Additionally, on the CrossSocket path `FWebRequest` is always `nil` — `Body`, `Host`, and `InitializeQuery` must be guarded against that.

**Add to the `interface` section — `public` block:**

```delphi
{ Parameterless constructor — used by THorseContextPool.WarmUp.
  Must initialise all internal collections to safe defaults.
  The existing Create(AWebRequest) overload is UNCHANGED. }
constructor Create; overload;

{ Fast field wipe for pool reuse — no Free/Create on the hot path.
  Called by THorseContext.Reset between every request.
  CRITICAL: must NOT free Body — it is a non-owning stream reference
  into CrossSocket's socket buffer (see FIX-POOL-1 in Pool.pas). }
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
    the live connection and produce EInvalidPointer (see FIX-POOL-1). }
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

### Change 3 — `Horse.Core.RouterTree.pas`

**Why:** The router's `Execute` method reads `ARequest.RawWebRequest.RawPathInfo` and `ARequest.RawWebRequest.MethodType` directly. On the CrossSocket path `RawWebRequest` is always `nil` (no `TWebRequest` is ever created), so every request crashes with an access violation before reaching any route.

The fix adds a nil-guard that branches on whether `RawWebRequest` is assigned:
- **Indy path** (`RawWebRequest <> nil`): original expressions unchanged — zero behaviour change.
- **CrossSocket path** (`RawWebRequest = nil`): reads `ARequest.RawPathInfo` and `ARequest.MethodType` — shadow fields populated by `TRequestBridge.Populate` before the pipeline is entered.

**Modify `THorseRouterTree.Execute` in the `implementation` section:**

```delphi
function THorseRouterTree.Execute(...): Boolean;
var
  LPathInfo:       string;
  LMethodType:     TMethodType;
  LRawWebRequest:  TWebRequest;   // local var required — Assigned() needs a variable
begin
  LRawWebRequest := ARequest.RawWebRequest;
  if not Assigned(LRawWebRequest) then
  begin
    // CrossSocket path: shadow fields set by TRequestBridge.Populate
    LPathInfo   := ARequest.RawPathInfo;
    LMethodType := ARequest.MethodType;
  end
  else
  begin
    // Indy path: original expressions — unchanged
    LPathInfo   := LRawWebRequest.RawPathInfo;
    LMethodType := LRawWebRequest.MethodType;
  end;
  // ... rest of Execute unchanged ...
end;
```

This change is two new lines inside `Execute` (the nil-guard branch) and two substitutions in the existing Indy branch — the Indy behaviour is bit-for-bit identical to upstream.

---

### Change 4 — `Horse.Provider.Abstract.pas` + new `Horse.Provider.Config.pas`

**Why:** `THorseProviderCrossSocket` exposes `ListenWithConfig(APort, AConfig)` as a class method. The abstract base class `THorseProvider` must declare a virtual version of this method so the compiler knows the signature. The base implementation raises an exception to make it immediately obvious when a concrete provider has forgotten to override it — all existing concrete providers (Console, VCL, Daemon, CGI, Apache) override it and call `SetPort(APort)` before their own `Listen`, so they are completely unaffected.

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
    Compressible:     Boolean;
    MinCompressSize:  Int64;
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
  Result.Compressible     := False;
  Result.MinCompressSize  := 512;
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
  { Base guard: every concrete provider must override this.
    Raising here converts "silent wrong port" into an immediate
    detectable oversight. All existing patched providers already
    override ListenWithConfig and call SetPort(APort) before Listen. }
  raise Exception.CreateFmt(
    '%s must override ListenWithConfig — call SetPort(APort) before Listen.',
    [ClassName]);
end;
```

---

### Summary of Horse source changes

| File | Change | Risk to existing code |
|---|---|---|
| `Horse.pas` | Add `{$DEFINE HORSE_CROSSSOCKET}` conditional branch for `THorseProvider` type alias | Zero — define is opt-in |
| `Horse.Request.pas` | Add `Create` overload (no params) | Zero — new overload, original untouched |
| `Horse.Request.pas` | Add `Clear` procedure | Zero — new method |
| `Horse.Response.pas` | Add `CustomHeaders` property | Zero — exposes existing field |
| `Horse.Response.pas` | Add `ContentStream` property | Zero — new field + property |
| `Horse.Response.pas` | Add `Clear` procedure | Zero — new method |
| `Horse.Core.RouterTree.pas` | Nil-guard `RawWebRequest` in `Execute` | Zero — Indy branch identical to upstream |
| `Horse.Provider.Abstract.pas` | Add `ListenWithConfig` virtual class method | Zero — default delegates to `Listen` |
| `Horse.Provider.Config.pas` | New file — shared config record | Zero — new file |

No existing method is removed, renamed, or given a different signature. Existing accessor methods in `THorseRequest` and `THorseResponse` are modified with nil-guard branches for the CrossSocket path; the Indy code path within each is unchanged.

---

## Applying the Patches

There are no patches for an end-user to apply.

- **Horse patches**: merged into `HashLoad/horse` upstream. `boss install` resolves the upstream repo directly.
- **Delphi-Cross-Socket bug fixes** (`PATCH-IOCP-1` shutdown cascade, the zero-body parser hang, the `_OnBodyEnd` nil-guard): merged into `winddriver/Delphi-Cross-Socket` upstream as of 2026-Q2. No action required if your clone is recent.
- **Delphi-Cross-Socket mTLS additions** (`SetCACertificate(File)` + `SetVerifyPeer(Boolean)`): **not** in `winddriver/Delphi-Cross-Socket` upstream. End-users who need mTLS server mode get the additions in pre-applied form by using the fork release [`freitasjca/Delphi-Cross-Socket v1.0.3`](https://github.com/freitasjca/Delphi-Cross-Socket/releases/tag/v1.0.3) — single clone, ready to compile. See [Path B in Installation](#installation) and the [Mutual TLS (mTLS)](#mutual-tls-mtls) section.

> A `patches/` directory exists in this repository for **maintainer reference** only — it holds the original Horse-source diffs (now obsolete since the merge) and the Delphi-Cross-Socket mTLS source files used to construct the fork release `v1.0.3`. End-users never interact with that directory.

---

## Installation

There are three supported install paths. **Path A is recommended** for new projects; pick B if you want bundled CnPack convenience or need mTLS; pick C if you need mTLS today and are willing to use the fork release.

### Path A — Recommended: Boss for Horse + upstream Delphi-Cross-Socket + CnPack from `cnpack/cnvcl`

Tracks the upstream maintainers' release cadence; smallest maintenance surface. Mirrors the install pattern used by `horse-provider-mormot` (Boss pulls Horse; everything else is a manual clone).

1. Install `horse-provider-crosssocket` via Boss — this also pulls Horse from `HashLoad/horse`:
   ```bash
   boss install github.com/freitasjca/horse-provider-crosssocket
   ```
2. Clone upstream Delphi-Cross-Socket and CnPack manually (Boss does not pull these):
   ```bash
   git clone https://github.com/winddriver/Delphi-Cross-Socket
   git clone https://github.com/cnpack/cnvcl
   ```
3. Add to your project's search path:
   - `modules/horse/src/` *(Boss-managed checkout of `HashLoad/horse`)*
   - `modules/horse-provider-crosssocket/src/` *(Boss-managed)*
   - `Delphi-Cross-Socket/Net/`
   - `Delphi-Cross-Socket/Utils/`
   - `Delphi-Cross-Socket/OpenSSL/`
   - `cnvcl/Source/Common/`
   - `cnvcl/Source/Crypto/`
4. The two mTLS patches for Delphi-Cross-Socket are **not needed** on this path unless your application sets `SSLVerifyPeer = True`. If you need mTLS, switch to **Path B** below.

**Cherry-pick variant** — if you don't want the whole CnPack repository, download only the 15 files Delphi-Cross-Socket actually uses (each from `https://github.com/cnpack/cnvcl/blob/master/Source/...`):

| File | Source path on GitHub |
|---|---|
| `Common/CnPack.inc` | [`Source/Common/CnPack.inc`](https://github.com/cnpack/cnvcl/blob/master/Source/Common/CnPack.inc) |
| `Crypto/CnMD5.pas`, `CnSHA1.pas`, `CnSHA2.pas`, `CnSHA3.pas`, `CnSM3.pas` | hash functions used by `Utils.Hash.pas` (+ `CnSHA3` pulled by `CnKDF`) |
| `Crypto/CnPemUtils.pas` | PEM parsing (`Utils.Hash.pas`) |
| `Crypto/CnConsts.pas`, `CnNative.pas`, `CnFloat.pas` | shared constants + native-int helpers (transitive) |
| `Crypto/CnRandom.pas`, `CnKDF.pas` | CSPRNG + KDF (used by `CnPemUtils`) |
| `Crypto/CnBase64.pas`, `CnAES.pas`, `CnDES.pas` | base64 + symmetric ciphers (used by `CnPemUtils` for encrypted PEM) |

Place them under `<your-workspace>/CnPack/Common/` and `<your-workspace>/CnPack/Crypto/` (preserve the two-folder split), then add those paths to the search path instead of the `cnvcl/Source/Common` and `cnvcl/Source/Crypto` entries in step 3.

### Path B — Supported alternative: `freitasjca/Delphi-Cross-Socket` fork (bundles CnPack + mTLS)

Single dependency to clone (CnPack and mTLS patches both pre-applied). The trade-off is **lag**: upstream `winddriver/Delphi-Cross-Socket` ships changes frequently and the fork drifts behind between syncs — recent improvements may not yet be in the fork release you install.

Use this path if:
- You need mTLS server mode (`SSLVerifyPeer = True` + `SSLCACertFile = ...`) and don't want to apply the two mTLS patches yourself, **or**
- You prefer one fewer clone over tracking upstream Delphi-Cross-Socket directly.

1. Install via Boss (same one-liner as Path A — pulls Horse from `HashLoad/horse`):
   ```bash
   boss install github.com/freitasjca/horse-provider-crosssocket
   ```
2. Clone the Delphi-Cross-Socket fork release `v1.0.3` (CnPack and mTLS additions pre-applied):
   ```bash
   git clone -b v1.0.3 https://github.com/freitasjca/Delphi-Cross-Socket
   ```
3. Search paths (no separate CnPack entries needed — they live under `Delphi-Cross-Socket/CnPack/`):
   - `modules/horse/src/` *(Boss-managed checkout of `HashLoad/horse`)*
   - `modules/horse-provider-crosssocket/src/` *(Boss-managed)*
   - `Delphi-Cross-Socket/Net/`
   - `Delphi-Cross-Socket/Utils/`
   - `Delphi-Cross-Socket/OpenSSL/`
   - `Delphi-Cross-Socket/CnPack/Common/`
   - `Delphi-Cross-Socket/CnPack/Crypto/`

### `boss.json` configuration for consuming projects

If your application's `boss.json` already declares `github.com/HashLoad/horse` as a direct dependency, that's fine — Boss will resolve the same package once. Both Horse and `horse-provider-crosssocket` come from the same upstream organisation, so there's no fork-vs-upstream conflict to worry about:

```json
{
  "dependencies": {
    "github.com/freitasjca/horse-provider-crosssocket": ">=1.0.6"
  }
}
```

---

## Quick Start

Add `HORSE_CROSSSOCKET` to your project's conditional defines (**Project Options → Delphi Compiler → Conditional defines**). That single define tells `Horse.pas` to resolve `THorseProvider` to `THorseProviderCrossSocket` — no other application code change is needed.

```delphi
program MyAPI;

{$APPTYPE CONSOLE}

// Set HORSE_CROSSSOCKET in Project Options → Conditional defines, or declare it here:
{$DEFINE HORSE_CROSSSOCKET}

uses
  Horse;   // Horse.pas resolves THorseProvider to THorseProviderCrossSocket automatically

begin
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('pong');
    end);

  THorse.Listen(9000);   // unchanged from any existing Horse project
end.
```

That is all. Every existing middleware (`horse-jwt`, `horse-cors`, `horse-jhonson`, etc.) continues to work without modification because the provider only replaces the transport layer.

---

## HTTPS / TLS

### OpenSSL runtime — what to ship per OS

CrossSocket `dlopen`s / `LoadLibrary`s OpenSSL at startup. It is **not** statically linked into your binary. Both OpenSSL 1.1.x and 3.x are accepted — the provider probes for both at startup.

**Linux** — install via the distro package manager:

```bash
apt install libssl3 libcrypto3                       # Debian/Ubuntu 22.04+
apt install libssl1.1                                 # Ubuntu 20.04
dnf install openssl-libs                              # RHEL/Rocky/Alma 9.x
apk add openssl libcrypto3 libssl3                    # Alpine
```

For air-gapped or minimal containers, ship the matching `libssl.so` + `libcrypto.so` alongside the binary and set `LD_LIBRARY_PATH=/opt/yourapp` in the systemd unit.

**Windows** — ship the DLLs **next to your `.exe`** (not into `System32`, not into a globally-PATHed folder — co-locating with the binary avoids hijacking by other apps' bundled OpenSSL):

| Version | DLLs (Win64; drop `-x64` for Win32) |
|---|---|
| 1.1.x | `libssl-1_1-x64.dll`, `libcrypto-1_1-x64.dll` |
| 3.x | `libssl-3-x64.dll`, `libcrypto-3-x64.dll` |

Source: [official OpenSSL Windows builds](https://wiki.openssl.org/index.php/Binaries) or [SLProWeb installers](https://slproweb.com/products/Win32OpenSSL.html). Pick one version family and use it everywhere — dynamic-loading code for `libssl-1_1.dll` will not run on a host that has only `libcrypto-3.dll`, and the two cannot coexist in the same process. For Windows Service deployments, the DLLs must be in the same folder as the service `.exe`; the SCM does not inherit the user's `PATH`.

If neither OpenSSL family is reachable at startup, the binary still runs but `SSLEnabled := True` fails at `Listen`-time with a clear "no SSL backend available" error.

See the cross-provider OpenSSL section in [`horse/doc/deployment.md`](https://github.com/HashLoad/horse/blob/master/doc/deployment.md#https--tls-runtime---what-to-ship-per-os) for shared gotchas (version-mismatch SIGSEGV, dual-ABI conflicts, etc.).

### Config

Use `ListenWithConfig` and populate the SSL fields on `THorseCrossSocketConfig`. The config type lives in `Horse.Provider.Config`:

```delphi
uses
  Horse,
  Horse.Provider.Config;   // THorseCrossSocketConfig

var
  Cfg: THorseCrossSocketConfig;
begin
  THorse.Get('/ping', ...);

  Cfg                := THorseCrossSocketConfig.Default;
  Cfg.SSLEnabled     := True;
  Cfg.SSLCertFile    := 'cert.pem';
  Cfg.SSLKeyFile     := 'key.pem';
  Cfg.SSLKeyPassword := '';           // leave empty if key has no passphrase

  THorse.ListenWithConfig(9443, Cfg);
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

> **mTLS requires the two Delphi-Cross-Socket mTLS patches** (`Net.CrossSslSocket.Base.pas` + `Net.CrossSslSocket.OpenSSL.pas`) which add `SetCACertificate(File)` and `SetVerifyPeer(Boolean)` to `TCrossSslSocketBase` and `TCrossOpenSslSocket`. You can either:
>
> 1. **Use Path B** (the [`freitasjca/Delphi-Cross-Socket v1.0.3`](https://github.com/freitasjca/Delphi-Cross-Socket/releases/tag/v1.0.3) fork release) which ships these patches pre-applied — single clone, ready to go.
> 2. **Stay on Path A** (upstream) and apply the two mTLS patches manually per [Applying the Patches](#applying-the-patches). Recommended if you also want to file the upstream mTLS PR.
>
> If `SSLVerifyPeer = True` but the mTLS patches haven't been applied, the build will fail with `E2003 Undeclared identifier: 'SetCACertificateFile'` / `'SetVerifyPeer'`. There is no plan in `winddriver/Delphi-Cross-Socket` mainline yet for these APIs — an upstream PR is in preparation.

---

## Advanced Configuration

`THorseCrossSocketConfig.Default` provides production-safe values out of the box. Every field can be overridden:

```delphi
var Cfg := THorseCrossSocketConfig.Default;

// Timeouts
Cfg.KeepAliveTimeout := 30;     // seconds; 0 = disable keep-alive
Cfg.ReadTimeout      := 20;     // seconds — mitigates slow-HTTP attacks
Cfg.DrainTimeoutMs   := 5000;   // ms to wait for active requests on Stop

// Size limits
Cfg.MaxHeaderSize    := 8192;             // bytes (default: 8 KB)
Cfg.MaxBodySize      := 4 * 1024 * 1024; // bytes (default: 4 MB)

// Connection ceiling — prevents file-descriptor exhaustion DoS
Cfg.MaxConnections   := 10000;

// Response compression
Cfg.Compressible     := True;    // enable gzip/deflate for compressible content types
Cfg.MinCompressSize  := 512;     // bytes — skip compression for smaller bodies

// Suppress Server: header (default: 'unknown')
Cfg.ServerBanner     := '';

THorse.ListenWithConfig(9000, Cfg);
```

### Custom error logging

Worker-pool exceptions (and unhandled pipeline exceptions) are routed to a pluggable callback. The default writes to `ErrOutput`. Override it after `Listen`:

```delphi
THorse.Listen(9000);

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
        (Reset via Clear — never Free)
```

---

## Security Model

This provider was designed with a layered defence-in-depth approach. Every protection is enforced by default and cannot be accidentally disabled.

> **Scope note — CrossSocket only.** The input validation and transport protections in this section are implemented by `TRequestBridge.Populate` and `THorseCrossSocketServer`, which are part of this provider. They apply **only when `{$DEFINE HORSE_CROSSSOCKET}` is active**. The Indy provider (`Horse.Provider.Console`, `Horse.Provider.Daemon`, etc.) does not perform any of these checks — Indy passes every request directly to the Horse pipeline without validation. See [Equivalent protection on Indy](#equivalent-protection-on-indy) below for how to add these checks as Horse middleware when using Indy.

### Input validation — CrossSocket only (before the Horse pipeline is entered)

`TRequestBridge.Populate` runs these checks on every request. If any check fails, a `400 Bad Request` (or `405 Method Not Allowed`) is returned **directly** — the middleware chain and route handlers are never called. This means a malformed or oversized request cannot reach application code at all.

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

### Transport — CrossSocket only

| Protection | Default |
|---|---|
| `ReadTimeout` enforced | 20 s |
| `MaxBodySize` enforced | 4 MB |
| `MaxHeaderSize` enforced | 8 KB |
| `MaxConnections` ceiling | 10 000 |
| TLS 1.2 + 1.3, AEAD-only ciphers | when SSL enabled |
| Mutual TLS (client cert) | opt-in |
| `Server:` header suppressed | `unknown` |

### Response output — CrossSocket only

`TResponseBridge.Flush` applies these to every response sent through the CrossSocket provider. The Indy provider has no equivalent; add a Horse middleware if you need these on Indy (see below).

| Protection | Default |
|---|---|
| CRLF stripped from all header values | always |
| Hop-by-hop headers blocked | always |
| `X-Content-Type-Options: nosniff` | always |
| `X-Frame-Options: DENY` | always |
| `Referrer-Policy: strict-origin-when-cross-origin` | always |
| `Cache-Control: no-store` | always |

### Object pool — CrossSocket only

The context pool resets **every field** between requests — including `Session`, `Body`, `RemoteAddr`, and all middleware-injected values — before returning an object to the pool. A failed reset discards the context rather than returning it dirty.

The reset path calls `THorseRequest.Clear` and `THorseResponse.Clear` (not the `Body(nil)` setter). This is critical: the `Body(AObject)` setter always frees the existing `FBody` before assigning — correct for the Indy ownership model, but fatal on the CrossSocket path where `FBody` is a **non-owning** reference into CrossSocket's socket buffer. `Clear` sets `FBody := nil` directly without calling `Free`, preventing a double-free when CrossSocket later destroys the request object. (See `[SEC-9]` / `FIX-POOL-1` in `Pool.pas`.)

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

### Equivalent protection on Indy

When using the standard Indy provider (`Horse.Provider.Console`, `Horse.Provider.Daemon`, etc.), **none** of the CrossSocket input validation or response hardening is active. Indy hands every request directly to the Horse middleware chain without any pre-validation.

You can add equivalent protection as Horse middleware that runs before your application routes. Because it is registered with `THorse.Use`, it runs on **all providers** — including CrossSocket, where it is redundant but harmless.

#### Method allowlist + smuggling guard

```delphi
const
  ALLOWED_METHODS: array[0..6] of string = (
    'GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS');

THorse.Use(
  procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
  var
    LMethod, LCL, LTE: string;
    LAllowed: Boolean;
    M: string;
  begin
    LMethod := Req.Method.ToUpper;

    // Method allowlist — reject TRACE, CONNECT, and unknown verbs
    LAllowed := False;
    for M in ALLOWED_METHODS do
      if M = LMethod then begin LAllowed := True; Break; end;
    if not LAllowed then
    begin
      Res.Status(405).Send('Method Not Allowed');
      Exit;  // do NOT call Next
    end;

    // RFC 7230 §3.3.3 — reject CL + TE together (request-smuggling vector)
    LCL := Req.Headers['Content-Length'];
    LTE := Req.Headers['Transfer-Encoding'];
    if (LCL <> '') and (LTE <> '') then
    begin
      Res.Status(400).Send('Bad Request');
      Exit;
    end;

    Next;
  end);
```

#### Host header validation

```delphi
THorse.Use(
  procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
  var
    LHost: string;
    I: Integer;
    C: Char;
  begin
    LHost := Req.Headers['Host'];
    if LHost = '' then
    begin
      Res.Status(400).Send('Bad Request');
      Exit;
    end;
    // Reject non-printable characters (header-injection guard)
    for I := 1 to Length(LHost) do
    begin
      C := LHost[I];
      if (Ord(C) < 32) or (Ord(C) = 127) then
      begin
        Res.Status(400).Send('Bad Request');
        Exit;
      end;
    end;
    Next;
  end);
```

#### Security response headers

```delphi
THorse.Use(
  procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
  begin
    Next;  // call first so route handlers run, then add headers to the response
    Res.AddHeader('X-Content-Type-Options', 'nosniff');
    Res.AddHeader('X-Frame-Options', 'DENY');
    Res.AddHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
    Res.AddHeader('Cache-Control', 'no-store');
  end);
```

#### Size limits

Indy does not enforce request body or header size limits natively. Add a guard early in the middleware chain:

```delphi
const
  MAX_BODY_BYTES = 4 * 1024 * 1024;  // 4 MB

THorse.Use(
  procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
  begin
    if Assigned(Req.Body) and (Req.Body.Size > MAX_BODY_BYTES) then
    begin
      Res.Status(413).Send('Payload Too Large');
      Exit;
    end;
    Next;
  end);
```

> **Note:** On Indy, Indy has already read the full body into memory before the middleware runs — the size check above prevents application code from processing an oversized payload, but it does not prevent Indy from buffering it. For a hard limit that prevents buffering, configure Indy's `TIdHTTPServer.MaximumHeaderLineCount` and consider a reverse proxy (nginx, HAProxy) in front of the service.

---

## CI / CD

All CI files are in the repository root and work against the `samples/tests/` integration test suite.

### Prerequisites on the build agent (Windows)

| Requirement | Notes |
|---|---|
| Delphi 10.4 Sydney or later | Set `DELPHI_ROOT` env var to the install directory (e.g. `C:\Program Files (x86)\Embarcadero\Studio\22.0`) |
| [Boss](https://github.com/HashLoad/boss) in `PATH` | Resolves `boss.json` dependencies — the patched Horse and Delphi-Cross-Socket forks |
| PowerShell | Used by `run-tests.bat` for the server health-check (`Invoke-WebRequest`) |
| `.dproj` files committed | `samples/tests/HorseCSTestServer.dproj` and `HorseCSTestClient.dproj` must exist — see `samples/tests/README.md` for required IDE settings |

### How the pipeline works

```
boss install                    ↓ pulls Horse from HashLoad/horse

git clone Delphi-Cross-Socket   ↓ either upstream + cnvcl (Path A)
                                  or freitasjca v1.0.3 (Path B)

scripts\setup-search-paths.bat  ↓ injects search-path entries into .dproj

msbuild HorseCSTestServer.dproj  (HORSE_CROSSSOCKET defined, Win64 Release)
msbuild HorseCSTestClient.dproj  (Win64 Release)
    ↓

scripts\run-tests.bat
    1. start HorseCSTestServer.exe in background (port 9100)
    2. poll GET /ping until server is ready (up to 10 s)
    3. run HorseCSTestClient.exe — 32 integration tests
    4. kill server unconditionally
    5. exit with client exit code (0 = all pass, N = N failures)
```

Expected baseline against either path: **80 passed / 1 failed** (the single failure is the documented Set-Cookie multi-value Horse-core limitation — `FCustomHeaders` is `TDictionary<string,string>` so two `Res.AddHeader('Set-Cookie', …)` calls keep only the last).

### Jenkins

`Jenkinsfile` at the repo root. Targets an agent labelled `windows && delphi`:

```groovy
// stages: Checkout → Install deps → Build → Integration tests → Archive
```

Run manually:

```bat
scripts\build.bat Release Win64
scripts\run-tests.bat Win64 Release
```

### GitHub Actions

`.github/workflows/ci.yml` — triggers on push to `main`/`develop` and on pull requests. Requires a self-hosted runner registered with the `delphi` label (Repository → Settings → Actions → Runners).

### MSBuild parameters reference

| Parameter | Value | Purpose |
|---|---|---|
| `/t:Build` | — | Compile the project |
| `/t:Clean` | — | Remove all output files |
| `/p:Config=Release` | Release \| Debug | Build configuration |
| `/p:Platform=Win64` | Win64 \| Win32 | Target platform |
| `/m` | — | Parallel compilation (multi-core) |
| `/nologo` | — | Suppress MSBuild version banner |

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
| Mutual TLS | ✓ (requires Delphi-Cross-Socket patch) |
| Windows (IOCP) | ✓ |
| Linux (epoll) | ✓ |
| macOS (kqueue) | ✓ via CrossSocket |
| VCL / Apache / CGI / ISAPI providers | not applicable — separate providers |

---

## File Reference

```
src/
├── Horse.Provider.CrossSocket.pas               Main provider — THorseProviderCrossSocket
├── Horse.Provider.CrossSocket.Server.pas        TCrossHttpServer wrapper + THorseCrossSocketConfig
├── Horse.Provider.CrossSocket.Pool.pas          Thread-safe context object pool
├── Horse.Provider.CrossSocket.Request.pas       ICrossHttpRequest → THorseRequest bridge + validation
├── Horse.Provider.CrossSocket.Response.pas      THorseResponse → ICrossHttpResponse bridge
├── Horse.Provider.CrossSocket.WorkerPool.pas    CPU-bound worker thread pool
├── Horse.Provider.CrossSocket.WebRequestAdapter.pas   TCrossSocketWebRequest (backward compat)
├── Horse.Provider.CrossSocket.WebResponseAdapter.pas  TCrossSocketWebResponse (backward compat)
├── Horse.Provider.CrossSocket.RawRequest.pas    TCrossSocketRawRequest — IHorseRawRequest impl
└── Horse.Provider.CrossSocket.RawResponse.pas   TCrossSocketRawResponse — IHorseRawResponse impl

patches/
├── horse/src/
│   ├── Horse.pas                   — PATCH-HORSE-1: incompatible define guard + CrossSocket switch
│   ├── Horse.Request.pas           — PATCH-REQ-*: no-arg ctor, Clear, shadow fields, nil-guards, SetBodyString
│   ├── Horse.Response.pas          — PATCH-RES-*: Clear, shadow fields, CustomHeaders, ContentStream
│   ├── Horse.Core.RouterTree.pas   — PATCH-TREE-1: nil-guard for RawWebRequest in Execute
│   ├── Horse.Provider.Abstract.pas — PATCH-ABS-*: ListenWithConfig, Execute, MaxConnections no-op
│   ├── Horse.Provider.Config.pas   — THorseCrossSocketConfig record (new file)
│   ├── Horse.Session.pas           — PATCH-SES-1: Clear procedure for pool reuse
│   ├── Horse.Provider.RawInterfaces.pas  — NEW: IHorseRawRequest + IHorseRawResponse interfaces
│   ├── Horse.Provider.RawAdapters.pas    — NEW: TInterfacedWebRequest/TInterfacedWebResponse
│   └── Horse.Provider.{Console,Daemon,VCL,FPC.*}.pas  — updated concrete providers
└── Delphi-Cross-Socket/Net/
    ├── Net.CrossSslSocket.OpenSSL.pas  — mTLS support
    └── Net.CrossSocket.Iocp.pas        — DEBUG-build shutdown fix

samples/
└── server.dpr                              Minimal working server example
```

### Unit responsibilities

**`Horse.Provider.CrossSocket`**
Entry point. `THorseProviderCrossSocket.Listen(port)` or `ListenWithConfig(port, config)`. Wires CrossSocket's `OnRequest` callback to the validation → pool → pipeline → flush cycle. Tracks active requests for graceful shutdown.

**`Horse.Provider.CrossSocket.Server`**
Wraps `TCrossHttpServer`. Owns `THorseCrossSocketConfig` (all timeouts, size limits, SSL settings). `Stop` is synchronous — it waits up to `DrainTimeoutMs` for active requests to finish before returning.

**`Horse.Provider.CrossSocket.Pool`**
Pre-allocates `THorseContext` objects at startup and reuses them across requests via `Acquire` / `Release`. `Reset` calls `THorseRequest.Clear` and `THorseResponse.Clear` — never the `Body(nil)` setter, which would free CrossSocket's non-owning stream reference and produce `EInvalidPointer` on every POST request (`FIX-POOL-1`). In `DEBUG` builds, poison values detect partial-reset bugs immediately.

**`Horse.Provider.CrossSocket.Request`**
`TRequestBridge.Populate` validates and translates `ICrossHttpRequest` into `THorseRequest`. Returns `rvOK`, `rvBadRequest`, or `rvMethodNotAllowed` — the pipeline is never entered for invalid requests.

**`Horse.Provider.CrossSocket.Response`**
`TResponseBridge.Flush` translates `THorseResponse` into the CrossSocket response. Strips CRLF from all header values, blocks hop-by-hop headers, and injects default security headers.

**`Horse.Provider.CrossSocket.WorkerPool`**
Fixed-size worker thread pool for CPU-bound tasks. Bounded queue (4 096), pluggable error callback, named threads, graceful drain on shutdown.

**`Horse.Provider.CrossSocket.RawRequest`** / **`Horse.Provider.CrossSocket.RawResponse`**
Implement `IHorseRawRequest` / `IHorseRawResponse` by wrapping `ICrossHttpRequest` / `ICrossHttpResponse` in ~15 / ~1 one-liner methods. These are the CrossSocket-specific adapters.

**`Horse.Provider.CrossSocket.WebRequestAdapter`** / **`Horse.Provider.CrossSocket.WebResponseAdapter`**
Thin constructors that create a `TCrossSocketWebRequest` / `TCrossSocketWebResponse` — backward-compatible subclasses of `TInterfacedWebRequest` / `TInterfacedWebResponse` (from `Horse.Provider.RawAdapters`). Assigned to `THorseRequest.RawWebRequest` and `THorseResponse.RawWebResponse` so existing middleware that calls `Req.RawWebRequest.Method` or `Res.RawWebResponse.SetCustomHeader` works without modification.

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
