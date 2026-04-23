unit Horse.Provider.CrossSocket.RawRequest;

{
  CrossSocket IHorseRawRequest implementation
  ===========================================
  Wraps ICrossHttpRequest in ~15 one-liner methods.
  The generic TInterfacedWebRequest adapter (Horse.Provider.RawAdapters)
  delegates here to build a full TWebRequest compatible with all middleware.

  Dual-compilation: Delphi and FPC share the same implementation — no
  platform-specific code needed at this layer.
}

{$IF DEFINED(FPC)}
{$MODE DELPHI}{$H+}
{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes,
{$ELSE}
  System.SysUtils,
  System.Classes,
{$ENDIF}
  Net.CrossHttpServer,
  Net.CrossHttpParams,
  Horse.Provider.RawInterfaces;

type
  TCrossSocketRawRequest = class(TInterfacedObject, IHorseRawRequest)
  private
    FCrossReq:      ICrossHttpRequest;
    FContentCache:  string;
    FContentCached: Boolean;
  public
    constructor Create(const ACrossReq: ICrossHttpRequest);

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

constructor TCrossSocketRawRequest.Create(const ACrossReq: ICrossHttpRequest);
begin
  inherited Create;
  FCrossReq      := ACrossReq;
  FContentCache  := '';
  FContentCached := False;
end;

function TCrossSocketRawRequest.GetMethod: string;
begin
  Result := FCrossReq.Method;
end;

function TCrossSocketRawRequest.GetProtocolVersion: string;
begin
  Result := 'HTTP/1.1';
end;

function TCrossSocketRawRequest.GetURL: string;
begin
  Result := FCrossReq.RawPathAndParams;
end;

function TCrossSocketRawRequest.GetPathInfo: string;
begin
  Result := FCrossReq.Path;
end;

function TCrossSocketRawRequest.GetQueryString: string;
var
  S: string;
begin
  S := FCrossReq.RawPathAndParams;
  if Pos('?', S) > 0 then
    Result := Copy(S, Pos('?', S) + 1, MaxInt)
  else
    Result := '';
end;

function TCrossSocketRawRequest.GetHost: string;
begin
  Result := FCrossReq.HostName;
end;

function TCrossSocketRawRequest.GetRemoteAddr: string;
begin
  Result := FCrossReq.Connection.PeerAddr;
end;

function TCrossSocketRawRequest.GetServerPort: Integer;
begin
  Result := FCrossReq.Connection.LocalPort;
end;

function TCrossSocketRawRequest.GetContentType: string;
begin
  Result := FCrossReq.ContentType;
end;

function TCrossSocketRawRequest.GetContent: string;
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

{$IF DEFINED(FPC)}
function TCrossSocketRawRequest.GetContentLength: Integer;
{$ELSEIF CompilerVersion >= 32.0}
function TCrossSocketRawRequest.GetContentLength: Int64;
{$ELSE}
function TCrossSocketRawRequest.GetContentLength: Integer;
{$IFEND}
var
  S: string;
begin
  S := FCrossReq.Header['Content-Length'];
  if S = '' then Exit(-1);
  Result := StrToInt64Def(S, -1);
end;

function TCrossSocketRawRequest.GetFieldByName(const AName: string): string;
begin
  Result := FCrossReq.Header[AName];
end;

procedure TCrossSocketRawRequest.PopulateQueryFields(ADest: TStrings);
var
  NV: TNameValue;
begin
  for NV in FCrossReq.Query do
    ADest.Add(NV.Name + '=' + NV.Value);
end;

procedure TCrossSocketRawRequest.PopulateContentFields(ADest: TStrings);
var
  NV: TNameValue;
begin
  if (FCrossReq.BodyType = btUrlEncoded) and (FCrossReq.Body is THttpUrlParams) then
    for NV in (FCrossReq.Body as THttpUrlParams) do
      ADest.Add(NV.Name + '=' + NV.Value);
end;

procedure TCrossSocketRawRequest.PopulateCookieFields(ADest: TStrings);
var
  NV: TNameValue;
begin
  for NV in FCrossReq.Cookies do
    ADest.Add(NV.Name + '=' + NV.Value);
end;

function TCrossSocketRawRequest.ReadBody(var Buffer; Count: Integer): Integer;
var
  LStream: TStream;
begin
  if not (FCrossReq.Body is TStream) then Exit(0);
  LStream := TStream(FCrossReq.Body);
  Result := LStream.Read(Buffer, Count);
end;

end.
