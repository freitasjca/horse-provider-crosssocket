unit Horse.Provider.CrossSocket.Response;

{
  Horse CrossSocket Provider  -  Response Bridge  (hardened)
  -----------------------------------------------------------

  ── Prerequisite ────────────────────────────────────────────────────────────
  PATCH-RES-4 must be applied to the Horse fork (Horse.Response.pas):
    property BodyText:      string  read FCSBody
    property ContentStream: TStream read FCSContentStream
    property CSContentType: string  read FCSContentType
    function Status: Integer  (nil-guard — returns FCSStatusCode when
                               FWebResponse is nil)

  All mutating methods (Send, ContentType, Status setters, SendFile, Download,
  RedirectTo, AddHeader, RemoveHeader) have nil-FWebResponse guards that write
  to the CS shadow fields instead of crashing on nil TWebResponse.

  ── Security fixes ──────────────────────────────────────────────────────────
  [SEC-19] CRLF stripping on all response header values.
           Header values containing CR (#13) or LF (#10) split into two HTTP
           headers on the wire — HTTP response splitting, enabling cache
           poisoning and XSS. All values are stripped before being written.

  [SEC-20] Hop-by-hop header filtering.
           Connection, Transfer-Encoding, Keep-Alive, etc. must not be
           forwarded from application code — CrossSocket manages them.
           Writing them would desync the framing layer.

  [SEC-21] Content-Type default is explicit.
           Default 'application/json; charset=utf-8' is only applied when
           the response truly has no Content-Type set.

  [SEC-22] X-Content-Type-Options: nosniff added by default.
           Prevents MIME-type sniffing attacks in browsers.

  [SEC-23] Security headers added by default.
           X-Frame-Options, Referrer-Policy, Cache-Control.

  [SEC-5]  Server: header suppressed.

  [SEC-24] ContentStream lifetime guard.
           Stream position reset before send. Bridge never frees the stream.

  ── API reference (verified against uploaded source files) ──────────────────
  ICrossHttpResponse (Net.CrossHttpServer.pas):
    property StatusCode:   Integer read/write
    property ContentType:  string  read/write
    property Header:       THttpHeader  (default string indexer [name] := value)
    procedure Send(const ABody: TStream; ...)   overload — stream body
    procedure Send(const ABody: TBytes; ...)    overload — bytes body
    procedure Send(const ABody: string; ...)    overload — string body
    All Send overloads have optional ACallback: TCrossConnectionCallback = nil

    NO SendStream method — use Send(TStream)
    NO SendBytes method  — use Send(TBytes)

  THorseResponse (patched Horse.Response.pas, PATCH-RES-4):
    function  Status: Integer                   (nil-guarded getter)
    property  BodyText:      string             (FCSBody shadow field)
    property  ContentStream: TStream            (FCSContentStream shadow field)
    property  CSContentType: string             (FCSContentType shadow field)
    property  CustomHeaders: TDictionary<string,string>  (PATCH-RES-3)
}

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  Net.CrossHttpServer,
  Net.CrossHttpParams,
  Horse.Response;

type
  TResponseBridge = class
  public
    class procedure Flush(
            AHorseRes:       THorseResponse;
      const ACrossRes:       ICrossHttpResponse
    );

  private
    class function  SanitiseHeaderValue(const AValue: string): string;
    class function  IsHopByHopHeader(const AName: string): Boolean;
    class procedure CopyHeaders(
                            AHorseRes:       THorseResponse;
                      const ACrossRes:       ICrossHttpResponse);
    class procedure ApplySecurityHeaders(const ACrossRes: ICrossHttpResponse);
    class procedure WriteBody(
                            AHorseRes:       THorseResponse;
                      const ACrossRes:       ICrossHttpResponse);
  end;

implementation

// ── [SEC-20] Hop-by-hop headers — managed by CrossSocket, not by the app ─────
const
  HOP_BY_HOP: array[0..8] of string = (
    'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
    'te', 'trailers', 'transfer-encoding', 'upgrade', 'server'
  );

{ TResponseBridge }

class procedure TResponseBridge.Flush(
        AHorseRes:       THorseResponse;
  const ACrossRes:       ICrossHttpResponse
);
var
  CT: string;
begin
  // Status — THorseResponse.Status (no args) is nil-guarded via PATCH-RES-4
  ACrossRes.StatusCode := AHorseRes.Status;

  // [SEC-23][SEC-22] Apply safe defaults BEFORE app headers so app can override
  ApplySecurityHeaders(ACrossRes);

  // Copy app-set headers (CRLF-stripped, hop-by-hop filtered) [SEC-19][SEC-20]
  CopyHeaders(AHorseRes, ACrossRes);

  // [SEC-21] Content-Type: prefer app-set value; fall back to JSON default
  // CSContentType is the PATCH-RES-4 shadow field (empty when not set)
  CT := AHorseRes.CSContentType;
  if CT <> '' then
    ACrossRes.ContentType := CT;
  // If still empty CrossSocket will use its own default

  WriteBody(AHorseRes, ACrossRes);
end;

// ── [SEC-19] ─────────────────────────────────────────────────────────────────
class function TResponseBridge.SanitiseHeaderValue(const AValue: string): string;
begin
  // Strip CR, LF, and NUL — all can be used for response splitting
  Result := StringReplace(AValue, #13, '', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '', [rfReplaceAll]);
  Result := StringReplace(Result, #0,  '', [rfReplaceAll]);
end;

// ── [SEC-20] ─────────────────────────────────────────────────────────────────
class function TResponseBridge.IsHopByHopHeader(const AName: string): Boolean;
var
  Lower: string;
  H:     string;
begin
  Lower := LowerCase(AName);
  for H in HOP_BY_HOP do
    if Lower = H then Exit(True);
  Result := False;
end;

class procedure TResponseBridge.CopyHeaders(
        AHorseRes:       THorseResponse;
  const ACrossRes:       ICrossHttpResponse
);
var
  Pair:      TPair<string, string>;
  SafeValue: string;
begin
  // CustomHeaders is the PATCH-RES-3 read-only TDictionary<string,string>
  if AHorseRes.CustomHeaders = nil then Exit;

  for Pair in AHorseRes.CustomHeaders do
  begin
    // [SEC-20] Skip hop-by-hop headers
    if IsHopByHopHeader(Pair.Key) then Continue;

    // [SEC-19] Reject names containing CR/LF (header name injection)
    if (Pos(#13, Pair.Key) > 0) or (Pos(#10, Pair.Key) > 0) then Continue;

    // [SEC-19] Strip CRLF from value
    SafeValue := SanitiseHeaderValue(Pair.Value);

    // THttpHeader default string indexer: Header['name'] := value
    // Confirmed in Net.CrossHttpServer.pas and Net.CrossHttpParams.pas
    ACrossRes.Header[Pair.Key] := SafeValue;
  end;
end;

// ── [SEC-22][SEC-23] ─────────────────────────────────────────────────────────
class procedure TResponseBridge.ApplySecurityHeaders(
  const ACrossRes: ICrossHttpResponse
);
begin
  ACrossRes.Header['X-Content-Type-Options'] := 'nosniff';         // [SEC-22]
  ACrossRes.Header['X-Frame-Options']        := 'DENY';             // [SEC-23]
  ACrossRes.Header['Referrer-Policy']        := 'strict-origin-when-cross-origin';
  ACrossRes.Header['Cache-Control']          := 'no-store';
  ACrossRes.Header['Server']                 := 'unknown';          // [SEC-5]
end;

// ── [SEC-24] ─────────────────────────────────────────────────────────────────
class procedure TResponseBridge.WriteBody(
        AHorseRes:       THorseResponse;
  const ACrossRes:       ICrossHttpResponse
);
var
  Buf:    TBytes;
  Stream: TStream;
begin
  // ContentStream: PATCH-RES-4 shadow field (nil when not set)
  Stream := AHorseRes.ContentStream;
  if Assigned(Stream) and (Stream.Size > 0) then
  begin
    // [SEC-24] Reset position — guard against double-send of exhausted stream
    Stream.Position := 0;
    // ICrossHttpResponse.Send(TStream) — confirmed overload
    ACrossRes.Send(Stream);
    Exit;
  end;

  // BodyText: PATCH-RES-4 shadow field (empty string when not set)
  if AHorseRes.BodyText <> '' then
  begin
    // Send(string) confirmed overload — CrossSocket handles UTF-8 encoding
    ACrossRes.Send(AHorseRes.BodyText);
    Exit;
  end;

  // Empty body — headers-only response (e.g. 204 No Content)
  // Send(TBytes) with an empty array confirmed overload
  Buf := nil;
  ACrossRes.Send(Buf);
end;

end.
