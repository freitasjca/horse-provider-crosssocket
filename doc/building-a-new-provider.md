# Building a New Horse Provider

This guide explains how to create a new transport provider for Horse using the hybrid interface architecture. The architecture was designed so that adding a provider like **nghttp2** (HTTP/2 via libnghttp2), **libuv** (Node.js-style event loop), or **QUIC** (HTTP/3 via quiche/msquic) requires implementing only ~15 methods for the request side and ~1 for the response side. All 30+ `TWebRequest`/`TWebResponse` abstract method stubs are handled by the generic adapters — zero boilerplate duplication.

---

## Architecture overview

```
Your native request object (e.g. TNghttp2Stream, TUVRequest, TQuicStream)
      |
      v
TMyRawRequest : TInterfacedObject, IHorseRawRequest    <-- you write this (~15 methods)
      |
      v
TInterfacedWebRequest (Horse.Provider.RawAdapters)      <-- already exists, delegates stubs
      |
      v
TMyWebRequest : TInterfacedWebRequest                   <-- thin subclass, 1 constructor
      |
      v
THorseRequest.RawWebRequest                             <-- returns TWebRequest (unchanged API)
      |
      v
Middleware (Horse.CORS, horse-jwt, etc.)                <-- works unchanged
```

Same pattern on the response side:

```
Your native response object
      |
TMyRawResponse : TInterfacedObject, IHorseRawResponse   <-- you write this (~1 method)
      |
TInterfacedWebResponse (Horse.Provider.RawAdapters)      <-- already exists
      |
TMyWebResponse : TInterfacedWebResponse                  <-- thin subclass, 1 constructor
      |
THorseResponse.RawWebResponse                            <-- returns TWebResponse (unchanged API)
```

---

## Prerequisites

Your Horse fork must include these patched units (all in `patches/horse/src/`):

| Unit | What it provides |
|---|---|
| `Horse.Provider.RawInterfaces.pas` | `IHorseRawRequest` + `IHorseRawResponse` interface definitions |
| `Horse.Provider.RawAdapters.pas` | `TInterfacedWebRequest` + `TInterfacedWebResponse` generic adapter classes |
| `Horse.Provider.Abstract.pas` | `ListenWithConfig` (PATCH-ABS-2), `Execute` (PATCH-ABS-3), `MaxConnections` (PATCH-ABS-4) virtual class methods |
| `Horse.Provider.Config.pas` | `THorseCrossSocketConfig` record (shared config type) |
| `Horse.Request.pas` | Shadow fields, `Clear`, `Populate`, `SetCSRawWebRequest` |
| `Horse.Response.pas` | Shadow fields, `Clear` (PATCH-RES-2), `SetCSRawWebResponse` (PATCH-RES-6), nil-guards, `CustomHeaders`, `BodyText`/`ContentStream`/`CSContentType` read-only properties |

---

## Step-by-step: nghttp2 provider example

The examples below use **nghttp2** (a C library for HTTP/2) as the hypothetical transport. Replace `TNghttp2*` / `Inghttp2*` with your transport's types.

### Step 1 — Implement `IHorseRawRequest`

Create `Horse.Provider.Nghttp2.RawRequest.pas`:

```pascal
unit Horse.Provider.Nghttp2.RawRequest;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$ENDIF}
  Nghttp2.Types,                    // your transport's type unit
  Horse.Provider.RawInterfaces;

type
  TNghttp2RawRequest = class(TInterfacedObject, IHorseRawRequest)
  private
    FStream: INghttp2Stream;         // your transport's native request
    FContentCache: string;
    FContentCached: Boolean;
  public
    constructor Create(const AStream: INghttp2Stream);

    { IHorseRawRequest — ~15 one-liner methods }
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

constructor TNghttp2RawRequest.Create(const AStream: INghttp2Stream);
begin
  inherited Create;
  FStream        := AStream;
  FContentCached := False;
end;

function TNghttp2RawRequest.GetMethod: string;
begin
  // HTTP/2 pseudo-header :method
  Result := FStream.Header[':method'];
end;

function TNghttp2RawRequest.GetProtocolVersion: string;
begin
  Result := 'HTTP/2';
end;

function TNghttp2RawRequest.GetURL: string;
begin
  // HTTP/2 pseudo-header :path includes query string
  Result := FStream.Header[':path'];
end;

function TNghttp2RawRequest.GetPathInfo: string;
var
  S: string;
  QPos: Integer;
begin
  S := GetURL;
  QPos := Pos('?', S);
  if QPos > 0 then
    Result := Copy(S, 1, QPos - 1)
  else
    Result := S;
end;

function TNghttp2RawRequest.GetQueryString: string;
var
  S: string;
  QPos: Integer;
begin
  S := GetURL;
  QPos := Pos('?', S);
  if QPos > 0 then
    Result := Copy(S, QPos + 1, MaxInt)
  else
    Result := '';
end;

function TNghttp2RawRequest.GetHost: string;
begin
  // HTTP/2 pseudo-header :authority replaces Host
  Result := FStream.Header[':authority'];
end;

function TNghttp2RawRequest.GetRemoteAddr: string;
begin
  Result := FStream.Connection.PeerAddr;
end;

function TNghttp2RawRequest.GetServerPort: Integer;
begin
  Result := FStream.Connection.LocalPort;
end;

function TNghttp2RawRequest.GetContentType: string;
begin
  Result := FStream.Header['content-type'];
end;

function TNghttp2RawRequest.GetContent: string;
var
  LStream: TStream;
  LBytes: TBytes;
begin
  if FContentCached then Exit(FContentCache);
  FContentCache := '';
  LStream := FStream.Body;
  if Assigned(LStream) and (LStream.Size > 0) then
  begin
    LStream.Position := 0;
    SetLength(LBytes, LStream.Size);
    LStream.Read(LBytes[0], LStream.Size);
    FContentCache := TEncoding.UTF8.GetString(LBytes);
  end;
  FContentCached := True;
  Result := FContentCache;
end;

{$IF DEFINED(FPC)}
function TNghttp2RawRequest.GetContentLength: Integer;
{$ELSEIF CompilerVersion >= 32.0}
function TNghttp2RawRequest.GetContentLength: Int64;
{$ELSE}
function TNghttp2RawRequest.GetContentLength: Integer;
{$IFEND}
begin
  Result := StrToInt64Def(FStream.Header['content-length'], -1);
end;

function TNghttp2RawRequest.GetFieldByName(const AName: string): string;
begin
  // HTTP/2 header names are lowercase
  Result := FStream.Header[LowerCase(AName)];
end;

procedure TNghttp2RawRequest.PopulateQueryFields(ADest: TStrings);
var
  S, Pair, Key, Value: string;
  AmpPos, EqPos: Integer;
begin
  // Generic query string parser — adapt if your transport has a parsed API
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

procedure TNghttp2RawRequest.PopulateContentFields(ADest: TStrings);
begin
  // Only relevant for application/x-www-form-urlencoded bodies.
  // Parse the body the same way as query fields if content-type matches.
  // If your transport pre-parses form fields, iterate them here.
end;

procedure TNghttp2RawRequest.PopulateCookieFields(ADest: TStrings);
var
  S, Pair: string;
  SemiPos: Integer;
begin
  S := Trim(FStream.Header['cookie']);
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

function TNghttp2RawRequest.ReadBody(var Buffer; Count: Integer): Integer;
var
  LStream: TStream;
begin
  LStream := FStream.Body;
  if not Assigned(LStream) then Exit(0);
  Result := LStream.Read(Buffer, Count);
end;

end.
```

**That's the bulk of the work.** Everything else is thin wiring.

### Step 2 — Implement `IHorseRawResponse`

Create `Horse.Provider.Nghttp2.RawResponse.pas`:

```pascal
unit Horse.Provider.Nghttp2.RawResponse;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  Nghttp2.Types,
  Horse.Provider.RawInterfaces;

type
  TNghttp2RawResponse = class(TInterfacedObject, IHorseRawResponse)
  private
    FStream: INghttp2Stream;
  public
    constructor Create(const AStream: INghttp2Stream);
    procedure SetCustomHeader(const AName, AValue: string);
  end;

implementation

constructor TNghttp2RawResponse.Create(const AStream: INghttp2Stream);
begin
  inherited Create;
  FStream := AStream;
end;

procedure TNghttp2RawResponse.SetCustomHeader(const AName, AValue: string);
begin
  { Header writes are captured by TInterfacedWebResponse's inherited
    CustomHeaders TStrings.  This method exists for providers that want
    to forward headers to the transport in real time.  For most providers
    this is a no-op — TResponseBridge reads CustomHeaders at flush time. }
end;

end.
```

### Step 3 — Create thin `TWebRequest`/`TWebResponse` subclasses

These are factory constructors that hide the two-step construction.

`Horse.Provider.Nghttp2.WebRequestAdapter.pas`:

```pascal
unit Horse.Provider.Nghttp2.WebRequestAdapter;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, fpHTTP, HTTPDefs,
{$ELSE}
  System.SysUtils, System.Classes, Web.HTTPApp,
{$ENDIF}
  Nghttp2.Types,
  Horse.Provider.RawAdapters,
  Horse.Provider.Nghttp2.RawRequest;

type
  TNghttp2WebRequest = class(TInterfacedWebRequest)
  public
    constructor Create(const AStream: INghttp2Stream); reintroduce;
  end;

implementation

constructor TNghttp2WebRequest.Create(const AStream: INghttp2Stream);
begin
  inherited Create(TNghttp2RawRequest.Create(AStream));
end;

end.
```

`Horse.Provider.Nghttp2.WebResponseAdapter.pas`:

```pascal
unit Horse.Provider.Nghttp2.WebResponseAdapter;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, fpHTTP, HTTPDefs,
{$ELSE}
  System.SysUtils, System.Classes, Web.HTTPApp,
{$ENDIF}
  Nghttp2.Types,
  Horse.Provider.RawAdapters,
  Horse.Provider.Nghttp2.RawResponse;

type
  TNghttp2WebResponse = class(TInterfacedWebResponse)
  public
    constructor Create(const AStream: INghttp2Stream); reintroduce;
  end;

implementation

constructor TNghttp2WebResponse.Create(const AStream: INghttp2Stream);
begin
  inherited Create(TNghttp2RawResponse.Create(AStream));
end;

end.
```

### Step 4 — Write the request bridge

The request bridge translates incoming requests from your native transport into `THorseRequest` shadow fields. This is where security validation goes.

`Horse.Provider.Nghttp2.Request.pas`:

```pascal
unit Horse.Provider.Nghttp2.Request;

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
  Nghttp2.Types;

type
  TRequestValidationResult = (rvOK, rvBadRequest, rvMethodNotAllowed);

  TNghttp2RequestBridge = class
  public
    class function Populate(
      const AStream:   INghttp2Stream;
      const AHorseReq: THorseRequest;
      out   ARejectReason: string
    ): TRequestValidationResult;
  end;

implementation

uses
  Horse.Provider.Nghttp2.WebRequestAdapter;

class function TNghttp2RequestBridge.Populate(
  const AStream:   INghttp2Stream;
  const AHorseReq: THorseRequest;
  out   ARejectReason: string
): TRequestValidationResult;
var
  LMethod, LPath, LHost, LContentType, LRemoteAddr: string;
  LMethodType: TMethodType;
begin
  Result := rvOK;
  ARejectReason := '';

  // ── Extract values from native request ────────────────────────────────
  LMethod      := AStream.Header[':method'];
  LPath        := AStream.Header[':path'];
  LHost        := AStream.Header[':authority'];
  LContentType := AStream.Header['content-type'];
  LRemoteAddr  := AStream.Connection.PeerAddr;

  // ── Validation (add your security checks here) ────────────────────────

  // Method allowlist
  if SameText(LMethod, 'CONNECT') or SameText(LMethod, 'TRACE') then
  begin
    ARejectReason := 'Method not allowed: ' + LMethod;
    Exit(rvMethodNotAllowed);
  end;

  // Host validation
  if LHost = '' then
  begin
    ARejectReason := 'Missing :authority pseudo-header';
    Exit(rvBadRequest);
  end;

  // Request smuggling: Content-Length + Transfer-Encoding
  if (AStream.Header['content-length'] <> '') and
     (AStream.Header['transfer-encoding'] <> '') then
  begin
    ARejectReason := 'Ambiguous body framing';
    Exit(rvBadRequest);
  end;

  // ── Probe-only mode (AHorseReq = nil) — validation without population ─
  if AHorseReq = nil then
    Exit;

  // ── Map method string to TMethodType ──────────────────────────────────
  if SameText(LMethod, 'GET')         then LMethodType := mtGet
  else if SameText(LMethod, 'POST')   then LMethodType := mtPost
  else if SameText(LMethod, 'PUT')    then LMethodType := mtPut
  else if SameText(LMethod, 'DELETE') then LMethodType := mtDelete
  else if SameText(LMethod, 'PATCH')  then LMethodType := mtPatch
  else if SameText(LMethod, 'HEAD')   then LMethodType := mtHead
  else LMethodType := mtAny;

  // ── Populate THorseRequest shadow fields ──────────────────────────────
  // Signature: (AMethod, AMethodType, APath, AContentType, ARemoteAddr).
  // AMethodType is the 2nd parameter — NOT the last. See PATCH-REQ-3.
  AHorseReq.Populate(LMethod, LMethodType, LPath, LContentType, LRemoteAddr);

  // ── Body ──────────────────────────────────────────────────────────────
  if Assigned(AStream.Body) then
    AHorseReq.Body(AStream.Body);   // non-owning reference — never freed

  // ── Headers → THorseRequest.Headers dictionary ────────────────────────
  // Iterate your transport's headers and add them:
  //   for H in AStream.Headers do
  //     AHorseReq.Headers.Dictionary.AddOrSetValue(H.Name, H.Value);

  // ── Cookies ───────────────────────────────────────────────────────────
  AHorseReq.PopulateCookiesFromHeader(AStream.Header['cookie']);

  // ── RawWebRequest adapter (PATCH-REQ-8) ───────────────────────────────
  // Creates a TWebRequest adapter so Req.RawWebRequest is non-nil.
  // Ownership transfers to THorseRequest; freed by Clear on pool release.
  AHorseReq.SetCSRawWebRequest(
    TNghttp2WebRequest.Create(AStream));
end;

end.
```

### Step 5 — Write the response bridge

The response bridge reads `THorseResponse` shadow fields and writes them to your native response.

`Horse.Provider.Nghttp2.Response.pas`:

```pascal
unit Horse.Provider.Nghttp2.Response;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils, Classes, Generics.Collections,
{$ELSE}
  System.SysUtils, System.Classes, System.Generics.Collections,
{$ENDIF}
  Horse,
  Nghttp2.Types;

type
  TNghttp2ResponseBridge = class
  public
    class procedure Flush(
      const AHorseRes:  THorseResponse;
      const AStream:    INghttp2Stream;
      const ABanner:    string
    );
  end;

implementation

class procedure TNghttp2ResponseBridge.Flush(
  const AHorseRes:  THorseResponse;
  const AStream:    INghttp2Stream;
  const ABanner:    string
);
var
  LStatus:      Integer;
  LBody:        string;
  LContentType: string;
  LPair:        TPair<string, string>;
  LBuf:         TBytes;
  I:            Integer;
begin
  // ── Status ────────────────────────────────────────────────────────────
  LStatus := AHorseRes.Status;
  if LStatus = 0 then
    LStatus := 200;
  AStream.StatusCode := LStatus;

  // ── Content-Type ──────────────────────────────────────────────────────
  LContentType := AHorseRes.CSContentType;
  if LContentType <> '' then
    AStream.Header['content-type'] := LContentType;

  // ── Custom headers (set via Res.AddHeader) ────────────────────────────
  // CustomHeaders is TDictionary<string,string> on Delphi, TStringList on FPC
  if Assigned(AHorseRes.CustomHeaders) then
  begin
{$IF DEFINED(FPC)}
    // FPC: TStringList — iterate Name/Value pairs
    for I := 0 to AHorseRes.CustomHeaders.Count - 1 do
      AStream.Header[AHorseRes.CustomHeaders.Names[I]] :=
        AHorseRes.CustomHeaders.ValueFromIndex[I];
{$ELSE}
    for LPair in AHorseRes.CustomHeaders do
      AStream.Header[LPair.Key] := LPair.Value;
{$ENDIF}
  end;

  // ── Security headers ──────────────────────────────────────────────────
  AStream.Header['x-content-type-options'] := 'nosniff';
  AStream.Header['x-frame-options']        := 'DENY';
  AStream.Header['cache-control']          := 'no-store';
  if ABanner <> '' then
    AStream.Header['server'] := ABanner
  else
    AStream.Header['server'] := 'unknown';

  // ── Body ──────────────────────────────────────────────────────────────
  if Assigned(AHorseRes.ContentStream) then
  begin
    // Stream response (SendFile / Download)
    AStream.SendStream(AHorseRes.ContentStream);
  end
  else
  begin
    LBody := AHorseRes.BodyText;
    if LBody <> '' then
    begin
      LBuf := TEncoding.UTF8.GetBytes(LBody);
      AStream.Send(LBuf);
    end
    else if LStatus >= 400 then
    begin
      // Minimal body for error status so the client sees the status code
      LBuf := TEncoding.UTF8.GetBytes(IntToStr(LStatus));
      AStream.Send(LBuf);
    end
    else
      AStream.Send(nil);  // empty 200/204
  end;
end;

end.
```

### Step 6 — Write the provider class

This is the main entry point — the equivalent of `Horse.Provider.CrossSocket.pas`.

`Horse.Provider.Nghttp2.pas`:

```pascal
unit Horse.Provider.Nghttp2;

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
  Nghttp2.Server,
  Nghttp2.Types;

type
  THorseProviderNghttp2 = class(THorseProviderAbstract)
  private
    class var FServer:    TNghttp2Server;
    class var FPort:      Integer;
    class var FStopEvent: TEvent;
    class var FRunning:   Boolean;

    class function  GetPort: Integer; static;
    class procedure SetPort(const AValue: Integer); static;

    class procedure ExecutePipeline(
      const AStream: INghttp2Stream
    );

    class procedure SendError(
      const AStream:  INghttp2Stream;
      AStatus:        Integer;
      const AMessage: string
    );

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
  Horse.Exception.Interrupted,
  Horse.Provider.Nghttp2.Request,
  Horse.Provider.Nghttp2.Response,
  Horse.Provider.Nghttp2.WebResponseAdapter;

// Assuming you have a context pool — otherwise allocate per request
// uses Horse.Provider.Nghttp2.Pool;

{ THorseProviderNghttp2 }

class function THorseProviderNghttp2.GetPort: Integer;
begin
  Result := FPort;
end;

class procedure THorseProviderNghttp2.SetPort(const AValue: Integer);
begin
  FPort := AValue;
end;

class procedure THorseProviderNghttp2.Listen;
begin
  if FPort <= 0 then
    FPort := 9000;
  ListenWithConfig(FPort, THorseCrossSocketConfig.Default);
end;

class procedure THorseProviderNghttp2.Listen(APort: Integer);
begin
  ListenWithConfig(APort, THorseCrossSocketConfig.Default);
end;

class procedure THorseProviderNghttp2.ListenWithConfig(
  const APort: Integer; const AConfig: THorseCrossSocketConfig);
begin
  if Assigned(FServer) then
    Stop;

  FServer := TNghttp2Server.Create;
  // Apply config (adapt to your server's API):
  // FServer.MaxHeaderSize := AConfig.MaxHeaderSize;
  // if AConfig.SSLEnabled then ...

  FServer.OnRequest :=
    procedure(const AStream: INghttp2Stream)
    begin
      ExecutePipeline(AStream);
    end;

  FPort := APort;
  FServer.Start(APort);
  DoOnListen;

  // Block the main thread in console apps (same pattern as CrossSocket)
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

class procedure THorseProviderNghttp2.StopListen;
begin
  Stop;
  DoOnStopListen;
end;

class procedure THorseProviderNghttp2.Stop;
begin
  FRunning := False;

  if Assigned(FServer) then
  begin
    FServer.Stop;
    FreeAndNil(FServer);
  end;

  if Assigned(FStopEvent) then
    FStopEvent.SetEvent;
end;

class procedure THorseProviderNghttp2.ExecutePipeline(
  const AStream: INghttp2Stream);
var
  Ctx:          THorseContext;       // or use a pool
  ValResult:    TRequestValidationResult;
  RejectReason: string;
begin
  // ── Validate before touching the pool ──────────────────────────────
  ValResult := TNghttp2RequestBridge.Populate(AStream, nil, RejectReason);

  if ValResult <> rvOK then
  begin
    case ValResult of
      rvMethodNotAllowed: SendError(AStream, 405, 'Method Not Allowed');
    else
      SendError(AStream, 400, 'Bad Request');
    end;
    Exit;
  end;

  // ── Acquire context (pool or fresh allocation) ─────────────────────
  // If using a pool:  Ctx := TMyContextPool.Acquire;
  // Otherwise:
  Ctx := THorseContext.Create;
  try
    // Full population
    TNghttp2RequestBridge.Populate(AStream, Ctx.Request, RejectReason);

    // Wire up RawWebResponse for middleware like Horse.CORS
    Ctx.Response.SetCSRawWebResponse(
      TNghttp2WebResponse.Create(AStream));

    // ── Run the Horse pipeline ─────────────────────────────────────
    try
      THorse.Execute(Ctx.Request, Ctx.Response);
    except
      on EHorseCallbackInterrupted do
        ;  // normal pipeline completion — swallow silently

      on E: EHorseException do
      begin
        Ctx.Response.Status(E.Status);
        Ctx.Response.Send(Format('{"error":"%s"}', [E.Message]));
        Ctx.Response.ContentType('application/json; charset=utf-8');
      end;

      on E: Exception do
      begin
        // Log internally — never leak stack traces to clients
        WriteLn(ErrOutput, Format('[Nghttp2] Exception: %s: %s',
          [E.ClassName, E.Message]));
        Ctx.Response.Status(THTTPStatus.InternalServerError);
        Ctx.Response.Send('{"error":"Internal Server Error"}');
        Ctx.Response.ContentType('application/json; charset=utf-8');
      end;
    end;

    // ── Flush response to the transport ────────────────────────────
    TNghttp2ResponseBridge.Flush(Ctx.Response, AStream, '');

  finally
    // If using a pool:  TMyContextPool.Release(Ctx);
    Ctx.Free;
  end;
end;

class procedure THorseProviderNghttp2.SendError(
  const AStream: INghttp2Stream; AStatus: Integer; const AMessage: string);
var
  Buf: TBytes;
begin
  AStream.StatusCode := AStatus;
  AStream.Header['content-type']            := 'application/json; charset=utf-8';
  AStream.Header['x-content-type-options']  := 'nosniff';
  AStream.Header['x-frame-options']         := 'DENY';
  AStream.Header['server']                  := 'unknown';
  AStream.Header['cache-control']           := 'no-store';

  Buf := TEncoding.UTF8.GetBytes(
    Format('{"error":"%s"}', [StringReplace(AMessage, '"', '\"', [rfReplaceAll])]));
  AStream.Send(Buf);
end;

end.
```

### Step 7 — Register the provider in `Horse.pas`

Add a new `{$ELSEIF}` branch in the conditional chain:

```pascal
// Horse.pas — uses clause
{$ELSEIF DEFINED(HORSE_NGHTTP2)}
  Horse.Provider.Nghttp2,

// Horse.pas — THorseProvider type alias
{$ELSEIF DEFINED(HORSE_NGHTTP2)}
  THorseProvider = Horse.Provider.Nghttp2.THorseProviderNghttp2;
```

Users activate it with `{$DEFINE HORSE_NGHTTP2}` in project options.

---

## File checklist

| File | Lines of code | What you write |
|---|---|---|
| `Horse.Provider.Nghttp2.RawRequest.pas` | ~120 | `IHorseRawRequest` implementation (~15 methods wrapping your native request) |
| `Horse.Provider.Nghttp2.RawResponse.pas` | ~25 | `IHorseRawResponse` implementation (1 method, usually a no-op) |
| `Horse.Provider.Nghttp2.WebRequestAdapter.pas` | ~15 | Thin subclass: 1 constructor calling `inherited Create(TMyRawRequest.Create(...))` |
| `Horse.Provider.Nghttp2.WebResponseAdapter.pas` | ~15 | Thin subclass: 1 constructor calling `inherited Create(TMyRawResponse.Create(...))` |
| `Horse.Provider.Nghttp2.Request.pas` | ~80 | Request bridge: validation + `Populate` + `SetCSRawWebRequest` |
| `Horse.Provider.Nghttp2.Response.pas` | ~60 | Response bridge: read shadow fields → write native response |
| `Horse.Provider.Nghttp2.pas` | ~120 | Provider class: `Listen`/`Stop`/`ExecutePipeline`/`SendError` |
| **Total** | **~435** | |

For comparison, doing this **without** the hybrid architecture (stubbing 30+ abstract methods directly) would add ~200 lines of boilerplate stubs that are identical across every provider — and every future provider would duplicate them again.

---

## What the generic adapters handle for you

These are the `TWebRequest` / `TWebResponse` abstract methods that `TInterfacedWebRequest` / `TInterfacedWebResponse` stub or delegate automatically. You never touch any of them:

### `TInterfacedWebRequest` (Delphi)

| Method | How the adapter handles it |
|---|---|
| `GetStringVariable(Index)` | 29-case dispatch to `IHorseRawRequest.GetMethod`, `GetHost`, `GetPathInfo`, `GetFieldByName(...)`, etc. |
| `GetDateVariable(Index)` | Returns `0` (no date header parsing needed) |
| `GetIntegerVariable(Index)` | Delegates `ContentLength` and `ServerPort` to `IHorseRawRequest` |
| `GetRawContent` | Calls `IHorseRawRequest.GetContent` → UTF-8 bytes |
| `GetFieldByName(Name)` | Delegates to `IHorseRawRequest.GetFieldByName` |
| `ReadClient(Buffer, Count)` | Delegates to `IHorseRawRequest.ReadBody` |
| `ReadString(Count)` | Calls `ReadClient` + UTF-8 decode |
| `TranslateURI(URI)` | Returns URI unchanged |
| `WriteClient` / `WriteString` / `WriteHeaders` | No-op stubs (response goes through `THorseResponse`) |

### `TInterfacedWebResponse` (Delphi)

| Method | How the adapter handles it |
|---|---|
| `GetStringVariable` / `SetStringVariable` | Stub (empty / no-op) |
| `GetDateVariable` / `SetDateVariable` | Stub (0 / no-op) |
| `GetIntegerVariable` / `SetIntegerVariable` | Stub (0 / no-op) |
| `GetContent` / `SetContent` | Stub (use `THorseResponse.Send`) |
| `SetContentStream` | Stub (use `THorseResponse.SendFile`) |
| `GetStatusCode` / `SetStatusCode` | Stub (200 / no-op — use `THorseResponse.Status`) |
| `GetLogMessage` / `SetLogMessage` | Stub |
| `SendResponse` / `SendRedirect` | No-op (use `TResponseBridge.Flush` / `THorseResponse.RedirectTo`) |
| `SetCustomHeader` | **Inherited from `TWebResponse`** — writes to `CustomHeaders: TStrings`, which the response bridge reads at flush time |

### FPC

On FPC, `TInterfacedWebRequest` subclasses `TRequest` and eagerly populates its published fields (`Method`, `URL`, `PathInfo`, `Host`, etc.) from `IHorseRawRequest` in the constructor. `TInterfacedWebResponse` subclasses `TResponse` and sets `Code := 200`.

---

## Compiler-version guard

`TWebRequest.GetIntegerVariable` / `TWebResponse.SetIntegerVariable` changed from `Integer` to `Int64` in Delphi 10.2 Tokyo (compiler version 32.0). The `IHorseRawRequest.GetContentLength` return type and the adapter overrides use this guard:

```pascal
{$IF DEFINED(FPC)}
  function GetContentLength: Integer;      // FPC: always Integer
{$ELSEIF CompilerVersion >= 32.0}
  function GetContentLength: Int64;        // Delphi 10.2+: Int64
{$ELSE}
  function GetContentLength: Integer;      // Delphi XE7–10.1: Integer
{$IFEND}
```

Copy this pattern exactly in your `IHorseRawRequest` implementation. The adapter handles the matching override signatures.

---

## Critical rules

1. **`FBody` is non-owning.** Your transport owns the body stream. `THorseRequest.Clear` sets `FBody := nil` without calling `Free`. Never call `FRequest.Body(nil)` — the setter frees the existing `FBody`. See FIX-POOL-1 in `CLAUDE.md`.

2. **`EHorseCallbackInterrupted` must be caught.** This is Horse's normal pipeline-end signal — raised by `NextCaller` when the middleware chain is exhausted. If you let it fall into the generic `Exception` handler, every request logs as an error and gets a 500 response overlaid on the real response.

3. **`IsConsole` guard.** `ListenWithConfig` must only block the main thread when `IsConsole = True`. VCL/service applications use their own message loop.

4. **Dual-compilation.** Every unit must carry `{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}` at the top and split `uses` clauses between Delphi and FPC.

5. **Each provider owns its own `FPort`.** Do not declare `FPort` in `THorseProviderAbstract` — `class var` in Delphi subclasses are independent memory locations. Each provider declares its own `FPort` and `Port` property.

6. **Shutdown ordering.** `Stop` must join all transport threads BEFORE signalling `FStopEvent`. Otherwise RTL finalization runs while threads are still active, clearing middleware globals out from under them.

---

## Optional enhancements

These are not required for a minimal provider but are recommended for production use:

| Enhancement | CrossSocket reference |
|---|---|
| **Context pool** — pre-allocate `THorseContext` objects, recycle via `Acquire`/`Release` | `Horse.Provider.CrossSocket.Pool.pas` |
| **Worker thread pool** — offload CPU-bound handlers from IO threads | `Horse.Provider.CrossSocket.WorkerPool.pas` |
| **Active-request tracking** — increment on entry, decrement in `finally`, drain on `Stop` | SEC-30 in `Horse.Provider.CrossSocket.pas` |
| **CRLF-stripping** — strip CR/LF/NUL from response header values (injection prevention) | `TResponseBridge.Flush` |
| **Hop-by-hop filter** — remove `Connection`, `Transfer-Encoding`, `Keep-Alive`, `Proxy-*` from response headers | `TResponseBridge.Flush` |
| **Double-start guard** — if `Listen` is called while already listening, stop the old server first | SEC-32 |

---

## Testing

Copy the test pattern from `patches/horse-provider-crosssocket/samples/tests/`:

1. **Test server** (`HorseMyTestServer.dpr`) — registers routes, calls `THorseProviderNghttp2.Listen(TEST_PORT)`
2. **Test client** (`HorseMyTestClient.dpr`) — sends requests using your transport's client (or `TIdHTTP` / `TCrossHttpClient`), checks status codes and body content

The CrossSocket test suite has 32 tests covering HTTP methods, routing, cookies, body isolation, concurrent pool safety, `RawWebRequest`/`RawWebResponse` adapter correctness, and CORS compatibility. Use it as a baseline for your provider's test suite.
