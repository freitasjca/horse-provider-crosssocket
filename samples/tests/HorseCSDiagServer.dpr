program HorseCSDiagServer;

{$APPTYPE CONSOLE}

{ Enables the [SLOTS] diagnostic — the most useful line this program prints.
  It reads THorseResponse.BodyText / BodyBytes / ContentStream / CSContentType,
  which are the PATCH-RES-4 shadow properties. If your Horse build does not
  expose them the program will not compile: comment this line out and you lose
  only that one diagnostic. }
{$DEFINE DIAG_SLOTS}

{ Link Horse.Jhonson, the JSON middleware the reporter uses. Without it,
  Res.Send(TJSONObject) writes no body slot at all and /probe/object and
  /probe/usershape return 200 with zero bytes -- which is exactly what v2
  measured. Comment this out to reproduce that empty-body baseline.
  Requires the jhonson src folder on the unit path; build-diag-dcc.bat adds it. }
{$DEFINE USE_JHONSON}

{ Accept EITHER spelling of the transport define.

  build-tests-dcc.bat (and build-diag-dcc.bat beside it) compile with
  -DHORSE_PROVIDER_CROSSSOCKET — the canonical PATCH-HORSE-2 name — while the
  branches in this program test HORSE_CROSSSOCKET, the legacy alias. Without
  this block, building through those scripts would silently compile the INDY
  path while the banner claimed CrossSocket, and the whole comparison would be
  void. That is the same class of failure as a stale DCU, authored in source.

  Neither name is defined here on purpose: pass it on the command line, or set
  it in Project > Options > Conditional defines. See the warning below. }
{$IF DEFINED(HORSE_PROVIDER_CROSSSOCKET) and not DEFINED(HORSE_CROSSSOCKET)}
  {$DEFINE HORSE_CROSSSOCKET}
{$ENDIF}

{
  Horse + CrossSocket  —  PUT / response-encoding DIAGNOSTIC server
  =================================================================
  Destination: horse-provider-crosssocket/samples/tests/HorseCSDiagServer.dpr

  Purpose
  -------
  Reproduce and isolate the reported failure:

    "PUT returns JSON, but the client raises 'No mapping for the Unicode
     character exists in the target multi-byte code page' on
     Response.ContentAsString(TEncoding.UTF8). GET and POST are fine.
     Disabling HORSE_CROSSSOCKET fixes it."

  That exception means the response bytes are not valid UTF-8. This server
  isolates the three candidate causes by varying ONE factor at a time:

    1. METHOD    — the same handler is registered on GET, POST and PUT, so if
                   only PUT fails, it is genuinely the method. If GET /large
                   fails too, the method was never the variable: size was.
    2. SIZE      — CrossSocket only gzips bodies >= MinCompressSize (512).
                   ?size=N lets you bisect that threshold exactly.
    3. NON-ASCII — /probe/accents is small but full of Spanish accents, so
                   encoding is tested independently of size.

  ============================ READ THIS FIRST ============================
  A DEFINE directive written in a .dpr does NOT invalidate already-compiled
  DCUs. If you toggle HORSE_CROSSSOCKET here and rebuild, Delphi may silently
  keep the DCUs built the other way and your A/B proves nothing.

  (No directive is spelled out with braces anywhere in this comment: Delphi's
  brace comments do not nest, so a quoted directive would close the block early
  and turn the rest of this header into bare code.)

  Set HORSE_CROSSSOCKET in Project > Options > Building > Delphi Compiler >
  Conditional defines, and Build (not Compile) after changing it.

  This program does not ask you to trust that. The [SLOTS] line is a RUNTIME
  transport oracle — see "Reading the output" below.
  ========================================================================

  Build
  -----
    Console app. Search path needs: horse/src, horse-provider-crosssocket/src,
    Delphi-Cross-Socket/Net, Delphi-Cross-Socket/Utils.

  Run
  ---
    HorseCSDiagServer.exe              → compression OFF (the Horse default)
    HorseCSDiagServer.exe --compress   → compression ON  (the A/B control)

  Routes (each registered on GET, POST and PUT with an identical handler)
  ----------------------------------------------------------------------
    /probe/small      small JSON, well under the 512-byte compression floor
    /probe/large      large JSON with a Base64 blob — mimics the real route.
                      ?size=N sets the decoded blob size; default 4096.
    /probe/accents    small JSON, heavy non-ASCII (tests encoding, not size)
    /probe/object     Res.Send(TJSONObject) — the FContent landmine, see below
    /probe/echo       echoes what the server actually received

  Reading the output
  ------------------
  Each request prints one [REQ] line and one [SLOTS] line.

  [SLOTS] is the transport oracle. The CrossSocket bridge reads these shadow
  fields in this exact order, and the FIRST non-empty one wins:

      ContentStream  -> sent as RAW BYTES (no encoding step)
      BodyBytes      -> sent as RAW BYTES (no encoding step)
      BodyText       -> sent via TEncoding.UTF8.GetBytes (always valid UTF-8)

  So:
    BodyText=<n>, others empty   -> CrossSocket path, UTF-8-safe branch.
    ContentStream or BodyBytes   -> CrossSocket path, RAW-BYTES branch. If the
                                    client then fails to decode UTF-8, this is
                                    your culprit.
    ALL slots empty, yet the      -> The shadow fields are only populated when
    client still gets a body         FWebResponse is nil. All-empty means the
                                     Indy/WebBroker path served it: your DCUs
                                     are stale, or HORSE_CROSSSOCKET is not
                                     actually defined for this build.

  The FContent landmine (/probe/object)
  -------------------------------------
  Res.Send(SomeTJSONObject) resolves to the generic THorseResponse.Send<T>,
  which only does FContent := AContent. Nothing in Horse core ever serializes
  FContent — that is a JSON middleware's job (Horse.Jhonson). Without one,
  /probe/object should come back with an EMPTY body. If it comes back with
  JSON, you have such a middleware registered, and that middleware is what
  chooses the body slot above.
}

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.NetEncoding,
  System.JSON,
  Horse,
  Horse.Commons,
  Horse.Response,
  { THorseCallbackRequestResponse (the 2-argument handler type) lives here and
    is NOT re-exported by Horse.pas — only the 3-argument THorseCallback is. }
  Horse.Callback,
{$IFDEF USE_JHONSON}
  Horse.Jhonson,
{$ENDIF}
{$IFDEF HORSE_CROSSSOCKET}
  Horse.Provider.Config,
  Horse.Provider.CrossSocket,
{$ENDIF}
  Horse.Core.Param;

const
  { Deliberately OUTSIDE 9000-9100. On several OEM Windows builds (Nahimic and
    friends) a background service squats that range and answers with a
    "301 -> about:blank", which looks exactly like a broken server. }
  DIAG_PORT         = 18080;
  DEFAULT_BLOB_SIZE = 4096;

var
  { CrossSocket dispatches handlers on arbitrary IOCP/epoll worker threads.
    Unsynchronised Writeln from several of them interleaves mid-line and the
    diagnostic output becomes unreadable. Every log line goes through GLogLock. }
  GLogLock: TCriticalSection;

// ── Logging ───────────────────────────────────────────────────────────────────

procedure Log(const AText: string);
begin
  GLogLock.Acquire;
  try
    Writeln(AText);
    Flush(Output);
  finally
    GLogLock.Release;
  end;
end;

procedure LogFmt(const AFormat: string; const AArgs: array of const);
begin
  Log(Format(AFormat, AArgs));
end;

// ── Helpers ───────────────────────────────────────────────────────────────────

{ Minimal JSON string escaping for inline Format() calls. }
function JE(const AValue: string): string;
begin
  Result := StringReplace(AValue,  '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
end;

{ Deterministic pseudo-random bytes, then Base64 — mirrors the real route,
  which Base64-encodes a stream returned by the backend. Deterministic so two
  runs are byte-for-byte comparable. }
function MakeBase64Blob(const AByteCount: Integer): string;
var
  LBytes: TBytes;
  I:      Integer;
begin
  SetLength(LBytes, AByteCount);
  for I := 0 to AByteCount - 1 do
    LBytes[I] := Byte((I * 37 + 11) and $FF);
  Result := TNetEncoding.Base64.EncodeBytesToString(LBytes);
end;

{ Dump which response body slot the bridge will actually read. This is the
  single most informative line in the whole program — see the header. }
procedure LogSlots(const ALabel: string; AResponse: THorseResponse);
{$IFDEF DIAG_SLOTS}
var
  LStreamSize: Int64;
  LUtf8Len:    Integer;
begin
  LStreamSize := -1;
  if Assigned(AResponse.ContentStream) then
    LStreamSize := AResponse.ContentStream.Size;

  LUtf8Len := 0;
  if AResponse.BodyText <> '' then
    LUtf8Len := TEncoding.UTF8.GetByteCount(AResponse.BodyText);

  LogFmt('  [SLOTS] %-14s BodyText=%d chars (%d utf8 bytes)  BodyBytes=%d  ' +
         'ContentStream=%d  CSContentType="%s"',
    [ALabel,
     Length(AResponse.BodyText),
     LUtf8Len,
     Length(AResponse.BodyBytes),
     LStreamSize,
     AResponse.CSContentType]);

  if (LStreamSize > 0) or (Length(AResponse.BodyBytes) > 0) then
    Log('  [SLOTS] *** RAW-BYTES branch will be used — no UTF-8 encoding ' +
        'step. This is the branch that can emit invalid UTF-8. ***');
end;
{$ELSE}
begin
  // BodyText/BodyBytes/ContentStream/CSContentType are the PATCH-RES-4 shadow
  // properties. If your Horse build does not expose them, comment out the
  // DIAG_SLOTS define at the top and you lose only this line.
  // Line comments here on purpose: a brace comment quoting that define would
  // close itself early and swallow the call below.
  LogFmt('  [SLOTS] %-14s (disabled: DIAG_SLOTS not defined)', [ALabel]);
end;
{$ENDIF}

{ Common request-side trace: what did the server actually receive? }
procedure LogRequest(const ARoute: string; Req: THorseRequest);
begin
  LogFmt('[REQ] %-6s %-16s  Accept-Encoding="%s"  Content-Type="%s"  body=%d bytes',
    [Req.MethodType.ToString,
     ARoute,
     Req.Headers['Accept-Encoding'],
     Req.Headers['Content-Type'],
     Length(Req.Body)]);
end;

// ── Handlers ──────────────────────────────────────────────────────────────────

procedure HandleSmall(Req: THorseRequest; Res: THorseResponse);
var
  LBody: string;
begin
  LogRequest('/probe/small', Req);
  LBody := Format('{"kind":"small","method":"%s","ok":true}',
    [JE(Req.MethodType.ToString)]);
  Res.ContentType('application/json; charset=utf-8').Send(LBody).Status(200);
  LogSlots('small', Res);
end;

procedure HandleLarge(Req: THorseRequest; Res: THorseResponse);
var
  LBody:     string;
  LBlobSize: Integer;
begin
  LogRequest('/probe/large', Req);

  LBlobSize := StrToIntDef(Req.Query['size'], DEFAULT_BLOB_SIZE);
  if LBlobSize < 0 then
    LBlobSize := 0;

  { Same shape as the real route: a JSON envelope whose 'data' member is a
    Base64 blob. Base64 is pure ASCII, so any non-UTF-8 byte the client sees
    was introduced by the transport, not by this payload. }
  LBody := Format('{"kind":"large","method":"%s","success":"true","data":"%s"}',
    [JE(Req.MethodType.ToString), MakeBase64Blob(LBlobSize)]);

  Res.ContentType('application/json; charset=utf-8').Send(LBody).Status(200);

  LogFmt('  [SIZE]  blob=%d decoded bytes -> response body=%d utf8 bytes ' +
         '(compression floor is 512)',
    [LBlobSize, TEncoding.UTF8.GetByteCount(LBody)]);
  LogSlots('large', Res);
end;

procedure HandleAccents(Req: THorseRequest; Res: THorseResponse);
var
  LBody: string;
begin
  LogRequest('/probe/accents', Req);
  { Small but heavily non-ASCII: isolates encoding from size. Every one of
    these characters is multi-byte in UTF-8, so a truncation or a codepage
    conversion anywhere in the chain corrupts it visibly. }
  LBody := '{"kind":"accents",' +
           '"message":"Error de transacción",' +
           '"literal":"petición número válido aéiou ñÑ áéíóú ¿¡",' +
           '"ok":true}';
  Res.ContentType('application/json; charset=utf-8').Send(LBody).Status(200);
  LogSlots('accents', Res);
end;

{ The FContent landmine. Res.Send(TJSONObject) hits the generic Send<T>, which
  only stores the object in FContent. Horse core never serializes FContent —
  only a JSON middleware does. Without one this should return an EMPTY body. }
procedure HandleObject(Req: THorseRequest; Res: THorseResponse);
var
  LJson: TJSONObject;
begin
  LogRequest('/probe/object', Req);
  LJson := TJSONObject.Create;
  LJson.AddPair('kind', 'object');
  LJson.AddPair('message', 'Error de transacción');
  LJson.AddPair('note', 'empty body here means no JSON middleware is registered');
  { Ownership matches the real code: Send<T> stores the object and Horse frees
    it on Clear/Destroy, so this handler must NOT free it. }
  Res.ContentType('application/json; charset=utf-8').Send(LJson).Status(200);
  LogSlots('object', Res);
end;

procedure HandleEcho(Req: THorseRequest; Res: THorseResponse);
var
  LBody: string;
begin
  LogRequest('/probe/echo', Req);
  LBody := Format(
    '{"kind":"echo","method":"%s","acceptEncoding":"%s","contentType":"%s",' +
    '"bodyChars":%d}',
    [JE(Req.MethodType.ToString),
     JE(Req.Headers['Accept-Encoding']),
     JE(Req.Headers['Content-Type']),
     Length(Req.Body)]);
  Res.ContentType('application/json; charset=utf-8').Send(LBody).Status(200);
  LogSlots('echo', Res);
end;

{ POSITIVE CONTROL — this route MUST break the client.

  Res.Send(TBytes) stores FCSBodyBytes, and the bridge sends that slot RAW:
  there is no UTF-8 encoding step on that branch, so these bytes reach the
  client exactly as written. They are deliberately not valid UTF-8, so
  ContentAsString(TEncoding.UTF8) has to raise on them.

  Why this exists: a matrix that has only ever passed proves nothing about its
  ability to detect a failure. If the client reports this route as OK, the
  harness is blind and every other PASS is worthless. }
procedure HandleBadBytes(Req: THorseRequest; Res: THorseResponse);
var
  LBytes: TBytes;
begin
  LogRequest('/probe/badbytes', Req);

  SetLength(LBytes, 8);
  LBytes[0] := Ord('{');
  LBytes[1] := Ord('"');
  LBytes[2] := $FF;      // $FF never appears in valid UTF-8
  LBytes[3] := $FE;      // nor does $FE
  LBytes[4] := $E2;      // start of a 3-byte sequence...
  LBytes[5] := $82;      // ...continuation...
  LBytes[6] := Ord('"'); // ...and truncated here: third byte never arrives
  LBytes[7] := Ord('}');

  Res.ContentType('application/json; charset=utf-8').Send(LBytes).Status(200);
  LogSlots('badbytes', Res);
end;

{ Mirrors the reported handler as closely as this reduction can: build a
  TJSONObject, Base64-encode a binary stream into it, and Send the OBJECT
  rather than a string. Send<T> takes ownership of the object (Clear frees it),
  so this handler must NOT free LJson -- only the stream it created itself. }
procedure HandleUserShape(Req: THorseRequest; Res: THorseResponse);
var
  LJson:   TJSONObject;
  LStream: TMemoryStream;
  LBytes:  TBytes;
  I:       Integer;
begin
  LogRequest('/probe/usershape', Req);

  LStream := TMemoryStream.Create;
  try
    SetLength(LBytes, 2048);
    for I := 0 to High(LBytes) do
      LBytes[I] := Byte((I * 53 + 7) and $FF);
    LStream.WriteBuffer(LBytes[0], Length(LBytes));

    // Read it back out the way the reported handler does.
    SetLength(LBytes, LStream.Size);
    LStream.Position := 0;
    LStream.Read(LBytes[0], LStream.Size);

    LJson := TJSONObject.Create;
    LJson.AddPair('success', 'true');
    LJson.AddPair('message', 'Error de transacción: número no válido');
    LJson.AddPair('data', TNetEncoding.Base64.EncodeBytesToString(LBytes));

    Res.ContentType('application/json; charset=utf-8').Send(LJson).Status(200);
  finally
    LStream.Free;
  end;

  LogSlots('usershape', Res);
end;

// ── Registration ──────────────────────────────────────────────────────────────

{ Register one handler on GET, POST and PUT. This is what separates "the
  method is the variable" from "the size is the variable" — with an identical
  handler behind all three verbs, a PUT-only failure can only be the method. }
procedure RegisterAllVerbs(const APath: string;
  const ACallback: THorseCallbackRequestResponse);
begin
  THorse.Get(APath, ACallback);
  THorse.Post(APath, ACallback);
  THorse.Put(APath, ACallback);
end;

procedure RegisterRoutes;
begin
  RegisterAllVerbs('/probe/small',   HandleSmall);
  RegisterAllVerbs('/probe/large',   HandleLarge);
  RegisterAllVerbs('/probe/accents', HandleAccents);
  RegisterAllVerbs('/probe/object',  HandleObject);
  RegisterAllVerbs('/probe/echo',    HandleEcho);
  RegisterAllVerbs('/probe/usershape', HandleUserShape);
  RegisterAllVerbs('/probe/badbytes',  HandleBadBytes);
end;

// ── Startup ───────────────────────────────────────────────────────────────────

function WantCompression: Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if SameText(ParamStr(I), '--compress') then
      Exit(True);
end;

procedure Banner(const ACompress: Boolean);
begin
  Log('===========================================================');
  Log(' Horse CrossSocket — PUT / response-encoding diagnostics');
  Log('===========================================================');
{$IFDEF HORSE_CROSSSOCKET}
  Log(' Compiled with : HORSE_CROSSSOCKET  (per this .dpr)');
{$ELSE}
  Log(' Compiled with : Indy / Console     (per this .dpr)');
{$ENDIF}
  LogFmt(' Listening on  : http://127.0.0.1:%d', [DIAG_PORT]);
{$IFDEF HORSE_CROSSSOCKET}
  LogFmt(' Compressible  : %s   MinCompressSize: 512 bytes',
    [BoolToStr(ACompress, True)]);
  if ACompress then
    Log(' NOTE: compression ON — this is the A/B control arm, not the default.');
{$ENDIF}
  Log('');
  Log(' Trust the [SLOTS] line, not the "Compiled with" line above:');
  Log('   a .dpr {$DEFINE} does not invalidate DCUs, so that line can lie.');
  Log('   Slots are sampled INSIDE the handler. A serializing middleware like');
  Log('   Jhonson writes RawWebResponse.Content in its finally block, i.e.');
  Log('   AFTER the handler returns, so with Jhonson active every slot reads');
  Log('   empty and the body still arrives -- via the bridge''s string branch.');
  Log('   All slots empty AND a zero-byte body = nothing serialized the object.');
  Log('-----------------------------------------------------------');
  Log('');
end;

{$IFDEF HORSE_CROSSSOCKET}
procedure RunCrossSocket(const ACompress: Boolean);
var
  LConfig: THorseCrossSocketConfig;
begin
  LConfig := THorseCrossSocketConfig.Default;
  LConfig.Compressible    := ACompress;
  LConfig.MinCompressSize := 512;
  { ListenWithConfig blocks the calling thread until StopListen. }
  THorseProviderCrossSocket.ListenWithConfig(DIAG_PORT, LConfig);
end;
{$ENDIF}

var
  GCompress: Boolean;

begin
  GLogLock := TCriticalSection.Create;
  try
    try
      GCompress := WantCompression;
{$IFDEF USE_JHONSON}
      { Jhonson does two things that matter here, and they are on opposite
        sides of the request:
          RESPONSE: in its finally block it serializes Res.Content (a
            TJSONValue) into Res.RawWebResponse.Content -- a STRING, which the
            bridge sends via TEncoding.UTF8. That is the last slot WriteBody
            checks, so anything written to an earlier slot wins over it.
          REQUEST:  on POST/PUT/PATCH with Content-Type application/json it
            parses the body and calls Req.Body(LJSON), rebinding FBody. GET is
            excluded by that method filter -- the one verb reported working. }
      Log('[INIT] Jhonson middleware ACTIVE');
      THorse.Use(Jhonson);
{$ELSE}
      Log('[INIT] Jhonson middleware NOT linked (empty-body baseline)');
{$ENDIF}
      RegisterRoutes;
      Banner(GCompress);
{$IFDEF HORSE_CROSSSOCKET}
      RunCrossSocket(GCompress);
{$ELSE}
      { Indy control arm — no config record, no compression, by construction. }
      THorse.Listen(DIAG_PORT);
{$ENDIF}
    except
      on E: Exception do
        LogFmt('[FATAL] %s: %s', [E.ClassName, E.Message]);
    end;
  finally
    GLogLock.Free;
  end;
end.
