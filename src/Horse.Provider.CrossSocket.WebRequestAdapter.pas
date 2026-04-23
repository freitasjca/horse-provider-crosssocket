unit Horse.Provider.CrossSocket.WebRequestAdapter;

{
  Horse CrossSocket Provider  -  TWebRequest / TRequest adapter
  ------------------------------------------------------------

  Purpose
  -------
  Provide a concrete TWebRequest subclass (Delphi) / TRequest subclass (FPC)
  backed by ICrossHttpRequest so that existing Horse middleware that uses
  Req.RawWebRequest.Method / .Host / .RemoteAddr / .GetFieldByName(...) works
  unchanged on the CrossSocket path.

  Design (PATCH-REQ-8 in Horse.Request.pas)
  -----------------------------------------
  Every request, the TRequestBridge.Populate ends by constructing one of these
  adapters and handing it to THorseRequest.SetCSRawWebRequest. THorseRequest
  owns the adapter: Clear and Destroy free it. The pool pattern re-creates
  a fresh adapter per request — they are small and cheap, and instance reuse
  would require clearing every cached inherited field, which is riskier than
  one alloc/free per request.

  Scope — intentionally minimal
  -----------------------------
  Overrides cover the variables middleware commonly read:
      Method, ProtocolVersion, URL, Query, PathInfo, Host, Accept,
      UserAgent, Referer, ContentType, ContentEncoding, ContentLength,
      RemoteAddr, ScriptName, Content, Connection, Cookie, Authorization,
      CacheControl, IfModifiedSince, ServerPort
  Plus the abstract GetFieldByName / ReadClient / ReadString. Write-side
  methods (WriteClient / WriteString / WriteHeaders) are stubbed — response
  writing MUST go through THorseResponse, not RawWebRequest. These stubs
  exist only to satisfy the abstract contract; calling them returns 0 / False.

  Out of scope
  ------------
  — Multipart file upload iteration via Files[]. Middleware that needs
    uploads must use Req.ContentFields (the shadow field collection).
  — Date-header parsing (GetDateVariable returns 0). Rarely used.
  — Response writing. Use Res.Send / Res.AddHeader / Res.Status.

  Lifetime
  --------
  Adapter holds ICrossHttpRequest by interface reference — ref-counted by
  CrossSocket. The interface keeps the underlying TCrossHttpRequest alive
  for as long as the adapter exists, which is one HTTP request cycle.

  Dual-compilation
  ----------------
  Delphi branch subclasses TWebRequest (abstract, Web.HTTPApp), overrides
  GetStringVariable plus the read/write abstract methods, and populates
  the inherited QueryFields / ContentFields / CookieFields eagerly in the
  constructor (these properties are backed by private fields with no
  virtual getter to override).

  FPC branch subclasses TRequest (HTTPDefs) — field-based, not abstract-
  method-driven. Constructor populates the inherited fields directly.
}

{$IF DEFINED(FPC)}
{$MODE DELPHI}{$H+}
{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes,
  fpHTTP,
  HTTPDefs,
{$ELSE}
  System.SysUtils,
  System.Classes,
  Web.HTTPApp,
{$ENDIF}
  Net.CrossHttpServer,
  Net.CrossHttpParams;

type
{$IF DEFINED(FPC)}
  { TCrossSocketWebRequest — FPC TRequest subclass
    Fields are populated in the constructor; no virtual dispatch needed. }
  TCrossSocketWebRequest = class(TRequest)
  private
    FCrossReq: ICrossHttpRequest;
  public
    constructor Create(const ACrossReq: ICrossHttpRequest); reintroduce;
  end;

{$ELSE}
  { TCrossSocketWebRequest — Delphi TWebRequest subclass
    Overrides the three abstract Get*Variable plus read/write methods.
    Eagerly populates inherited QueryFields / ContentFields / CookieFields
    in the constructor (no virtual getter exists in TWebRequest to override). }
  TCrossSocketWebRequest = class(TWebRequest)
  private
    FCrossReq:         ICrossHttpRequest;
    FContentCache:     string;
    FContentCached:    Boolean;
    function  GetContentAsString: string;
  protected
    function  GetStringVariable(Index: Integer): string; override;
    function  GetDateVariable(Index: Integer): TDateTime; override;
    function  GetIntegerVariable(Index: Integer): Int64; override;
  public
    constructor Create(const ACrossReq: ICrossHttpRequest); reintroduce;
    destructor  Destroy; override;
    function  GetFieldByName(const Name: string): string; override;
    function  ReadClient(var Buffer; Count: Integer): Integer; override;
    function  ReadString(Count: Integer): string; override;
    function  TranslateURI(const URI: string): string; override;
    function  WriteClient(var Buffer; Count: Integer): Integer; override;
    function  WriteString(const AString: string): Boolean; override;
    function  WriteHeaders(StatusCode: Integer; const ReasonString,
                           Headers: string): Boolean; override;
  end;
{$ENDIF}

implementation

{$IF NOT DEFINED(FPC)}

{ Web.HTTPApp declares these indices privately inside TWebRequest as the
  argument values passed to GetStringVariable. They have been stable across
  Delphi versions from XE onward. Re-declared here so we do not depend on
  private symbols of Web.HTTPApp.

  VERIFY: if Embarcadero changes the enumeration in a future Delphi release,
  only this table needs updating. }
const
  HRV_Method           = 0;
  HRV_ProtocolVersion  = 1;
  HRV_URL              = 2;
  HRV_Query            = 3;
  HRV_PathInfo         = 4;
  HRV_PathTranslated   = 5;
  HRV_CacheControl     = 6;
  HRV_Date             = 7;
  HRV_Accept           = 8;
  HRV_From             = 9;
  HRV_Host             = 10;
  HRV_IfModifiedSince  = 11;
  HRV_Referer          = 12;
  HRV_UserAgent        = 13;
  HRV_ContentEncoding  = 14;
  HRV_ContentType      = 15;
  HRV_ContentLength    = 16;
  HRV_ContentVersion   = 17;
  HRV_DerivedFrom      = 18;
  HRV_Expires          = 19;
  HRV_Title            = 20;
  HRV_RemoteAddr       = 21;
  HRV_RemoteHost       = 22;
  HRV_ScriptName       = 23;
  HRV_ServerPort       = 24;
  HRV_Content          = 25;
  HRV_Connection       = 26;
  HRV_Cookie           = 27;
  HRV_Authorization    = 28;

{ TCrossSocketWebRequest }

constructor TCrossSocketWebRequest.Create(const ACrossReq: ICrossHttpRequest);
var
  NV: TNameValue;
begin
  { Assign FCrossReq BEFORE inherited Create — TWebRequest.Create calls
    GetStringVariable internally to initialise its own state (Method,
    ContentType, etc.).  If FCrossReq is still nil at that point the
    virtual dispatch crashes with an AV. }
  FCrossReq      := ACrossReq;
  FContentCache  := '';
  FContentCached := False;
  inherited Create;

  { Populate the inherited TStrings created by TWebRequest.Create.
    QueryFields / ContentFields / CookieFields are read-only properties
    backed by private fields — no virtual getter to override — so we
    fill them eagerly here instead. }
  for NV in FCrossReq.Query do
    QueryFields.Add(NV.Name + '=' + NV.Value);

  if (FCrossReq.BodyType = btUrlEncoded) and (FCrossReq.Body is THttpUrlParams) then
    for NV in (FCrossReq.Body as THttpUrlParams) do
      ContentFields.Add(NV.Name + '=' + NV.Value);

  for NV in FCrossReq.Cookies do
    CookieFields.Add(NV.Name + '=' + NV.Value);
end;

destructor TCrossSocketWebRequest.Destroy;
begin
  FCrossReq := nil;
  inherited;  { TWebRequest.Destroy frees QueryFields / ContentFields / CookieFields }
end;

function TCrossSocketWebRequest.GetContentAsString: string;
var
  LStream: TStream;
  LBytes:  TBytes;
begin
  if FContentCached then Exit(FContentCache);
  FContentCache := '';
  if (FCrossReq.Body <> nil) and (FCrossReq.Body is TStream) then
  begin
    LStream := TStream(FCrossReq.Body);
    LStream.Position := 0;
    SetLength(LBytes, LStream.Size);
    if LStream.Size > 0 then
      LStream.Read(LBytes[0], LStream.Size);
    FContentCache := TEncoding.UTF8.GetString(LBytes);
  end;
  FContentCached := True;
  Result := FContentCache;
end;

function TCrossSocketWebRequest.GetStringVariable(Index: Integer): string;
begin
  if FCrossReq = nil then Exit('');
  case Index of
    HRV_Method:           Result := FCrossReq.Method;
    HRV_ProtocolVersion:  Result := 'HTTP/1.1';
    HRV_URL:              Result := FCrossReq.RawPathAndParams;
    HRV_Query:
      begin
        Result := FCrossReq.RawPathAndParams;
        if Pos('?', Result) > 0 then
          Result := Copy(Result, Pos('?', Result) + 1, MaxInt)
        else
          Result := '';
      end;
    HRV_PathInfo:         Result := FCrossReq.Path;
    HRV_PathTranslated:   Result := FCrossReq.Path;
    HRV_CacheControl:     Result := FCrossReq.Header['Cache-Control'];
    HRV_Date:             Result := FCrossReq.Header['Date'];
    HRV_Accept:           Result := FCrossReq.Header['Accept'];
    HRV_From:             Result := FCrossReq.Header['From'];
    HRV_Host:             Result := FCrossReq.HostName;
    HRV_IfModifiedSince:  Result := FCrossReq.Header['If-Modified-Since'];
    HRV_Referer:          Result := FCrossReq.Header['Referer'];
    HRV_UserAgent:        Result := FCrossReq.Header['User-Agent'];
    HRV_ContentEncoding:  Result := FCrossReq.Header['Content-Encoding'];
    HRV_ContentType:      Result := FCrossReq.ContentType;
    HRV_ContentLength:    Result := FCrossReq.Header['Content-Length'];
    HRV_ContentVersion:   Result := FCrossReq.Header['Content-Version'];
    HRV_DerivedFrom:      Result := FCrossReq.Header['Derived-From'];
    HRV_Expires:          Result := FCrossReq.Header['Expires'];
    HRV_Title:            Result := FCrossReq.Header['Title'];
    HRV_RemoteAddr:       Result := FCrossReq.Connection.PeerAddr;
    HRV_RemoteHost:       Result := FCrossReq.Connection.PeerAddr;
    HRV_ScriptName:       Result := '';
    HRV_ServerPort:
      { VERIFY: ICrossConnection.LocalPort — confirmed on Net.CrossSocket.Base
        as a property returning Word. If the accessor name differs in the
        Delphi-Cross-Socket version shipped, update to the correct member. }
      Result := IntToStr(FCrossReq.Connection.LocalPort);
    HRV_Content:          Result := GetContentAsString;
    HRV_Connection:       Result := FCrossReq.Header['Connection'];
    HRV_Cookie:           Result := FCrossReq.Header['Cookie'];
    HRV_Authorization:    Result := FCrossReq.Header['Authorization'];
  else
    Result := '';
  end;
end;

function TCrossSocketWebRequest.GetDateVariable(Index: Integer): TDateTime;
begin
  { Middleware that reads Date / If-Modified-Since as a parsed date is rare.
    Returning 0 matches the behaviour of TWebRequest when the header is
    missing or unparseable. }
  Result := 0;
end;

function TCrossSocketWebRequest.GetIntegerVariable(Index: Integer): Int64;
var
  S: string;
begin
  if FCrossReq = nil then Exit(-1);
  case Index of
    HRV_ContentLength:
      begin
        S := FCrossReq.Header['Content-Length'];
        if S = '' then Exit(-1);
        Result := StrToInt64Def(S, -1);
      end;
    HRV_ServerPort:
      { VERIFY: see GetStringVariable / HRV_ServerPort. }
      Result := FCrossReq.Connection.LocalPort;
  else
    Result := -1;
  end;
end;

function TCrossSocketWebRequest.GetFieldByName(const Name: string): string;
begin
  { CrossSocket's THttpHeader default indexer performs case-insensitive
    lookup by name — same contract as TWebRequest.GetFieldByName. }
  Result := FCrossReq.Header[Name];
end;

function TCrossSocketWebRequest.ReadClient(var Buffer; Count: Integer): Integer;
var
  LStream: TStream;
begin
  { Streaming read from the body. FCrossReq.Body is a TMemoryStream for btBinary;
    for btUrlEncoded / btMultiPart it is a parsed container (not a TStream) —
    ReadClient on a parsed body returns 0 (no raw bytes to re-stream). Callers
    typically use Content / GetContentAsString on parsed bodies. }
  if not (FCrossReq.Body is TStream) then Exit(0);
  LStream := TStream(FCrossReq.Body);
  Result := LStream.Read(Buffer, Count);
end;

function TCrossSocketWebRequest.ReadString(Count: Integer): string;
var
  LBytes: TBytes;
  LRead:  Integer;
begin
  if Count <= 0 then Exit('');
  SetLength(LBytes, Count);
  LRead := ReadClient(LBytes[0], Count);
  if LRead <= 0 then Exit('');
  SetLength(LBytes, LRead);
  Result := TEncoding.UTF8.GetString(LBytes);
end;

function TCrossSocketWebRequest.TranslateURI(const URI: string): string;
begin
  { WebBroker's default implementation maps virtual paths to filesystem paths.
    Horse does not serve files through RawWebRequest; return the URI as-is. }
  Result := URI;
end;

function TCrossSocketWebRequest.WriteClient(var Buffer; Count: Integer): Integer;
begin
  { Responses must go through THorseResponse — see TResponseBridge.Flush.
    Writing to RawWebRequest is not supported on the CrossSocket path. }
  Result := 0;
end;

function TCrossSocketWebRequest.WriteString(const AString: string): Boolean;
begin
  Result := False;
end;

function TCrossSocketWebRequest.WriteHeaders(StatusCode: Integer;
  const ReasonString, Headers: string): Boolean;
begin
  Result := False;
end;

{$ELSE}  // FPC

{ TCrossSocketWebRequest — FPC }

constructor TCrossSocketWebRequest.Create(const ACrossReq: ICrossHttpRequest);
var
  NV: TNameValue;
begin
  inherited Create;
  FCrossReq := ACrossReq;

  { HTTPDefs.TRequest exposes these as read/write string properties. }
  Method          := ACrossReq.Method;
  URL             := ACrossReq.RawPathAndParams;
  URI             := ACrossReq.RawPathAndParams;
  PathInfo        := ACrossReq.Path;
  Host            := ACrossReq.HostName;
  ContentType     := ACrossReq.ContentType;
  RemoteAddr      := ACrossReq.Connection.PeerAddr;
  RemoteHost      := ACrossReq.Connection.PeerAddr;
  ProtocolVersion := 'HTTP/1.1';
  { VERIFY: on some FPC versions ServerPort is Word rather than string.
    If the direct assignment below fails to compile, replace with
    ServerPort := IntToStr(FCrossReq.Connection.LocalPort); }
  ServerPort      := IntToStr(FCrossReq.Connection.LocalPort);

  for NV in ACrossReq.Query do
    QueryFields.Add(NV.Name + '=' + NV.Value);

  if (ACrossReq.BodyType = btUrlEncoded) and (ACrossReq.Body is THttpUrlParams) then
    for NV in (ACrossReq.Body as THttpUrlParams) do
      ContentFields.Add(NV.Name + '=' + NV.Value);

  for NV in ACrossReq.Cookies do
    CookieFields.Add(NV.Name + '=' + NV.Value);
end;

{$ENDIF}

end.
