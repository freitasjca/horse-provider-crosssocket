program HorseCSTestServer;

{$APPTYPE CONSOLE}

{
  Horse + CrossSocket  —  Integration Test Server
  ================================================
  Destination: horse-provider-crosssocket/samples/tests/HorseCSTestServer.dpr

  Transport selection (compile-time):
    {$DEFINE HORSE_CROSSSOCKET   →  CrossSocket (IOCP/epoll) transport
    (absent)                     →  Indy / Console (default Horse) transport

  Run this program first, then run HorseCSTestClient.

  Routes exercised by the client test suite:
    GET    /ping                        health check
    GET    /methods/get                 GET method probe
    POST   /methods/post                POST body echo
    PUT    /methods/put/:id             PUT with path param
    DELETE /methods/delete/:id          DELETE with path param
    PATCH  /methods/patch/:id           PATCH with path param
    HEAD   /methods/head                HEAD — header only, no body
    GET    /params/path/:id             single path param echo
    GET    /params/query                query param echo  (?name=X&value=Y)
    GET    /params/multi/:a/:b          two path params in one route
    GET    /cookies/set                 sets session + user cookies
    GET    /cookies/echo                echoes Cookie values back as JSON
    POST   /upload                      multipart: 'file' stream + 'fieldname' text
    GET    /download                    text/plain with Content-Disposition header
    GET    /headers/echo                echoes X-Test-Header back
    POST   /echo/body                   echoes body text + size (pool isolation tests)
    GET    /status/:code                responds with the HTTP status from the path param
    GET    /response/large              sends a fixed 65536-byte body (buffer tests)
    GET    /raw/webrequest              echoes Req.RawWebRequest.* properties as JSON  (PATCH-REQ-8)
    ALL    /raw/cors                    Horse.CORS-style: OPTIONS → 204 preflight, else 200
    GET    /raw/webresponse             sets header via Res.RawWebResponse.SetCustomHeader  (PATCH-RES-6)
    POST   /echo/body-twice             calls Req.Body twice — verifies FBodyString cache (PATCH-REQ-9)
    GET    /compat/rawbody              writes RawWebResponse.Content then Res.Send — shadow wins (COMPAT-1)
    POST   /pool/burst                  body echo under load — worker pool cascade wake test
    GET    /stream/pull                 chunked streaming via Res.SendChunked — pull model (PATCH-STREAM-1)
    GET    /stream/content-type         SendChunked Content-Type propagation probe (PATCH-STREAM-1)
    GET    /stream/empty                zero-chunk producer edge case — 200 + empty body (PATCH-STREAM-1)
}

uses
  System.SysUtils,
  System.Classes,
  Web.HTTPApp,
  Horse,
  Horse.Commons,
  Horse.Response,
{$IFDEF HORSE_CROSSSOCKET}
  Horse.Provider.CrossSocket,
  Horse.Provider.CrossSocket.WorkerPool,
{$ENDIF}
  Horse.Core.Param,
  Horse.Core.Param.Field;

const
  TEST_PORT           = 9010;
  LARGE_RESPONSE_SIZE = 65536; // bytes, must match client constant

// ── Helpers ───────────────────────────────────────────────────────────────────

{ Minimal JSON string escaping for inline Format() calls. }
function JE(const S: string): string;
begin
  Result := StringReplace(S,  '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
end;

{ JSON boolean literal — returned unquoted for inline Format() calls. }
function JB(const B: Boolean): string;
begin
  if B then Result := 'true' else Result := 'false';
end;

// ── Route registration ────────────────────────────────────────────────────────

procedure RegisterRoutes;
begin

  // ── Health ────────────────────────────────────────────────────────────────────
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain').Send('pong');
    end
  );

  // ── HTTP method probes ────────────────────────────────────────────────────────

  THorse.Get('/methods/get',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send('{"method":"GET"}');
    end
  );

  THorse.Post('/methods/post',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"POST","body":"%s"}', [JE(Req.Body)]));
    end
  );

  THorse.Put('/methods/put/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"PUT","id":"%s"}', [JE(Req.Params['id'])]));
    end
  );

  THorse.Delete('/methods/delete/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"DELETE","id":"%s"}', [JE(Req.Params['id'])]));
    end
  );

  THorse.Patch('/methods/patch/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"PATCH","id":"%s"}', [JE(Req.Params['id'])]));
    end
  );

  // HEAD: respond with a custom header and no body — correct behaviour for HEAD.
  THorse.Head('/methods/head',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.AddHeader('X-Head-Ok', 'true');
      // Deliberately no Res.Send — HEAD must not include a message body.
    end
  );

  // ── Path & query params ───────────────────────────────────────────────────────

  THorse.Get('/params/path/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"id":"%s"}', [JE(Req.Params['id'])]));
    end
  );

  // ?name=X&value=Y  → {"name":"X","value":"Y"}
  THorse.Get('/params/query',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"name":"%s","value":"%s"}',
           [JE(Req.Query['name']), JE(Req.Query['value'])]));
    end
  );

  // Two path params in a single route — exercises router tree multi-segment matching.
  THorse.Get('/params/multi/:a/:b',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"a":"%s","b":"%s"}',
           [JE(Req.Params['a']), JE(Req.Params['b'])]));
    end
  );

  // ── Cookies ───────────────────────────────────────────────────────────────────

  // Sets two cookies in Set-Cookie headers.
  THorse.Get('/cookies/set',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.AddHeader('Set-Cookie', 'session=abc123; Path=/');
      Res.AddHeader('Set-Cookie', 'user=tester; Path=/');
      Res.ContentType('application/json; charset=utf-8')
         .Send('{"status":"cookies set"}');
    end
  );

  // Reads the Cookie header the client sends and echoes both values.
  THorse.Get('/cookies/echo',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"session":"%s","user":"%s"}',
           [JE(Req.Cookie['session']), JE(Req.Cookie['user'])]));
    end
  );

  // ── File upload (multipart/form-data) ─────────────────────────────────────────
  //
  // Expected multipart fields:
  //   file       — file stream (required)
  //   fieldname  — plain text field carrying the original filename
  //
  // Response: {"received":true,"name":"<fieldname>","size":<bytes>}
  //        or {"received":false,"error":"no file field"}  on bad request
  //
  THorse.Post('/upload',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LStream: TStream;
      LName:   string;
    begin
      LStream := Req.ContentFields.Field('file').AsStream;
      LName   := Req.ContentFields['fieldname'];
      if Assigned(LStream) then
        Res.ContentType('application/json; charset=utf-8')
           .Send(Format('{"received":true,"name":"%s","size":%d}',
             [JE(LName), LStream.Size]))
      else
        Res.Status(THTTPStatus.BadRequest)
           .ContentType('application/json; charset=utf-8')
           .Send('{"received":false,"error":"no file field"}');
    end
  );

  // ── File download ─────────────────────────────────────────────────────────────
  // Returns a fixed text body with Content-Disposition: attachment.
  // Client verifies both the header and the body content.
  THorse.Get('/download',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain; charset=utf-8')
         .AddHeader('Content-Disposition', 'attachment; filename="testfile.txt"')
         .Send('Hello from Horse CrossSocket test download!');
    end
  );

  // ── Custom header echo ────────────────────────────────────────────────────────
  THorse.Get('/headers/echo',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"X-Test-Header":"%s"}',
           [JE(Req.Headers['X-Test-Header'])]));
    end
  );

  // ── Body echo ─────────────────────────────────────────────────────────────────
  // Echoes back the raw request body and its byte length.
  // Used by: pool isolation tests, large-body test, empty-body test.
  // Response: {"body":"<text>","size":<n>}
  THorse.Post('/echo/body',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: string;
    begin
      LBody := Req.Body;
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"body":"%s","size":%d}',
           [JE(LBody), Length(TEncoding.UTF8.GetBytes(LBody))]));
    end
  );

  // ── Explicit status code ──────────────────────────────────────────────────────
  // Responds with the HTTP status code extracted from the path parameter.
  // Used to verify that non-200 codes flow through the pipeline correctly.
  // GET /status/400 → 400 Bad Request  {"status":400}
  // GET /status/500 → 500 Internal Server Error  {"status":500}
  THorse.Get('/status/:code',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LCode: Integer;
    begin
      LCode := StrToIntDef(Req.Params['code'], 200);
      if (LCode < 100) or (LCode > 599) then
        LCode := 400;
      Res.ContentType('application/json; charset=utf-8')
         .Status(LCode)
         .Send(Format('{"status":%d}', [LCode]));
    end
  );

  // ── Large response ────────────────────────────────────────────────────────────
  // Returns a body of exactly LARGE_RESPONSE_SIZE bytes.
  // Used to verify that large response payloads are transmitted without
  // truncation or corruption (CrossSocket async write-completion chain).
  THorse.Get('/response/large',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain; charset=utf-8')
         .Send(StringOfChar('X', LARGE_RESPONSE_SIZE));
    end
  );

  // ── RawWebRequest adapter probe  (PATCH-REQ-8) ────────────────────────────────
  // Exercises the TWebRequest/TRequest adapter so middleware that reaches through
  // `Req.RawWebRequest.*` (e.g. Horse.CORS) keeps working on CrossSocket.
  // On Indy the adapter is not used — FWebRequest is returned directly.
  // On CrossSocket the hybrid adapter exposes Method/Host/PathInfo/GetFieldByName
  // backed by ICrossHttpRequest.
  THorse.Get('/raw/webrequest',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LRaw: TWebRequest;
    begin
      LRaw := Req.RawWebRequest;
      if not Assigned(LRaw) then
      begin
        Res.ContentType('application/json; charset=utf-8').Status(500)
           .Send('{"hasAdapter":false,"error":"RawWebRequest is nil"}');
        Exit;
      end;
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format(
           '{"hasAdapter":true,"method":"%s","host":"%s","pathInfo":"%s",'
         + '"customHeader":"%s","remoteAddrNonEmpty":%s}',
           [JE(LRaw.Method),
            JE(LRaw.Host),
            JE(LRaw.PathInfo),
            JE(LRaw.GetFieldByName('X-Test-Header')),
            JB(LRaw.RemoteAddr <> '')]));
    end
  );

  // ── Horse.CORS-style route  (PATCH-REQ-8 regression) ──────────────────────────
  // Emulates the Horse.CORS middleware pattern:
  //   if Req.RawWebRequest.Method = 'OPTIONS' then reply 204 + CORS header,
  //   otherwise continue and echo the method.
  // Registered with `All` so the route matches every TMethodType including
  // mtAny (which is how OPTIONS is represented on both Indy and CrossSocket).
  THorse.All('/raw/cors',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LRaw: TWebRequest;
      LMethod: string;
    begin
      LRaw := Req.RawWebRequest;
      if not Assigned(LRaw) then
      begin
        Res.ContentType('text/plain').Status(500)
           .Send('raw-cors:nil-adapter');
        Exit;
      end;
      LMethod := LRaw.Method;
      if SameText(LMethod, 'OPTIONS') then
      begin
        Res.AddHeader('Access-Control-Allow-Origin', '*');
        Res.AddHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
        Res.ContentType('text/plain').Status(THTTPStatus.NoContent).Send('');
        Exit;
      end;
      Res.ContentType('text/plain').Send('cors-route:' + LMethod);
    end
  );

  // ── RawWebResponse adapter probe  (PATCH-RES-6) ─────────────────────────────
  // Exercises Res.RawWebResponse.SetCustomHeader — the exact call Horse.CORS
  // makes to inject Access-Control-* headers.  Before PATCH-RES-6 this AV'd on
  // CrossSocket because Res.RawWebResponse was nil (FWebResponse is never
  // assigned; FCSRawWebResponse was not wired).
  // Also sets a header via Res.AddHeader for comparison — both must appear.
  THorse.Get('/raw/webresponse',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LRaw: TWebResponse;
    begin
      LRaw := Res.RawWebResponse;
      if not Assigned(LRaw) then
      begin
        Res.ContentType('application/json; charset=utf-8').Status(500)
           .Send('{"hasAdapter":false,"error":"RawWebResponse is nil"}');
        Exit;
      end;
      // This is the exact pattern Horse.CORS uses:
      LRaw.SetCustomHeader('X-Via-RawResponse', 'PATCH-RES-6-OK');
      // Also set via Horse's own AddHeader for comparison
      Res.AddHeader('X-Via-AddHeader', 'AddHeader-OK');
      Res.ContentType('application/json; charset=utf-8')
         .Send('{"hasAdapter":true}');
    end
  );

  // ── PATCH-REQ-9: double-read idempotency ─────────────────────────────────────
  // Calls Req.Body twice and echoes both results.  Before PATCH-REQ-9, the
  // second call re-read an exhausted TMemoryStream and returned an empty string.
  // After PATCH-REQ-9, MapBody decodes to FBodyString once; both calls return
  // the same cached value.
  THorse.Post('/echo/body-twice',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LFirst:  string;
      LSecond: string;
    begin
      LFirst  := Req.Body;
      LSecond := Req.Body;
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"first":"%s","second":"%s","equal":%s}',
           [JE(LFirst), JE(LSecond), JB(LFirst = LSecond)]));
    end
  );

  // ── COMPAT-1: RawWebResponse.Content does not corrupt shadow-field body ───────
  // Writes to Res.RawWebResponse.Content (which is a stub on CrossSocket — the
  // value is intentionally not forwarded through TInterfacedWebResponse).
  // Then calls Res.Send via the Horse API (shadow field).
  // Verifies:
  //   (a) The shadow field wins — 'shadow-wins' body is returned.
  //   (b) The COMPAT-1 fallback does not fire spuriously (GetContent returns '').
  //   (c) No crash when RawWebResponse.Content is set before the shadow field.
  THorse.Get('/compat/rawbody',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LRaw: TWebResponse;
    begin
      LRaw := Res.RawWebResponse;
      // Simulate Indy-era middleware writing via the raw adapter (stub on CrossSocket)
      if Assigned(LRaw) then
        LRaw.Content := 'raw-should-not-appear';
      // The Horse shadow-field API must take precedence
      Res.ContentType('text/plain; charset=utf-8')
         .Send('shadow-wins');
    end
  );

  // ── PATCH-STREAM-1: pull-model chunked streaming ──────────────────────────────
  // Res.SendChunked returns immediately; CrossSocket IO threads pump the
  // producer (5 chunks, ~120 ms apart) and the provider defers pool release
  // until the stream drains ([STREAM-2]).
  // On the Indy transport (no HORSE_CROSSSOCKET) this route responds 501 —
  // "streaming not supported" — which is the intended negative behaviour.
  // Manual incremental check:  curl -N http://127.0.0.1:9010/stream/pull
  THorse.Get('/stream/pull',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      // [STREAM-WRITER-1] Phase 2: retargeted from the retired pull SendChunked to
      // upstream's push Res.SendStream. The callback runs synchronously; the writer
      // frames chunks and blocks each SendBytes until drained.
      Res.ContentType('text/plain; charset=utf-8');
      Res.SendStream(
        procedure(const AWriter: IHorseStreamWriter)
        var
          LCount: Integer;
        begin
          for LCount := 0 to 4 do
          begin
            if not AWriter.IsConnected then Break;
            Sleep(120); // spacing so incremental arrival is observable
            AWriter.Write(Format('chunk-%d;', [LCount]));
          end;
        end);
    end
  );

  // ── PATCH-STREAM-1 extras: Content-Type propagation ──────────────────────────────
  // Streams 3 fast chunks with 'application/octet-stream' content type so the
  // client can verify that the content-type passed to SendChunked reaches the
  // wire Content-Type response header.  No Sleep — chunks are emitted without
  // delay to keep the test fast.
  THorse.Get('/stream/content-type',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/octet-stream');
      Res.SendStream(
        procedure(const AWriter: IHorseStreamWriter)
        var
          LCount: Integer;
        begin
          for LCount := 0 to 2 do
          begin
            if not AWriter.IsConnected then Break;
            AWriter.Write(Format('ct-chunk-%d;', [LCount]));
          end;
        end);
    end
  );

  // ── PATCH-STREAM-1 extras: zero-chunk producer (edge case) ────────────────────
  // The producer returns False on the very first call — no data bytes emitted.
  // CrossSocket must complete with 200 + empty body without hanging or crashing;
  // the deferred pool release ([STREAM-2]) must still fire so the context is
  // recycled (validated by the /ping health check in the client).
  THorse.Get('/stream/empty',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain');
      Res.SendStream(
        procedure(const AWriter: IHorseStreamWriter)
        begin
          // no writes — upstream's Close still commits a complete (empty) response
        end);
    end
  );

  // ── Worker pool burst endpoint ────────────────────────────────────────────────
  // Same as /echo/body but registered at a separate path so burst tests don't
  // interfere with sequential body isolation tests (17).
  THorse.Post('/pool/burst',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LBody: string;
    begin
      LBody := Req.Body;
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"body":"%s","size":%d}',
           [JE(LBody), Length(TEncoding.UTF8.GetBytes(LBody))]));
    end
  );

  // ── FIX-BODYBYTES-1: Res.Send(TBytes) must actually reach the client ────────
  // Horse core's Send(TBytes) writes the shadow slot FCSBodyBytes (public
  // property BodyBytes). TResponseBridge.WriteBody never read it, so this
  // returned 200 with Content-Length: 0 — no exception, no log, nothing to
  // notice. The response simply arrived empty.
  //
  // The payload is ASCII on purpose: the failure being tested is "the slot is
  // never read", so an exact string compare is the clearest assertion, and
  // binary bytes would be mangled by the test client's string-typed body.
  // Byte fidelity through this path is already covered by the stream tests.
  THorse.Get('/body/bytes',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/octet-stream');
      Res.Send(TEncoding.UTF8.GetBytes('BODYBYTES-OK-0123456789'));
    end
  );

  // ── FIX-BINBODY-1: a binary request body must not abort the request ──────────
  // A body of arbitrary bytes (0..255) is deliberately NOT valid UTF-8.  Before
  // FIX-BINBODY-1 both text accessors decoded the raw body eagerly with
  // TEncoding.UTF8.GetString, which raises EEncodingError ('No mapping for the
  // Unicode character exists in the target multi-byte code page') when a
  // non-empty input decodes to zero chars.  That fired inside the request
  // bridge, so the request died with a 500 before this handler ever ran — the
  // tell was the complete absence of handler-side logging.
  //
  // Two independent call sites had to be guarded; guarding only the first left
  // the failure fully intact, so this route exercises BOTH:
  //   Req.Body                  → Request.pas     MapBody, btBinary branch
  //   Req.RawWebRequest.Content → RawRequest.pas  GetContent
  //
  // Read order matters. The two text accessors run FIRST, and Body<TStream> has
  // to survive what they did to the stream: GetContent used to read the shared
  // non-owning stream to EOF without rewinding, so a handler that touched
  // Content first then saw Size bytes but read zero of them.  "sum" is what
  // actually catches that — a truncated or re-read body cannot reproduce it.
  //
  // Asserted by the client: status 200, size 256, sum 32640 (= 0+1+…+255).
  // textLen/rawLen are reported for diagnosis but deliberately NOT asserted:
  // the degradation to '' is correct-but-incidental, and FPC decodes via a
  // different path (MapBody's decode is Delphi-only), so pinning them would
  // make this test compiler-specific for no added coverage.
  THorse.Post('/body/binary',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LText:   string;
      LRaw:    string;
      LRawReq: TWebRequest;
      LStream: TStream;
      LBytes:  TBytes;
      I:       Integer;
      LSum:    Integer;
      LSize:   Integer;
    begin
      LText := Req.Body;                    // site 1 — must not raise

      // RawWebRequest is a property GETTER, i.e. an rvalue, and Assigned()
      // demands a variable — passing it directly is E2036 "Variable required".
      // Capture it first, then test with <> nil. Same pattern as the
      // /raw/webrequest route above.
      LRawReq := Req.RawWebRequest;
      if LRawReq <> nil then
        LRaw := LRawReq.Content             // site 2 — must not raise
      else
        LRaw := '';

      LSum  := 0;
      LSize := 0;
      LStream := Req.Body<TStream>;         // must still be readable from 0
      if Assigned(LStream) then
      begin
        LSize := LStream.Size;
        LStream.Position := 0;              // never free this — non-owning
        SetLength(LBytes, LSize);
        if LSize > 0 then
          LStream.Read(LBytes[0], LSize);
        for I := 0 to LSize - 1 do
          Inc(LSum, LBytes[I]);
      end;

      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"size":%d,"sum":%d,"textLen":%d,"rawLen":%d}',
           [LSize, LSum, Length(LText), Length(LRaw)]));
    end
  );

end;

// ── Entry point ───────────────────────────────────────────────────────────────

begin
  try
    RegisterRoutes;
{$IFDEF HORSE_CROSSSOCKET}
    THorseProviderCrossSocket.Listen(TEST_PORT);
    Writeln(Format('[HorseCSTest] Server listening on http://127.0.0.1:%d  [CrossSocket]',
      [TEST_PORT]));
{$ELSE}
    THorse.Listen(TEST_PORT);
    Writeln(Format('[HorseCSTest] Server listening on http://127.0.0.1:%d  [Indy/Console]',
      [TEST_PORT]));
{$ENDIF}
    Writeln('[HorseCSTest] Run HorseCSTestClient to execute the test suite.');
    Writeln('[HorseCSTest] Press ENTER to stop...');
    Readln;
{$IFDEF HORSE_CROSSSOCKET}
    THorseProviderCrossSocket.Stop;
{$ELSE}
    THorse.StopListen;
{$ENDIF}
    Writeln('[HorseCSTest] Server stopped.');
  except
    on E: Exception do
    begin
      Writeln('[HorseCSTest] Fatal: ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
