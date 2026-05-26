# Building a Horse Provider with mORMot2

## mORMot2 overview

[mORMot2](https://github.com/synopse/mORMot2) is a high-performance open-source framework for Delphi and Free Pascal. Its HTTP server layer uses **IOCP on Windows** and **epoll on Linux/BSD** — the same async I/O primitives as CrossSocket, nginx, and Go's `net/http`. It is one of the fastest HTTP server implementations available in the Delphi/FPC ecosystem.

mORMot2's HTTP server exposes a single `THttpServerRequest` object per request that carries both input (method, URL, headers, body) and output (status, body, headers) properties. This unified design maps cleanly onto the Horse hybrid interface architecture.

### Why mORMot2 as a Horse transport

| Advantage | Detail |
|---|---|
| Async I/O | IOCP (Windows) / epoll (Linux) / kqueue (macOS) via `TPollAsyncSockets` |
| Mature codebase | 15+ years of production use, actively maintained |
| Broad compiler support | Delphi 7 through 12.3, FPC 3.2.0+ |
| Cross-platform | Windows, Linux, BSD, macOS (server); Android, iOS (client) |
| HTTP/1.1 + WebSocket | Full HTTP/1.1 with keep-alive, WebSocket upgrade |
| http.sys integration | `THttpApiServer` uses the Windows kernel HTTP stack for maximum Windows performance |
| No external dependencies | Pure Pascal — no OpenSSL or libc dependency for basic HTTP (OpenSSL optional for TLS) |

---

## Requirements

### Compiler versions

| Compiler | Minimum version | Recommended |
|---|---|---|
| Delphi | 7 (limited), XE+ (full) | 10.4 Sydney or later |
| Free Pascal | 3.2.0 | 3.2.2+ |

### Platform support

| Platform | Server | Client |
|---|---|---|
| Windows x86/x64 | Yes | Yes |
| Linux x64 | Yes (epoll) | Yes |
| macOS x64/ARM64 | Yes | Yes |
| FreeBSD | Yes | Yes |
| Android | No | Yes |
| iOS | No | Yes |

### Static binaries (required for some features)

mORMot2 relies on pre-compiled static libraries for SQLite3, OpenSSL bindings, and other optional C components. Even if you only use the HTTP server, download the static binaries matching your platform:

| Platform | URL |
|---|---|
| All platforms (archive) | https://synopse.info/files/mormot2static.tgz |
| GitHub releases | https://github.com/niccolobrogi/mORMot2-static/releases |

---

## Installation

### Option A — Git clone (recommended)

```bash
# Clone mORMot2 into a shared location
cd C:\lang\Repo
git clone https://github.com/synopse/mORMot2.git

# Download static binaries (extract into mORMot2/static/)
# Windows: download from https://synopse.info/files/mormot2static.tgz
# Linux:
cd mORMot2
mkdir -p static
curl -L https://synopse.info/files/mormot2static.tgz | tar xz -C static/
```

### Option B — ZIP download

1. Download from https://github.com/synopse/mORMot2/archive/refs/heads/master.zip
2. Extract to `C:\lang\Repo\mORMot2`
3. Download and extract static binaries as above

### Delphi IDE setup

1. Open **Tools > Options > Language > Delphi > Library**
2. Add the following to **Library Path** (adjust base path as needed):

```
C:\lang\Repo\mORMot2\src
C:\lang\Repo\mORMot2\src\core
C:\lang\Repo\mORMot2\src\net
C:\lang\Repo\mORMot2\src\lib
C:\lang\Repo\mORMot2\src\app
C:\lang\Repo\mORMot2\src\rest
C:\lang\Repo\mORMot2\src\orm
C:\lang\Repo\mORMot2\src\db
C:\lang\Repo\mORMot2\src\script
C:\lang\Repo\mORMot2\src\ui
```

> **Tip:** For a minimal HTTP-only provider, the paths you strictly need are `src`, `src/core`, `src/net`, and `src/lib`.

3. Optionally install the design-time package:
   - Open `src/packages/delphi/mormot2.dpk`
   - Right-click > Install

### Lazarus / FPC setup

1. Open `src/packages/lazarus/mormot2.lpk` in the Lazarus IDE
2. Compile the package
3. Install it (only needed for design-time components; the HTTP server works without installation)
4. Add the same source paths to your project's search path

### Verify installation

Create a minimal console app:

```pascal
program TestMormot;

{$APPTYPE CONSOLE}

uses
  mormot.core.base,
  mormot.net.server;

begin
  WriteLn('mORMot2 version: ', SYNOPSE_FRAMEWORK_VERSION);
  WriteLn('Installation OK.');
  ReadLn;
end.
```

If this compiles and runs, mORMot2 is correctly installed.

### Boss package manager

mORMot2 does **not** ship a `boss.json` and is not available via Boss. Use Git clone or ZIP download.

---

## mORMot2 HTTP server key classes

All classes are in unit **`mormot.net.server`**.

| Class | Role |
|---|---|
| `THttpServer` | Main socket-based HTTP/1.1 server (thread-pool, non-blocking) |
| `THttpApiServer` | Windows http.sys kernel-mode server (highest Windows performance) |
| `THttpServerRequest` | Unified request+response context passed to your callback |

### `THttpServerRequest` properties

**Input (read from the client):**

| Property | Type | Description |
|---|---|---|
| `Method` | `RawUtf8` | HTTP method: `'GET'`, `'POST'`, etc. |
| `Url` | `RawUtf8` | Full request URL including query string |
| `InHeaders` | `RawUtf8` | All request headers as a single CRLF-delimited string |
| `InContent` | `RawByteString` | Request body bytes |
| `InContentType` | `RawUtf8` | `Content-Type` request header |
| `Host` | `RawUtf8` | `Host` header value |
| `RemoteIP` | `RawUtf8` | Client IP address |

**Output (written back to the client):**

| Property | Type | Description |
|---|---|---|
| `OutContent` | `RawByteString` | Response body bytes |
| `OutContentType` | `RawUtf8` | Response `Content-Type` header |
| `OutCustomHeaders` | `RawUtf8` | Custom response headers (CRLF-delimited) |
| `OutStatus` | `Integer` | HTTP status code (200, 404, 500, etc.) |

### Callback type

```pascal
TOnHttpServerRequest = function(Ctxt: THttpServerRequestAbstract): cardinal of object;
```

The callback receives a `THttpServerRequestAbstract` (which is `THttpServerRequest` at runtime), reads input properties, writes output properties, and returns the HTTP status code as the function result.

### Minimal mORMot2 HTTP server

```pascal
program MormotMinimal;

{$APPTYPE CONSOLE}

uses
  mormot.core.base,
  mormot.core.os,
  mormot.net.server;

type
  TMyServer = class
    function Process(Ctxt: THttpServerRequestAbstract): cardinal;
  end;

function TMyServer.Process(Ctxt: THttpServerRequestAbstract): cardinal;
begin
  Ctxt.OutContent     := '{"status":"ok"}';
  Ctxt.OutContentType := 'application/json';
  Result := 200;
end;

var
  Handler: TMyServer;
  Server:  THttpServer;
begin
  Handler := TMyServer.Create;
  try
    Server := THttpServer.Create('8080', nil, nil, '', 4);
    try
      Server.OnRequest := Handler.Process;
      WriteLn('Listening on http://127.0.0.1:8080');
      WriteLn('Press ENTER to stop...');
      ReadLn;
    finally
      Server.Free;
    end;
  finally
    Handler.Free;
  end;
end.
```

---

## Architecture overview

The hybrid interface architecture lets you build a mORMot2 provider by implementing only ~15 methods for the request side and ~1 for the response side. All 30+ `TWebRequest`/`TWebResponse` abstract method stubs are handled by the generic adapters.

```
THttpServerRequest (mormot.net.server)
      |
      v
TMormotRawRequest : TInterfacedObject, IHorseRawRequest    <-- you write this (~15 methods)
      |
      v
TInterfacedWebRequest (Horse.Provider.RawAdapters)          <-- already exists, delegates stubs
      |
      v
TMormotWebRequest : TInterfacedWebRequest                   <-- thin subclass, 1 constructor
      |
      v
THorseRequest.RawWebRequest                                 <-- returns TWebRequest (unchanged API)
      |
      v
Middleware (Horse.CORS, horse-jwt, etc.)                    <-- works unchanged
```

Same pattern on the response side:

```
THttpServerRequest (same object — mORMot uses one object for both)
      |
TMormotRawResponse : TInterfacedObject, IHorseRawResponse   <-- you write this (~1 method)
      |
TInterfacedWebResponse (Horse.Provider.RawAdapters)          <-- already exists
      |
TMormotWebResponse : TInterfacedWebResponse                  <-- thin subclass, 1 constructor
      |
THorseResponse.RawWebResponse                                <-- returns TWebResponse (unchanged API)
```

---

## Prerequisites

Your Horse fork must include these patched units (all in `patches/horse/src/`):

| Unit | What it provides |
|---|---|
| `Horse.pas` | PATCH-HORSE-1 `{$MESSAGE FATAL}` guard against incompatible provider defines |
| `Horse.Provider.RawInterfaces.pas` | `IHorseRawRequest` + `IHorseRawResponse` interface definitions |
| `Horse.Provider.RawAdapters.pas` | `TInterfacedWebRequest` + `TInterfacedWebResponse` generic adapter classes |
| `Horse.Provider.Abstract.pas` | `ListenWithConfig`, `Execute`, `MaxConnections` virtual class methods (PATCH-ABS-2/3/4) |
| `Horse.Provider.Config.pas` | `THorseCrossSocketConfig` record (shared config type) |
| `Horse.Request.pas` | Shadow fields, `Clear` (PATCH-REQ-2), `Populate` (PATCH-REQ-3), `SetCSRawWebRequest` (PATCH-REQ-8), `SetBodyString` body cache (PATCH-REQ-9), `Method: string` (PATCH-REQ-10) |
| `Horse.Response.pas` | Shadow fields, `Clear` (PATCH-RES-2), `SetCSRawWebResponse` (PATCH-RES-6), nil-guards (PATCH-RES-4), lazy `EnsureCustomHeaders` (PATCH-RES-7) |
| `Horse.Session.pas` | `THorseSessions.Clear` for in-place pool reset (PATCH-SES-1) |
| `Horse.Core.RouterTree.pas` | `RawPathInfo` and `MethodType`-based dispatch (PATCH-TREE-1 / PATCH-REQ-5) |

---

## Step-by-step implementation

### Step 1 — Implement `IHorseRawRequest`

Create `Horse.Provider.Mormot.RawRequest.pas`:

```pascal
unit Horse.Provider.Mormot.RawRequest;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$ENDIF}
  mormot.core.base,
  mormot.net.server,
  Horse.Provider.RawInterfaces;

type
  TMormotRawRequest = class(TInterfacedObject, IHorseRawRequest)
  private
    FCtxt:          THttpServerRequestAbstract;
    FContentCache:  string;
    FContentCached: Boolean;
    FPathInfo:      string;
    FQueryString:   string;
    FPathParsed:    Boolean;
    procedure ParsePath;
  public
    constructor Create(const ACtxt: THttpServerRequestAbstract);

    { IHorseRawRequest }
    function  GetMethod: string;
    function  GetProtocolVersion: string;
    function  GetURL: string;
    function  GetPathInfo: string;
    function  GetQueryString: string;
    function  GetHost: string;
    function  GetRemoteAddr: string;
    function  GetServerPort: Integer;
    function  GetContentType: string;
    function  GetContent: string;
{$IF DEFINED(FPC)}
    function  GetContentLength: Integer;
{$ELSEIF CompilerVersion >= 32.0}
    function  GetContentLength: Int64;
{$ELSE}
    function  GetContentLength: Integer;
{$IFEND}
    function  GetFieldByName(const AName: string): string;
    procedure PopulateQueryFields(ADest: TStrings);
    procedure PopulateContentFields(ADest: TStrings);
    procedure PopulateCookieFields(ADest: TStrings);
    function  ReadBody(var Buffer; Count: Integer): Integer;
  end;

implementation

constructor TMormotRawRequest.Create(const ACtxt: THttpServerRequestAbstract);
begin
  inherited Create;
  FCtxt          := ACtxt;
  FContentCached := False;
  FPathParsed    := False;
end;

procedure TMormotRawRequest.ParsePath;
var
  S: string;
  QPos: Integer;
begin
  if FPathParsed then Exit;
  // mORMot's Url contains path + query string
  S := Utf8ToString(FCtxt.Url);
  QPos := Pos('?', S);
  if QPos > 0 then
  begin
    FPathInfo    := Copy(S, 1, QPos - 1);
    FQueryString := Copy(S, QPos + 1, MaxInt);
  end
  else
  begin
    FPathInfo    := S;
    FQueryString := '';
  end;
  FPathParsed := True;
end;

function TMormotRawRequest.GetMethod: string;
begin
  Result := Utf8ToString(FCtxt.Method);
end;

function TMormotRawRequest.GetProtocolVersion: string;
begin
  Result := 'HTTP/1.1';
end;

function TMormotRawRequest.GetURL: string;
begin
  Result := Utf8ToString(FCtxt.Url);
end;

function TMormotRawRequest.GetPathInfo: string;
begin
  ParsePath;
  Result := FPathInfo;
end;

function TMormotRawRequest.GetQueryString: string;
begin
  ParsePath;
  Result := FQueryString;
end;

function TMormotRawRequest.GetHost: string;
begin
  Result := Utf8ToString(FCtxt.Host);
end;

function TMormotRawRequest.GetRemoteAddr: string;
begin
  Result := Utf8ToString(FCtxt.RemoteIP);
end;

function TMormotRawRequest.GetServerPort: Integer;
begin
  // mORMot does not directly expose local port on the request object.
  // Parse from Host header (host:port) or store from server config.
  // Fallback: return 0 and let the provider set it from its own FPort.
  Result := 0;
end;

function TMormotRawRequest.GetContentType: string;
begin
  Result := Utf8ToString(FCtxt.InContentType);
end;

function TMormotRawRequest.GetContent: string;
begin
  if FContentCached then Exit(FContentCache);
  // InContent is RawByteString — convert to UTF-8 string
  FContentCache  := Utf8ToString(RawUtf8(FCtxt.InContent));
  FContentCached := True;
  Result := FContentCache;
end;

{$IF DEFINED(FPC)}
function TMormotRawRequest.GetContentLength: Integer;
{$ELSEIF CompilerVersion >= 32.0}
function TMormotRawRequest.GetContentLength: Int64;
{$ELSE}
function TMormotRawRequest.GetContentLength: Integer;
{$IFEND}
begin
  Result := Length(FCtxt.InContent);
end;

function TMormotRawRequest.GetFieldByName(const AName: string): string;
var
  LHeaders: string;
  LSearch:  string;
  LPos, LEnd: Integer;
begin
  // mORMot stores all headers as a single CRLF-delimited string.
  // Search for "Name: Value" pattern.
  Result := '';
  LHeaders := Utf8ToString(FCtxt.InHeaders);
  LSearch  := LowerCase(AName) + ': ';
  LPos := Pos(LSearch, LowerCase(LHeaders));
  if LPos > 0 then
  begin
    LPos := LPos + Length(LSearch);
    LEnd := Pos(#13, Copy(LHeaders, LPos, MaxInt));
    if LEnd = 0 then
      LEnd := Length(LHeaders) - LPos + 2;
    Result := Copy(LHeaders, LPos, LEnd - 1);
  end;
end;

procedure TMormotRawRequest.PopulateQueryFields(ADest: TStrings);
var
  S, Pair: string;
  AmpPos, EqPos: Integer;
begin
  S := GetQueryString;
  while S <> '' do
  begin
    AmpPos := Pos('&', S);
    if AmpPos > 0 then
    begin
      Pair := Copy(S, 1, AmpPos - 1);
      Delete(S, 1, AmpPos);
    end
    else
    begin
      Pair := S;
      S := '';
    end;
    EqPos := Pos('=', Pair);
    if EqPos > 0 then
      ADest.Add(Copy(Pair, 1, EqPos - 1) + '=' + Copy(Pair, EqPos + 1, MaxInt))
    else
      ADest.Add(Pair + '=');
  end;
end;

procedure TMormotRawRequest.PopulateContentFields(ADest: TStrings);
var
  S: string;
begin
  // Only for application/x-www-form-urlencoded bodies
  if Pos('application/x-www-form-urlencoded', LowerCase(GetContentType)) > 0 then
  begin
    S := GetContent;
    // Reuse the same key=value&key=value parsing as query fields
    while S <> '' do
    begin
      var AmpPos := Pos('&', S);
      var Pair: string;
      if AmpPos > 0 then
      begin
        Pair := Copy(S, 1, AmpPos - 1);
        Delete(S, 1, AmpPos);
      end
      else
      begin
        Pair := S;
        S := '';
      end;
      ADest.Add(Pair);
    end;
  end;
end;

procedure TMormotRawRequest.PopulateCookieFields(ADest: TStrings);
var
  S, Pair: string;
  SemiPos: Integer;
begin
  S := Trim(GetFieldByName('Cookie'));
  while S <> '' do
  begin
    SemiPos := Pos(';', S);
    if SemiPos > 0 then
    begin
      Pair := Trim(Copy(S, 1, SemiPos - 1));
      Delete(S, 1, SemiPos);
      S := TrimLeft(S);
    end
    else
    begin
      Pair := Trim(S);
      S := '';
    end;
    if Pair <> '' then
      ADest.Add(Pair);
  end;
end;

function TMormotRawRequest.ReadBody(var Buffer; Count: Integer): Integer;
var
  LLen: Integer;
begin
  LLen := Length(FCtxt.InContent);
  if LLen = 0 then Exit(0);
  if Count > LLen then
    Count := LLen;
  Move(FCtxt.InContent[1], Buffer, Count);
  Result := Count;
end;

end.
```

> **Note on `RawUtf8` / `RawByteString`:** mORMot uses `RawUtf8` (an alias for `AnsiString` with UTF-8 codepage) throughout. The `Utf8ToString` function converts to the Delphi `string` type (UTF-16 on Delphi, UTF-8 on FPC). Use it at the boundary between mORMot and Horse.

> **Note on `PopulateContentFields`:** The implementation above uses inline `var` declarations for brevity. For pre-10.3 Delphi (10.2 and earlier) and FPC compatibility, move them to a `var` block before `begin`. See the Critical Rules section.

### Step 2 — Implement `IHorseRawResponse`

Create `Horse.Provider.Mormot.RawResponse.pas`:

```pascal
unit Horse.Provider.Mormot.RawResponse;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  mormot.core.base,
  mormot.net.server,
  Horse.Provider.RawInterfaces;

type
  TMormotRawResponse = class(TInterfacedObject, IHorseRawResponse)
  private
    FCtxt: THttpServerRequestAbstract;
  public
    constructor Create(const ACtxt: THttpServerRequestAbstract);
    procedure SetCustomHeader(const AName, AValue: string);
  end;

implementation

constructor TMormotRawResponse.Create(const ACtxt: THttpServerRequestAbstract);
begin
  inherited Create;
  FCtxt := ACtxt;
end;

procedure TMormotRawResponse.SetCustomHeader(const AName, AValue: string);
begin
  { Header writes are captured by TInterfacedWebResponse's inherited
    CustomHeaders TStrings. This method exists for providers that want
    to forward headers to the transport in real time.

    mORMot option: you can also write directly to OutCustomHeaders here
    for immediate header forwarding:
      FCtxt.OutCustomHeaders := FCtxt.OutCustomHeaders +
        StringToUtf8(AName + ': ' + AValue + #13#10);
    But the response bridge already does this at flush time, so this
    is a no-op for the standard flow. }
end;

end.
```

### Step 3 — Create thin `TWebRequest`/`TWebResponse` subclasses

`Horse.Provider.Mormot.WebRequestAdapter.pas`:

```pascal
unit Horse.Provider.Mormot.WebRequestAdapter;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, fpHTTP, HTTPDefs,
{$ELSE}
  System.SysUtils, System.Classes, Web.HTTPApp,
{$ENDIF}
  mormot.core.base,
  mormot.net.server,
  Horse.Provider.RawAdapters,
  Horse.Provider.Mormot.RawRequest;

type
  TMormotWebRequest = class(TInterfacedWebRequest)
  public
    constructor Create(const ACtxt: THttpServerRequestAbstract); reintroduce;
  end;

implementation

constructor TMormotWebRequest.Create(const ACtxt: THttpServerRequestAbstract);
begin
  inherited Create(TMormotRawRequest.Create(ACtxt));
end;

end.
```

`Horse.Provider.Mormot.WebResponseAdapter.pas`:

```pascal
unit Horse.Provider.Mormot.WebResponseAdapter;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, fpHTTP, HTTPDefs,
{$ELSE}
  System.SysUtils, System.Classes, Web.HTTPApp,
{$ENDIF}
  mormot.core.base,
  mormot.net.server,
  Horse.Provider.RawAdapters,
  Horse.Provider.Mormot.RawResponse;

type
  TMormotWebResponse = class(TInterfacedWebResponse)
  public
    constructor Create(const ACtxt: THttpServerRequestAbstract); reintroduce;
  end;

implementation

constructor TMormotWebResponse.Create(const ACtxt: THttpServerRequestAbstract);
begin
  inherited Create(TMormotRawResponse.Create(ACtxt));
end;

end.
```

### Step 4 — Write the request bridge

`Horse.Provider.Mormot.Request.pas`:

```pascal
unit Horse.Provider.Mormot.Request;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$ENDIF}
  Horse,
  Horse.Commons,
  mormot.core.base,
  mormot.net.server;

type
  TRequestValidationResult = (rvOK, rvBadRequest, rvMethodNotAllowed);

  TMormotRequestBridge = class
  public
    class function Populate(
      const ACtxt:     THttpServerRequestAbstract;
      const AHorseReq: THorseRequest;
      out   ARejectReason: string
    ): TRequestValidationResult;
  end;

implementation

uses
  Horse.Provider.Mormot.WebRequestAdapter;

class function TMormotRequestBridge.Populate(
  const ACtxt:     THttpServerRequestAbstract;
  const AHorseReq: THorseRequest;
  out   ARejectReason: string
): TRequestValidationResult;
var
  LMethod, LUrl, LPath, LHost, LContentType, LRemoteAddr: string;
  LMethodType: TMethodType;
  QPos: Integer;
begin
  Result := rvOK;
  ARejectReason := '';

  // ── Extract values from mORMot request ────────────────────────────
  LMethod      := Utf8ToString(ACtxt.Method);
  LUrl         := Utf8ToString(ACtxt.Url);
  LHost        := Utf8ToString(ACtxt.Host);
  LContentType := Utf8ToString(ACtxt.InContentType);
  LRemoteAddr  := Utf8ToString(ACtxt.RemoteIP);

  // Split URL into path and query string
  QPos := Pos('?', LUrl);
  if QPos > 0 then
    LPath := Copy(LUrl, 1, QPos - 1)
  else
    LPath := LUrl;

  // ── Validation ────────────────────────────────────────────────────

  // Method allowlist
  if SameText(LMethod, 'CONNECT') or SameText(LMethod, 'TRACE') then
  begin
    ARejectReason := 'Method not allowed: ' + LMethod;
    Exit(rvMethodNotAllowed);
  end;

  // Host validation
  if LHost = '' then
  begin
    ARejectReason := 'Missing Host header';
    Exit(rvBadRequest);
  end;

  // Request smuggling: Content-Length + Transfer-Encoding
  if (Pos('content-length:', LowerCase(Utf8ToString(ACtxt.InHeaders))) > 0) and
     (Pos('transfer-encoding:', LowerCase(Utf8ToString(ACtxt.InHeaders))) > 0) then
  begin
    ARejectReason := 'Ambiguous body framing (CL + TE)';
    Exit(rvBadRequest);
  end;

  // ── Probe-only mode (AHorseReq = nil) — validate without populating ─
  if AHorseReq = nil then
    Exit;

  // ── Map method string to TMethodType ──────────────────────────────
  if SameText(LMethod, 'GET')         then LMethodType := mtGet
  else if SameText(LMethod, 'POST')   then LMethodType := mtPost
  else if SameText(LMethod, 'PUT')    then LMethodType := mtPut
  else if SameText(LMethod, 'DELETE') then LMethodType := mtDelete
  else if SameText(LMethod, 'PATCH')  then LMethodType := mtPatch
  else if SameText(LMethod, 'HEAD')   then LMethodType := mtHead
  else LMethodType := mtAny;

  // ── Populate THorseRequest shadow fields ──────────────────────────
  // Signature: (AMethod, AMethodType, APath, AContentType, ARemoteAddr).
  // AMethodType is the 2nd parameter — NOT the last. See PATCH-REQ-3.
  AHorseReq.Populate(LMethod, LMethodType, LPath, LContentType, LRemoteAddr);

  // ── Body ──────────────────────────────────────────────────────────
  // mORMot's InContent is a RawByteString (already fully buffered).
  //
  // Two complementary writes are needed:
  //   1. SetBodyString — populates the PATCH-REQ-9 UTF-8 cache so that
  //      Req.Body : string is O(1) and idempotent across multiple reads.
  //   2. Body(LStream) — exposes the bytes via Req.Body<TStream> for
  //      middleware that expects a TStream (e.g. file-upload handlers).
  //
  // Ownership: Unlike CrossSocket — where the transport owns the stream
  // and FBody is non-owning (FIX-POOL-1 / SEC-9) — the mORMot bridge
  // creates LStream itself.  THorseRequest.Clear sets FBody := nil
  // without freeing; the stream must be tracked and freed by the
  // pipeline handler after Clear runs.  See TMormotHandler.Process in
  // Step 6 for the tracking pattern.
  if Length(ACtxt.InContent) > 0 then
  begin
    var LStream: TMemoryStream;
    LStream := TMemoryStream.Create;
    LStream.Write(ACtxt.InContent[1], Length(ACtxt.InContent));
    LStream.Position := 0;
    AHorseReq.Body(LStream);
    AHorseReq.SetBodyString(Utf8ToString(RawUtf8(ACtxt.InContent)));
  end;

  // ── Headers → THorseRequest.Headers dictionary ────────────────────
  // Parse mORMot's CRLF-delimited InHeaders into Horse's header dict.
  // (Omitted for brevity — iterate lines, split on ': ', call
  //  AHorseReq.Headers[Name] := Value)

  // ── Cookies ───────────────────────────────────────────────────────
  var LCookie: string;
  LCookie := '';
  // Extract Cookie header from InHeaders
  var LPos: Integer;
  LPos := Pos('cookie: ', LowerCase(Utf8ToString(ACtxt.InHeaders)));
  if LPos > 0 then
  begin
    var LTemp: string;
    LTemp := Utf8ToString(ACtxt.InHeaders);
    LPos := LPos + Length('cookie: ');
    var LEnd: Integer;
    LEnd := Pos(#13, Copy(LTemp, LPos, MaxInt));
    if LEnd = 0 then
      LEnd := Length(LTemp) - LPos + 2;
    LCookie := Copy(LTemp, LPos, LEnd - 1);
  end;
  if LCookie <> '' then
    AHorseReq.PopulateCookiesFromHeader(LCookie);

  // ── RawWebRequest adapter (PATCH-REQ-8) ───────────────────────────
  AHorseReq.SetCSRawWebRequest(TMormotWebRequest.Create(ACtxt));
end;

end.
```

> **Note on inline `var`:** The code above uses inline variable declarations for clarity. For pre-10.3 Delphi or FPC compatibility, move all `var` declarations to the procedure's `var` block.

### Step 5 — Write the response bridge

`Horse.Provider.Mormot.Response.pas`:

```pascal
unit Horse.Provider.Mormot.Response;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, Generics.Collections,
{$ELSE}
  System.SysUtils, System.Classes, System.Generics.Collections,
{$ENDIF}
  Horse,
  mormot.core.base,
  mormot.net.server;

type
  TMormotResponseBridge = class
  public
    class procedure Flush(
      const AHorseRes: THorseResponse;
      const ACtxt:     THttpServerRequestAbstract;
      const ABanner:   string
    );
  end;

implementation

class procedure TMormotResponseBridge.Flush(
  const AHorseRes: THorseResponse;
  const ACtxt:     THttpServerRequestAbstract;
  const ABanner:   string
);
var
  LStatus:      Integer;
  LBody:        string;
  LContentType: string;
  LHeaders:     string;
  LPair:        TPair<string, string>;
  LStream:      TStream;
  LBytes:       TBytes;
  I:            Integer;
begin
  // ── Status ────────────────────────────────────────────────────────
  LStatus := AHorseRes.Status;
  if LStatus = 0 then
    LStatus := 200;
  ACtxt.OutStatus := LStatus;

  // ── Content-Type ──────────────────────────────────────────────────
  LContentType := AHorseRes.CSContentType;
  if LContentType <> '' then
    ACtxt.OutContentType := StringToUtf8(LContentType);

  // ── Custom headers ────────────────────────────────────────────────
  LHeaders := '';

  // Security headers
  LHeaders := LHeaders + 'X-Content-Type-Options: nosniff'#13#10;
  LHeaders := LHeaders + 'X-Frame-Options: DENY'#13#10;
  LHeaders := LHeaders + 'Cache-Control: no-store'#13#10;
  if ABanner <> '' then
    LHeaders := LHeaders + 'Server: ' + ABanner + #13#10
  else
    LHeaders := LHeaders + 'Server: unknown'#13#10;

  // Application headers (set via Res.AddHeader)
  if Assigned(AHorseRes.CustomHeaders) then
  begin
{$IF DEFINED(FPC)}
    for I := 0 to AHorseRes.CustomHeaders.Count - 1 do
      LHeaders := LHeaders +
        AHorseRes.CustomHeaders.Names[I] + ': ' +
        AHorseRes.CustomHeaders.ValueFromIndex[I] + #13#10;
{$ELSE}
    for LPair in AHorseRes.CustomHeaders do
      LHeaders := LHeaders + LPair.Key + ': ' + LPair.Value + #13#10;
{$ENDIF}
  end;

  // Also copy headers set via Res.RawWebResponse.SetCustomHeader
  // (these land in TInterfacedWebResponse.CustomHeaders TStrings)
  // The response bridge should iterate those too if present.

  ACtxt.OutCustomHeaders := StringToUtf8(LHeaders);

  // ── Body ──────────────────────────────────────────────────────────
  LStream := AHorseRes.ContentStream;
  if Assigned(LStream) then
  begin
    // Stream response (SendFile / Download)
    LStream.Position := 0;
    SetLength(LBytes, LStream.Size);
    if LStream.Size > 0 then
      LStream.Read(LBytes[0], LStream.Size);
    ACtxt.OutContent := RawByteString(TEncoding.UTF8.GetString(LBytes));
  end
  else
  begin
    LBody := AHorseRes.BodyText;
    if LBody <> '' then
      ACtxt.OutContent := StringToUtf8(LBody)
    else if LStatus >= 400 then
      ACtxt.OutContent := StringToUtf8(IntToStr(LStatus))
    else
      ACtxt.OutContent := '';
  end;
end;

end.
```

### Step 6 — Write the provider class

`Horse.Provider.Mormot.pas`:

```pascal
unit Horse.Provider.Mormot;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, SyncObjs,
{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs,
{$ENDIF}
  Horse.Exception,
  Horse.Provider.Abstract,
  Horse.Provider.Config,
  mormot.core.base,
  mormot.net.server;

type
  THorseProviderMormot = class(THorseProviderAbstract)
  private
    class var FServer:    THttpServer;
    class var FPort:      Integer;
    class var FStopEvent: TEvent;
    class var FRunning:   Boolean;

    class function  GetPort: Integer; static;
    class procedure SetPort(const AValue: Integer); static;

    // mORMot uses a method-of-object callback — this helper class provides it
    class var FHandler: TObject;  // see TMormotHandler below

  public
    class procedure ListenWithConfig(const APort: Integer;
      const AConfig: THorseCrossSocketConfig); override;
    class procedure StopListen; override;
    class procedure Listen; overload; override;
    class procedure Listen(APort: Integer); reintroduce; overload;
    class procedure Stop;

    class property Port: Integer read GetPort write SetPort;
  end;

implementation

uses
  Horse,
  Horse.Commons,
  Horse.Constants,
  Horse.Exception.Interrupted,
  Horse.Provider.Mormot.Request,
  Horse.Provider.Mormot.Response,
  Horse.Provider.Mormot.WebResponseAdapter;

type
  { mORMot requires a method-of-object for OnRequest.
    This helper class provides that method and calls the Horse pipeline. }
  TMormotHandler = class
  public
    function Process(Ctxt: THttpServerRequestAbstract): cardinal;
  end;

function TMormotHandler.Process(Ctxt: THttpServerRequestAbstract): cardinal;
var
  Ctx:          THorseContext;
  ValResult:    TRequestValidationResult;
  RejectReason: string;
  LBodyStream:  TMemoryStream;
begin
  // ── Validate before touching the pool ──────────────────────────────
  ValResult := TMormotRequestBridge.Populate(Ctxt, nil, RejectReason);

  if ValResult <> rvOK then
  begin
    case ValResult of
      rvMethodNotAllowed:
      begin
        Ctxt.OutStatus      := 405;
        Ctxt.OutContentType := 'application/json; charset=utf-8';
        Ctxt.OutContent     := '{"error":"Method Not Allowed"}';
        Ctxt.OutCustomHeaders := 'X-Content-Type-Options: nosniff'#13#10 +
          'X-Frame-Options: DENY'#13#10'Server: unknown'#13#10;
      end;
    else
      Ctxt.OutStatus      := 400;
      Ctxt.OutContentType := 'application/json; charset=utf-8';
      Ctxt.OutContent     := '{"error":"Bad Request"}';
      Ctxt.OutCustomHeaders := 'X-Content-Type-Options: nosniff'#13#10 +
        'X-Frame-Options: DENY'#13#10'Server: unknown'#13#10;
    end;
    Result := Ctxt.OutStatus;
    Exit;
  end;

  // ── Acquire context ────────────────────────────────────────────────
  // For production, use a context pool (see Horse.Provider.CrossSocket.Pool)
  Ctx := THorseContext.Create;
  LBodyStream := nil;
  try
    // Full population
    TMormotRequestBridge.Populate(Ctxt, Ctx.Request, RejectReason);

    // Track the body stream we created (if any) so we can free it.
    // Note: Ctx.Request.Body without a type argument returns the cached
    // string (PATCH-REQ-9). Use Body<TStream> to get the FBody object.
    if Length(Ctxt.InContent) > 0 then
      LBodyStream := Ctx.Request.Body<TMemoryStream>;

    // Wire up RawWebResponse for middleware like Horse.CORS
    Ctx.Response.SetCSRawWebResponse(TMormotWebResponse.Create(Ctxt));

    // ── Run the Horse pipeline ─────────────────────────────────────
    try
      THorse.Execute(Ctx.Request, Ctx.Response);
    except
      on EHorseCallbackInterrupted do
        ;  // normal pipeline completion

      on E: EHorseException do
      begin
        Ctx.Response.Status(E.Status);
        Ctx.Response.Send(Format('{"error":"%s"}', [E.Message]));
        Ctx.Response.ContentType('application/json; charset=utf-8');
      end;

      on E: Exception do
      begin
        WriteLn(ErrOutput, Format('[Mormot] Exception: %s: %s',
          [E.ClassName, E.Message]));
        Ctx.Response.Status(THTTPStatus.InternalServerError);
        Ctx.Response.Send('{"error":"Internal Server Error"}');
        Ctx.Response.ContentType('application/json; charset=utf-8');
      end;
    end;

    // ── Flush response to mORMot ───────────────────────────────────
    TMormotResponseBridge.Flush(Ctx.Response, Ctxt, '');

    Result := Ctxt.OutStatus;

  finally
    // Clear request BEFORE freeing the body stream
    Ctx.Request.Clear;
    // Now safe to free the stream we created in the bridge
    LBodyStream.Free;
    Ctx.Free;
  end;
end;

{ THorseProviderMormot }

class function THorseProviderMormot.GetPort: Integer;
begin
  Result := FPort;
end;

class procedure THorseProviderMormot.SetPort(const AValue: Integer);
begin
  FPort := AValue;
end;

class procedure THorseProviderMormot.Listen;
var
  LPort: Integer;
begin
  LPort := FPort;
  if LPort <= 0 then
    LPort := DEFAULT_PORT;
  ListenWithConfig(LPort, THorseCrossSocketConfig.Default);
end;

class procedure THorseProviderMormot.Listen(APort: Integer);
begin
  ListenWithConfig(APort, THorseCrossSocketConfig.Default);
end;

class procedure THorseProviderMormot.ListenWithConfig(
  const APort: Integer; const AConfig: THorseCrossSocketConfig);
var
  LHandler: TMormotHandler;
begin
  if Assigned(FServer) then
    Stop;

  LHandler := TMormotHandler.Create;
  FHandler := LHandler;

  // THttpServer constructor: (aPort, aOnRequest, aOnThreadStart,
  //   aHttpServerKind, aServerThreadPoolCount, aKeepAliveTimeOut)
  // Pass port as string, nil for thread callbacks, 4 threads default
  FServer := THttpServer.Create(
    StringToUtf8(IntToStr(APort)),  // port as UTF-8 string
    nil,                             // OnStart callback
    nil,                             // OnStop callback
    '',                              // server name
    4                                // thread pool count
  );
  FServer.OnRequest := LHandler.Process;

  FPort := APort;
  DoOnListen;

  // PATCH-LISTEN-1 — block the main thread in console apps so RTL
  // finalisation does not run while IO threads are still processing
  // requests. StopListen sets FRunning := False, joins server threads,
  // then signals FStopEvent to release this WaitFor. Without this guard
  // a console process can either (a) exit while requests are in flight
  // or (b) hang on shutdown because finalizers race with worker joins.
  if IsConsole then
  begin
    FRunning := True;
    if not Assigned(FStopEvent) then
      FStopEvent := TEvent.Create(nil, True, False, '');
    while FRunning do
      FStopEvent.WaitFor(INFINITE);
    FreeAndNil(FStopEvent);
  end;
end;

class procedure THorseProviderMormot.StopListen;
begin
  Stop;
  DoOnStopListen;
end;

class procedure THorseProviderMormot.Stop;
begin
  FRunning := False;

  if Assigned(FServer) then
  begin
    FServer.Free;
    FServer := nil;
  end;

  FreeAndNil(FHandler);

  if Assigned(FStopEvent) then
    FStopEvent.SetEvent;
end;

end.
```

### Step 7 — Register the provider in `Horse.pas`

PATCH-HORSE-2 reserves **`HORSE_PROVIDER_MORMOT`** as the canonical define for this provider (listed in the *reserved* column of the three-axis table). Add the new `{$ELSEIF}` branch under the Stage 2 (self-hosted) Provider selection:

```pascal
// Horse.pas — uses clause (Stage 2)
{$ELSEIF DEFINED(HORSE_PROVIDER_MORMOT)}
  Horse.Provider.Mormot,

// Horse.pas — THorseProvider type alias chain (parallel structure)
{$ELSEIF DEFINED(HORSE_PROVIDER_MORMOT)}
  THorseProvider = Horse.Provider.Mormot.THorseProviderMormot;
```

Users activate it with `{$DEFINE HORSE_PROVIDER_MORMOT}` in project options. Optionally add a legacy alias `HORSE_MORMOT` in the alias block at the top of `Horse.pas` if you want to ship an informal short name. Cross-product Application-type wrappers (VCL host, Windows Service, Linux daemon) follow the `Horse.Provider.CrossSocket.*` pattern — see the five worked examples there.

---

## File checklist

| File | Lines of code | What you write |
|---|---|---|
| `Horse.Provider.Mormot.RawRequest.pas` | ~160 | `IHorseRawRequest` implementation (~15 methods wrapping `THttpServerRequestAbstract`) |
| `Horse.Provider.Mormot.RawResponse.pas` | ~30 | `IHorseRawResponse` implementation (1 method, usually a no-op) |
| `Horse.Provider.Mormot.WebRequestAdapter.pas` | ~15 | Thin subclass: 1 constructor |
| `Horse.Provider.Mormot.WebResponseAdapter.pas` | ~15 | Thin subclass: 1 constructor |
| `Horse.Provider.Mormot.Request.pas` | ~100 | Request bridge: validation + `Populate` + `SetCSRawWebRequest` |
| `Horse.Provider.Mormot.Response.pas` | ~70 | Response bridge: read shadow fields, write `OutContent`/`OutCustomHeaders`/`OutStatus` |
| `Horse.Provider.Mormot.pas` | ~130 | Provider class: `Listen`/`Stop`/`TMormotHandler.Process` |
| **Total** | **~520** | |

---

## What the generic adapters handle for you

These are the `TWebRequest` / `TWebResponse` abstract methods that `TInterfacedWebRequest` / `TInterfacedWebResponse` stub or delegate automatically. You never touch any of them:

### `TInterfacedWebRequest` (Delphi)

| Method | How the adapter handles it |
|---|---|
| `GetStringVariable(Index)` | 29-case dispatch to `IHorseRawRequest.GetMethod`, `GetHost`, `GetPathInfo`, `GetFieldByName(...)`, etc. |
| `GetDateVariable(Index)` | Returns `0` |
| `GetIntegerVariable(Index)` | Delegates `ContentLength` and `ServerPort` to `IHorseRawRequest` |
| `GetRawContent` | Calls `IHorseRawRequest.GetContent` then UTF-8 bytes |
| `GetFieldByName(Name)` | Delegates to `IHorseRawRequest.GetFieldByName` |
| `ReadClient(Buffer, Count)` | Delegates to `IHorseRawRequest.ReadBody` |
| `ReadString(Count)` | Calls `ReadClient` + UTF-8 decode |
| `TranslateURI(URI)` | Returns URI unchanged |
| `WriteClient` / `WriteString` / `WriteHeaders` | No-op stubs |

### `TInterfacedWebResponse` (Delphi)

| Method | How the adapter handles it |
|---|---|
| `GetStringVariable` / `SetStringVariable` | Stub |
| `GetDateVariable` / `SetDateVariable` | Stub |
| `GetIntegerVariable` / `SetIntegerVariable` | Stub |
| `GetContent` / `SetContent` | Stub (use `THorseResponse.Send`) |
| `SetContentStream` | Stub (use `THorseResponse.SendFile`) |
| `GetStatusCode` / `SetStatusCode` | Stub (use `THorseResponse.Status`) |
| `GetLogMessage` / `SetLogMessage` | Stub |
| `SendResponse` / `SendRedirect` | No-op |
| `SetCustomHeader` | **Inherited from `TWebResponse`** — writes to `CustomHeaders: TStrings` |

### FPC

On FPC, `TInterfacedWebRequest` subclasses `TRequest` and eagerly populates its published fields (`Method`, `URL`, `PathInfo`, `Host`, etc.) from `IHorseRawRequest` in the constructor. `TInterfacedWebResponse` subclasses `TResponse` and sets `Code := 200`.

---

## mORMot-specific considerations

### `RawUtf8` vs `string`

mORMot uses `RawUtf8` (UTF-8 `AnsiString`) everywhere. Horse uses `string` (UTF-16 on Delphi, UTF-8 on FPC). Convert at the boundary:

```pascal
// mORMot → Horse
LMethod := Utf8ToString(ACtxt.Method);

// Horse → mORMot
ACtxt.OutContent := StringToUtf8(LBody);
```

Both `Utf8ToString` and `StringToUtf8` are defined in `mormot.core.base`.

### Body stream ownership

This is the single trickiest part of porting to mORMot — read carefully.

CrossSocket and mORMot disagree on who owns the body stream:

| Provider | Source | Ownership | Cleanup |
|---|---|---|---|
| CrossSocket | `ICrossHttpRequest.Body` (live `TMemoryStream`) | **Transport** owns it for the lifetime of the request | `THorseRequest.Clear` sets `FBody := nil` (no `Free`); `TCrossHttpRequest.Destroy` frees it later (FIX-POOL-1 / SEC-9) |
| mORMot | `THttpServerRequestAbstract.InContent` (a `RawByteString`) | No stream exists — the bytes live in the string | The bridge creates a `TMemoryStream` copy itself; that stream has no natural owner |

The mORMot bridge's `TMemoryStream` copy must be freed **after** `THorseRequest.Clear` runs (which sets `FBody := nil` without freeing it). The `TMormotHandler.Process` method holds it in a local `LBodyStream` variable and frees it in the `finally` block. **Do not** add the stream to a pool's `Reset` path that calls `Body(nil)` — the `Body(AObject)` setter frees the existing `FBody` first, so on a real CrossSocket-pool design that would double-free CrossSocket's transport stream. Either keep ownership in the handler, or build a mORMot-only pool that knows the stream is owning.

If you only need `Req.Body : string` (the cached UTF-8 PATCH-REQ-9 path) and never `Req.Body<TStream>`, you can skip the stream allocation entirely — `SetBodyString` is enough. The `Req.Body<TStream>` accessor would then return `nil`, which middleware that expects a stream must tolerate.

### Header parsing

mORMot stores all request headers as a single CRLF-delimited `RawUtf8` string in `InHeaders`. The `GetFieldByName` implementation does a linear search through this string. For production use, consider parsing headers into a dictionary once in the constructor and looking up from there.

### `THttpServer` constructor

```pascal
THttpServer.Create(
  aPort:                    RawUtf8;    // port as string, e.g. '8080'
  aOnHttpThreadStart:       TNotifyEvent;
  aOnHttpThreadTerminate:   TNotifyEvent;
  aHttpServerKind:          RawUtf8;    // server name/description
  aServerThreadPoolCount:   Integer     // number of worker threads
);
```

The `OnRequest` property must be assigned after construction.

### `THttpApiServer` (Windows http.sys alternative)

On Windows, you can use `THttpApiServer` instead of `THttpServer` for kernel-mode HTTP. It uses the same `THttpServerRequestAbstract` interface, so your `IHorseRawRequest` / `IHorseRawResponse` implementations work unchanged. Only the provider class constructor changes:

```pascal
// Replace THttpServer with THttpApiServer for http.sys:
FServer := THttpApiServer.Create(False);  // False = not cloned
FServer.AddUrl('/');                       // register URL prefix
FServer.OnRequest := LHandler.Process;
```

This gives you kernel-mode HTTP termination on Windows — comparable to IIS performance without the IIS dependency.

---

## Compiler-version guard

`TWebRequest.GetIntegerVariable` / `TWebResponse.SetIntegerVariable` changed from `Integer` to `Int64` in Delphi 10.2 Tokyo (compiler version 32.0). Copy this pattern in your `IHorseRawRequest` implementation:

```pascal
{$IF DEFINED(FPC)}
  function GetContentLength: Integer;      // FPC: always Integer
{$ELSEIF CompilerVersion >= 32.0}
  function GetContentLength: Int64;        // Delphi 10.2+: Int64
{$ELSE}
  function GetContentLength: Integer;      // Delphi XE7–10.1: Integer
{$IFEND}
```

---

## Critical rules

1. **`FBody` ownership differs from CrossSocket.** On CrossSocket, the transport owns the body stream. On mORMot, `InContent` is a string — the bridge creates a `TMemoryStream` copy. You must free this stream yourself after `Clear` runs. Track it in a local variable in the pipeline handler.

2. **`EHorseCallbackInterrupted` must be caught.** This is Horse's normal pipeline-end signal. If it falls into the generic `Exception` handler, every request logs as an error and gets a spurious 500.

3. **`IsConsole` guard.** `ListenWithConfig` must only block when `IsConsole = True`. VCL/service applications use their own message loop.

4. **Dual-compilation.** Every unit must carry `{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}` at the top and split `uses` clauses between Delphi and FPC.

5. **Each provider owns its own `FPort`.** Do not declare `FPort` in `THorseProviderAbstract`. Each provider declares its own.

6. **Shutdown ordering.** `Stop` must free the server (joining all threads) BEFORE signalling `FStopEvent`.

7. **`RawUtf8` conversion.** Always convert at the mORMot/Horse boundary. Never store `RawUtf8` in Horse's `string` fields without conversion — on Delphi the codepage mismatch will silently corrupt non-ASCII characters.

8. **Avoid inline `var` for FPC/pre-10.3 compatibility.** The sample code in Steps 4-5 uses inline `var` for clarity. For production dual-compilation code, move all variable declarations to the procedure's `var` block.

---

## Optional enhancements

| Enhancement | CrossSocket reference |
|---|---|
| **Context pool** — pre-allocate `THorseContext` objects | `Horse.Provider.CrossSocket.Pool.pas` |
| **Active-request tracking** — graceful drain on `Stop` | SEC-30 in `Horse.Provider.CrossSocket.pas` |
| **CRLF-stripping** — strip CR/LF/NUL from response header values | `TResponseBridge.Flush` |
| **Hop-by-hop filter** — remove `Connection`, `Transfer-Encoding`, etc. | `TResponseBridge.Flush` |
| **Header dictionary** — parse `InHeaders` once into a `TDictionary` for O(1) lookup | `TMormotRawRequest` constructor |
| **http.sys mode** — use `THttpApiServer` on Windows for kernel-mode performance | See mORMot-specific section above |

---

## Testing

Copy the test pattern from `patches/horse-provider-crosssocket/samples/tests/`:

1. **Test server** (`HorseMormotTestServer.dpr`) — registers routes, calls `THorseProviderMormot.Listen(TEST_PORT)`
2. **Test client** (`HorseMormotTestClient.dpr`) — sends requests using `THttpClientSocket` (mORMot's client) or `TIdHTTP` or `TCrossHttpClient`, checks status codes and body content

The CrossSocket test suite has **32 tests** covering HTTP methods, routing, cookies, body isolation, concurrent pool safety, `RawWebRequest` / `RawWebResponse` adapter correctness, CORS compatibility, the PATCH-REQ-9 double-read body cache (Test 31), and COMPAT-1 shadow-field precedence (Test 32). Use it as a baseline for your provider's test suite.

For the surface each official Horse middleware touches and the mechanism that satisfies it, see `doc/middleware-compatibility.md`. Anything that works on CrossSocket via `IHorseRawRequest` / `IHorseRawResponse` will also work on a mORMot provider that follows the same hybrid-adapter pattern.

### Minimal test verification

```pascal
program HorseMormotTestServer;

{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_MORMOT}   // canonical (PATCH-HORSE-2 namespace)

uses
  Horse;

const
  TEST_PORT = 9020;

begin
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain').Send('pong');
    end);

  THorse.Listen(TEST_PORT);
end.
```

Verify with curl:

```bash
curl http://127.0.0.1:9020/ping
# Expected: pong
```
