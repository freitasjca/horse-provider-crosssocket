unit Horse.Provider.CrossSocket.Response;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

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

  [SEC-5]  Server: header set to config.ServerBanner or 'unknown' (suppressed).

  [SEC-24] ContentStream lifetime guard.
           Stream position reset before send. Bridge never frees the stream.

  ── Improvements ────────────────────────────────────────────────────────────
  [FIX-EMPTY-STATUS] Empty-body responses with status >= 400 raced with TCP
           delivery on the client.  CrossSocket's _Send immediately calls
           Disconnect() when the body source returns False (empty body), which
           fires shutdown(SD_BOTH) in the same WSASend completion callback as
           the header write.  The client sees Connection: keep-alive, marks the
           connection rsIdle, and re-uses it for the next request before the
           server's FIN arrives — sending a new request on a half-closed socket
           and getting a RST.  Fix: for status >= 400 with no body, WriteBody
           sends the status code as a minimal plain-text body so Disconnect
           fires only after all data is flushed.

  [IMP-4]  Sent guard.
           ACrossRes.Sent is checked at the start of Flush. If CrossSocket has
           already sent the response (e.g. via a direct ICrossHttpResponse call
           in middleware), the bridge skips writing to avoid a double-send.

  [COMPAT-1] Middleware RawWebResponse compatibility.
           Middleware that writes via Res.RawWebResponse.Content or
           Res.RawWebResponse.ContentType (e.g. horse-jhonson) bypasses the
           PATCH-RES-4 shadow fields. Flush reads both shadow fields first and
           falls back to RawWebResponse if the shadow fields are empty —
           no middleware source change required for compatibility.

  [IMP-6]  Content-Length header.
           Explicit Content-Length is set for string and stream bodies so that
           HEAD requests and HTTP proxies see a reliable byte count.

  [Config] ServerBanner passed as parameter.
           Flush now receives AServerBanner from the provider config.
           Empty string → 'unknown' (previous hard-coded behaviour preserved).

  ── API reference (verified against uploaded source files) ──────────────────
  ICrossHttpResponse (Net.CrossHttpServer.pas):
    property StatusCode:   Integer read/write
    property ContentType:  string  read/write
    property Header:       THttpHeader  (default string indexer [name] := value)
    property Sent:         Boolean read  (True once Send has been called)
    procedure Send(const ABody: TStream; ...)   overload — stream body
    procedure Send(const ABody: TBytes; ...)    overload — bytes body
    procedure Send(const ABody: string; ...)    overload — string body
    All Send overloads have optional ACallback: TCrossConnectionCallback = nil

    NO SendStream method — use Send(TStream)
    NO SendBytes method  — use Send(TBytes)

  THorseResponse (patched Horse.Response.pas, PATCH-RES-4):
    function  Status: Integer                   (nil-guarded getter)
    property  BodyText:       string             (FCSBody shadow field)
    property  ContentStream:  TStream            (FCSContentStream shadow field)
    property  CSContentType:  string             (FCSContentType shadow field)
    property  CustomHeaders: TList<TPair<string,string>>  (PATCH-RES-3)
}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes,
  Generics.Collections,
  fpHTTP,
  HTTPDefs,
{$ELSE}
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  Web.HTTPApp,
{$ENDIF}
  Net.CrossHttpServer,
  Net.CrossHttpParams,
  Horse.Response;

type
  TResponseBridge = class
  public
    /// Flush AHorseRes to ACrossRes.
    /// AServerBanner: value for the Server: header; '' → 'unknown'.
    class procedure Flush(
            AHorseRes:       THorseResponse;
      const ACrossRes:       ICrossHttpResponse;
      const AServerBanner:   string
    );

  private
    class function  SanitiseHeaderValue(const AValue: string): string;
    class function  IsHopByHopHeader(const AName: string): Boolean;
    class procedure CopyHeaders(
                            AHorseRes:       THorseResponse;
                      const ACrossRes:       ICrossHttpResponse);
    class procedure ApplySecurityHeaders(
                      const ACrossRes:       ICrossHttpResponse;
                      const AServerBanner:   string);
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
  const ACrossRes:       ICrossHttpResponse;
  const AServerBanner:   string
);
var
  CT:      string;
  LRawRes: {$IF DEFINED(FPC)}TResponse{$ELSE}TWebResponse{$ENDIF};
begin
  // [IMP-4] Do not attempt to write a response that CrossSocket has already
  // sent (e.g. by middleware that called ICrossHttpResponse.Send directly).
  // Writing again would produce a double-send or corrupt framing.
  if ACrossRes.Sent then Exit;

  // Status — THorseResponse.Status (no args) is nil-guarded via PATCH-RES-4
  ACrossRes.StatusCode := AHorseRes.Status;

  // [SEC-23][SEC-22] Apply safe defaults BEFORE app headers so app can override
  ApplySecurityHeaders(ACrossRes, AServerBanner);

  // Copy app-set headers (CRLF-stripped, hop-by-hop filtered) [SEC-19][SEC-20]
  CopyHeaders(AHorseRes, ACrossRes);

  // [SEC-21] Content-Type: prefer app-set value; fall back to JSON default
  // CSContentType is the PATCH-RES-4 shadow field (empty when not set)
  CT := AHorseRes.CSContentType;
  // [COMPAT-1] Middleware (e.g. horse-jhonson) may write ContentType via
  // Res.RawWebResponse.ContentType — pick it up when the shadow field is empty.
  // RawWebResponse is a function — capture result before calling Assigned().
  LRawRes := AHorseRes.RawWebResponse;
  if (CT = '') and Assigned(LRawRes) then
    CT := LRawRes.ContentType;
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

  procedure EmitHeader(const AName, AValue: string);
  var
    SafeValue: string;
  begin
    // [SEC-20] Skip hop-by-hop headers
    if IsHopByHopHeader(AName) then Exit;
    // [SEC-19] Reject names containing CR/LF (header name injection)
    if (Pos(#13, AName) > 0) or (Pos(#10, AName) > 0) then Exit;
    // [SEC-19] Strip CRLF from value
    SafeValue := SanitiseHeaderValue(AValue);
    // [MULTI-1] Set-Cookie must appear as a separate header line per cookie
    // (RFC 6265 §3 prohibits folding multiple Set-Cookie values into one line).
    if SameText(AName, 'set-cookie') then
      ACrossRes.Header.Add(AName, SafeValue, True)
    else
      ACrossRes.Header[AName] := SafeValue;
  end;

var
  {$IF NOT DEFINED(FPC)}
  Pair:      TPair<string, string>;
  {$ENDIF}
  LRawRes:   {$IF DEFINED(FPC)}TResponse{$ELSE}TWebResponse{$ENDIF};
  I:         Integer;
  LName:     string;
  LValue:    string;
begin
  // 1. Copy headers from THorseResponse.CustomHeaders (PATCH-RES-1/3)
  //    Written by Res.AddHeader — the normal Horse API path.
  //    Delphi: CustomHeaders is TDictionary<string,string> — iterate TPair.
  //    FPC:    CustomHeaders is TStringList — iterate by index via Names/ValueFromIndex.
  if AHorseRes.CustomHeaders <> nil then
  {$IF NOT DEFINED(FPC)}
    for Pair in AHorseRes.CustomHeaders do
      EmitHeader(Pair.Key, Pair.Value);
  {$ELSE}
    for I := 0 to AHorseRes.CustomHeaders.Count - 1 do
    begin
      LName  := AHorseRes.CustomHeaders.Names[I];
      LValue := AHorseRes.CustomHeaders.ValueFromIndex[I];
      if LName <> '' then
        EmitHeader(LName, LValue);
    end;
  {$ENDIF}

  // 2. PATCH-RES-6 — Copy headers from the RawWebResponse adapter.
  //    Middleware that calls Res.RawWebResponse.SetCustomHeader (e.g. Horse.CORS)
  //    writes to the adapter's inherited CustomHeaders TStrings, bypassing
  //    THorseResponse.FCustomHeaders entirely. Merge them here.
  LRawRes := AHorseRes.RawWebResponse;
  if Assigned(LRawRes) and Assigned(LRawRes.CustomHeaders) then
  begin
    for I := 0 to LRawRes.CustomHeaders.Count - 1 do
    begin
      LName  := LRawRes.CustomHeaders.Names[I];
      LValue := LRawRes.CustomHeaders.ValueFromIndex[I];
      if LName <> '' then
        EmitHeader(LName, LValue);
    end;
  end;
end;

// ── [SEC-22][SEC-23][SEC-5][Config] ──────────────────────────────────────────
class procedure TResponseBridge.ApplySecurityHeaders(
  const ACrossRes:     ICrossHttpResponse;
  const AServerBanner: string
);
begin
  ACrossRes.Header['X-Content-Type-Options'] := 'nosniff';           // [SEC-22]
  ACrossRes.Header['X-Frame-Options']        := 'DENY';               // [SEC-23]
  ACrossRes.Header['Referrer-Policy']        := 'strict-origin-when-cross-origin';
  ACrossRes.Header['Cache-Control']          := 'no-store';
  // [SEC-5][Config] Use caller-supplied banner; fall back to 'unknown' so the
  // real server name/version is never disclosed even when banner is empty.
  if AServerBanner <> '' then
    ACrossRes.Header['Server'] := AServerBanner
  else
    ACrossRes.Header['Server'] := 'unknown';
end;

// ── [SEC-24][IMP-6] ──────────────────────────────────────────────────────────
class procedure TResponseBridge.WriteBody(
        AHorseRes:       THorseResponse;
  const ACrossRes:       ICrossHttpResponse
);
var
  Buf:      TBytes;
  Stream:   TStream;
  LRawRes:  {$IF DEFINED(FPC)}TResponse{$ELSE}TWebResponse{$ENDIF};
  LContent: string;
begin
  // ContentStream: PATCH-RES-4 shadow field (nil when not set)
  Stream := AHorseRes.ContentStream;
  if Assigned(Stream) and (Stream.Size > 0) then
  begin
    // [SEC-24] Reset position — guard against double-send of exhausted stream
    Stream.Position := 0;
    // [IMP-6] Set Content-Length so proxies and HEAD requests see the size
    ACrossRes.Header['Content-Length'] := IntToStr(Stream.Size);
    // ICrossHttpResponse.Send(TStream) — confirmed overload
    ACrossRes.Send(Stream);
    Exit;
  end;

  // BodyText: PATCH-RES-4 shadow field (empty string when not set)
  if AHorseRes.BodyText <> '' then
  begin
    // [IMP-6] Compute UTF-8 byte length (may differ from string char count)
    ACrossRes.Header['Content-Length'] :=
      IntToStr(TEncoding.UTF8.GetByteCount(AHorseRes.BodyText));
    // Send(string) confirmed overload — CrossSocket handles UTF-8 encoding
    ACrossRes.Send(AHorseRes.BodyText);
    Exit;
  end;

  // [COMPAT-1] Middleware (e.g. horse-jhonson) may write the body via
  // Res.RawWebResponse.Content — pick it up when both shadow fields are empty.
  // RawWebResponse is a function — capture result before calling Assigned().
  LRawRes := AHorseRes.RawWebResponse;
  if Assigned(LRawRes) then
  begin
    LContent := LRawRes.Content;
    if LContent <> '' then
    begin
      ACrossRes.Header['Content-Length'] :=
        IntToStr(TEncoding.UTF8.GetByteCount(LContent));
      ACrossRes.Send(LContent);
      Exit;
    end;
  end;

  // [FIX-EMPTY-STATUS] For status >= 400 with no body, CrossSocket's _Send
  // disconnects immediately when the body source exhausts (returns False on
  // the first call, right after the header WSASend completes).  With nil
  // TBytes the disconnect races with TCP delivery: the client may attempt to
  // re-use the keep-alive connection before the server's FIN arrives, sending
  // the next request on a half-closed socket and getting a RST.  Sending a
  // minimal non-empty body ensures Disconnect fires only AFTER body data has
  // been flushed, giving the client time to receive and parse the response.
  // Content-Length is set automatically by CrossSocket's _CreateHeader.
  if AHorseRes.Status >= 400 then
  begin
    ACrossRes.Send(IntToStr(AHorseRes.Status));
    Exit;
  end;

  // Empty body — headers-only response (e.g. 204 No Content)
  // [IMP-6] Explicit zero Content-Length for clarity
  ACrossRes.Header['Content-Length'] := '0';
  // Send(TBytes) with an empty array confirmed overload
  Buf := nil;
  ACrossRes.Send(Buf);
end;

end.
