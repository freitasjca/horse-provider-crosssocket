unit Horse.CrossSocket.TestRoutes;

(*
  Horse + CrossSocket — Shared Integration Test Routes
  ====================================================

  This unit registers every route of the console test server
  (HorseCSTestServer.dpr), which the integration test client
  (HorseCSTestClient.dpr) exercises. It's the test surface for every
  per-shape server project under Delphi/ and Lazarus/ in this samples/tests
  tree. When a route is added to HorseCSTestServer.dpr, add it here too:
  until ROUTES-SYNC-1 (v1.0.30) the /stream, /body, /params/decode and /diag
  routes existed only in the console server, so the full client got 404s for
  them against every other shape.

  The stream producers and the /diag/raise request hook are plain unit-scope
  procedures, not anonymous ones: that is the form FPC accepts for Horse
  callbacks without HORSE_FPC_FUNCTIONREFERENCES. The /diag routes need the
  CrossSocket worker pool, so they answer 501 (the client skips them loudly)
  when neither HORSE_PROVIDER_CROSSSOCKET nor HORSE_CROSSSOCKET is a
  project-level define.

  Dual-compiler: compiles on both Delphi (Web.HTTPApp.TWebRequest /
  TWebResponse) and FPC (HTTPDefs.TRequest / TResponse) via type aliases.
  Anonymous procedures require FPC >= 3.2 in {$MODE DELPHI}.

  Usage from a per-shape server:

      uses Horse, Horse.CrossSocket.TestRoutes;
      begin
        RegisterTestRoutes;
        THorse.Listen(TEST_PORT);
      end.

  Or, for shapes whose lifecycle is wrapped (TfrmHorseVCLHost,
  THorseCrossSocketDaemonApp, etc.), call RegisterTestRoutes from the
  appropriate lifecycle hook (FormCreate / OnHorseListen / Run setup proc).
*)

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

interface

const
  TEST_PORT           = 9010;
  LARGE_RESPONSE_SIZE = 65536;     // bytes — must match client constant
  DIAG_RAISE_MARKER   = 'DIAG-RAISE-DELIBERATE'; // must match client constant

procedure RegisterTestRoutes;

implementation

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
{$IF DEFINED(HORSE_PROVIDER_CROSSSOCKET) or DEFINED(HORSE_CROSSSOCKET)}
  Horse.Provider.CrossSocket.WorkerPool,
{$ENDIF}
  Horse,
  Horse.Commons,
  Horse.Response,   // IHorseStreamWriter
  Horse.Core.Param,
  Horse.Core.Param.Field;

type
  { Type aliases so the route bodies stay readable on both compilers. }
  TRawWebReq = {$IF DEFINED(FPC)}TRequest{$ELSE}TWebRequest{$ENDIF};
  TRawWebRes = {$IF DEFINED(FPC)}TResponse{$ELSE}TWebResponse{$ENDIF};

{ ── JSON helpers ──────────────────────────────────────────────────────────── }

{ Minimal JSON string escaping for inline Format() calls. }
function JE(const S: string): string;
begin
  Result := StringReplace(S,     '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
end;

{ JSON boolean literal — returned unquoted for inline Format() calls. }
function JB(const B: Boolean): string;
begin
  if B then Result := 'true' else Result := 'false';
end;

{ [FIX-DECODE-ONCE-1] Read field "v" three ways and report each as JSON.
  Field is read FIRST: it reads the dictionary directly, so it always shows
  the value exactly as stored. The two indexed reads that follow show what
  THorseCoreParam does to it, and the second one sees whatever the first
  wrote back. Each read catches its own exception, so one failing accessor
  cannot hide what the others return. }
function DecodeReport(const AParam: THorseCoreParam): string;
var
  LField: string;
  LGet:   string;
  LAgain: string;
begin
  try
    LField := AParam.Field('v').AsString;
  except
    on E: Exception do
      LField := 'EXCEPTION ' + E.ClassName + ': ' + E.Message;
  end;
  try
    LGet := AParam['v'];
  except
    on E: Exception do
      LGet := 'EXCEPTION ' + E.ClassName + ': ' + E.Message;
  end;
  try
    LAgain := AParam['v'];
  except
    on E: Exception do
      LAgain := 'EXCEPTION ' + E.ClassName + ': ' + E.Message;
  end;
  Result := '{"field":"' + JE(LField) + '","get":"' + JE(LGet)
    + '","again":"' + JE(LAgain) + '"}';
end;

{ ── Stream producers (PATCH-STREAM-1 / STREAM-WRITER-1) ───────────────────── }

{ Five chunks ~120 ms apart, so incremental arrival is observable. }
procedure StreamPullProducer(const AWriter: IHorseStreamWriter);
var
  LCount: Integer;
begin
  for LCount := 0 to 4 do
  begin
    if not AWriter.IsConnected then Break;
    Sleep(120);
    AWriter.Write(Format('chunk-%d;', [LCount]));
  end;
end;

{ Three fast chunks; the route sets application/octet-stream. }
procedure StreamContentTypeProducer(const AWriter: IHorseStreamWriter);
var
  LCount: Integer;
begin
  for LCount := 0 to 2 do
  begin
    if not AWriter.IsConnected then Break;
    AWriter.Write(Format('ct-chunk-%d;', [LCount]));
  end;
end;

{ No writes: Close still commits a complete, empty 200 response. }
procedure StreamEmptyProducer(const AWriter: IHorseStreamWriter);
begin
end;

{$IF DEFINED(HORSE_PROVIDER_CROSSSOCKET) or DEFINED(HORSE_CROSSSOCKET)}
{ [FIX-WP-ERRCOUNT] /diag/raise must raise from an onRequest hook, not a
  route handler: Horse's TNextCaller catches a route's exception and answers
  "Internal Application Error" without re-raising, so it never reaches the
  provider's catch that counts it. Hooks run in THorseLifecycleExecutor.Next,
  which has no try/except. Side effect: with a hook registered, every request
  goes through THorseLifecycleExecutor. }
procedure DiagRaiseHook(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  if SameText(AReq.PathInfo, '/diag/raise') then
    raise Exception.Create(DIAG_RAISE_MARKER);
  ANext();
end;
{$ENDIF}

{ ── Route registration ───────────────────────────────────────────────────── }

procedure RegisterTestRoutes;
begin

  // ── Health ────────────────────────────────────────────────────────────────
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain').Send('pong');
    end
  );

  // ── HTTP method probes ────────────────────────────────────────────────────

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

  // ── Path & query params ───────────────────────────────────────────────────

  THorse.Get('/params/path/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"id":"%s"}', [JE(Req.Params['id'])]));
    end
  );

  THorse.Get('/params/query',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"name":"%s","value":"%s"}',
           [JE(Req.Query['name']), JE(Req.Query['value'])]));
    end
  );

  THorse.Get('/params/multi/:a/:b',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"a":"%s","b":"%s"}',
           [JE(Req.Params['a']), JE(Req.Params['b'])]));
    end
  );

  // ── Cookies ───────────────────────────────────────────────────────────────

  THorse.Get('/cookies/set',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.AddHeader('Set-Cookie', 'session=abc123; Path=/');
      Res.AddHeader('Set-Cookie', 'user=tester; Path=/');
      Res.ContentType('application/json; charset=utf-8')
         .Send('{"status":"cookies set"}');
    end
  );

  THorse.Get('/cookies/echo',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"session":"%s","user":"%s"}',
           [JE(Req.Cookie['session']), JE(Req.Cookie['user'])]));
    end
  );

  // ── File upload (multipart/form-data) ─────────────────────────────────────
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

  // ── File download ─────────────────────────────────────────────────────────
  THorse.Get('/download',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain; charset=utf-8')
         .AddHeader('Content-Disposition', 'attachment; filename="testfile.txt"')
         .Send('Hello from Horse CrossSocket test download!');
    end
  );

  // ── Custom header echo ────────────────────────────────────────────────────
  THorse.Get('/headers/echo',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"X-Test-Header":"%s"}',
           [JE(Req.Headers['X-Test-Header'])]));
    end
  );

  // ── Body echo (used by pool isolation tests + large body) ────────────────
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

  // ── Explicit status code ──────────────────────────────────────────────────
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

  // ── Large response ────────────────────────────────────────────────────────
  THorse.Get('/response/large',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain; charset=utf-8')
         .Send(StringOfChar('X', LARGE_RESPONSE_SIZE));
    end
  );

  // ── RawWebRequest adapter probe  (PATCH-REQ-8) ────────────────────────────
  THorse.Get('/raw/webrequest',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LRaw: TRawWebReq;
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

  // ── Horse.CORS-style route  (PATCH-REQ-8 regression) ──────────────────────
  THorse.All('/raw/cors',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LRaw: TRawWebReq;
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

  // ── RawWebResponse adapter probe  (PATCH-RES-6) ──────────────────────────
  THorse.Get('/raw/webresponse',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LRaw: TRawWebRes;
    begin
      LRaw := Res.RawWebResponse;
      if not Assigned(LRaw) then
      begin
        Res.ContentType('application/json; charset=utf-8').Status(500)
           .Send('{"hasAdapter":false,"error":"RawWebResponse is nil"}');
        Exit;
      end;
      LRaw.SetCustomHeader('X-Via-RawResponse', 'PATCH-RES-6-OK');
      Res.AddHeader('X-Via-AddHeader', 'AddHeader-OK');
      Res.ContentType('application/json; charset=utf-8')
         .Send('{"hasAdapter":true}');
    end
  );

  // ── PATCH-REQ-9: double-read idempotency ─────────────────────────────────
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

  // ── COMPAT-1: shadow-field precedence over RawWebResponse.Content ───────
  THorse.Get('/compat/rawbody',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LRaw: TRawWebRes;
    begin
      LRaw := Res.RawWebResponse;
      if Assigned(LRaw) then
        LRaw.Content := 'raw-should-not-appear';
      Res.ContentType('text/plain; charset=utf-8').Send('shadow-wins');
    end
  );

  // ── PATCH-STREAM-1: chunked streaming through Res.SendStream ─────────────
  THorse.Get('/stream/pull',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain; charset=utf-8');
      Res.SendStream(StreamPullProducer);
    end
  );

  // Content-Type set before SendStream must reach the wire.
  THorse.Get('/stream/content-type',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/octet-stream');
      Res.SendStream(StreamContentTypeProducer);
    end
  );

  // Zero chunks: 200 + empty body, no hang; the pool context is recycled.
  THorse.Get('/stream/empty',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain');
      Res.SendStream(StreamEmptyProducer);
    end
  );

  // ── Worker pool burst endpoint ────────────────────────────────────────────
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

  // ── FIX-BODYBYTES-1: Res.Send(TBytes) must reach the client ─────────────
  // The response bridge never read the TBytes slot, so this answered 200
  // with Content-Length: 0. ASCII payload so the client can compare strings.
  THorse.Get('/body/bytes',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/octet-stream');
      Res.Send(TEncoding.UTF8.GetBytes('BODYBYTES-OK-0123456789'));
    end
  );

  // ── FIX-BINBODY-1: a binary request body must not abort the request ──────
  // Bytes 0..255 are not valid UTF-8. Both text accessors (Req.Body and
  // RawWebRequest.Content) used to raise EEncodingError inside the bridge;
  // they run FIRST here, and Body<TStream> must still read all 256 bytes
  // from position 0 afterwards. The client asserts size 256 and sum 32640;
  // textLen/rawLen are reported for diagnosis only.
  THorse.Post('/body/binary',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LText:   string;
      LRaw:    string;
      LRawReq: TRawWebReq;
      LStream: TStream;
      LBytes:  TBytes;
      I:       Integer;
      LSum:    Integer;
      LSize:   Integer;
    begin
      LText := Req.Body;                    // site 1 — must not raise

      // RawWebRequest is a property getter: capture it, then test <> nil
      // (Assigned() on a getter is E2036).
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

  // ── FIX-DECODE-ONCE-1: query / form values are URL-decoded exactly once ──
  // The bridge stores values CrossSocket already decoded; a second decode
  // raised EConvertError on values such as 100%25 or 50%25off.
  THorse.Get('/params/decode',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(DecodeReport(Req.Query));
    end
  );

  THorse.Put('/params/decode-form',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(DecodeReport(Req.ContentFields));
    end
  );

  // ── FIX-WP-ERRCOUNT: server-side failure counter ────────────────────────
{$IF DEFINED(HORSE_PROVIDER_CROSSSOCKET) or DEFINED(HORSE_CROSSSOCKET)}
  THorse.AddOnRequest(DiagRaiseHook);

  // Reached only if the hook did NOT fire: 200 makes that explicit in the
  // client instead of a confusing 404.
  THorse.Get('/diag/raise',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send('{"raised":false,"error":"onRequest hook did not fire"}');
    end
  );

  // Cumulative since server start; the client asserts the delta.
  THorse.Get('/diag/failed-tasks',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"failedTasks":%d}',
           [THorseWorkerPool.Instance.FailedTasks]));
    end
  );
{$ELSE}
  // No CrossSocket define reached this unit, so no worker pool: 501 tells
  // the client to SKIP the counter tests loudly rather than fail.
  THorse.Get('/diag/failed-tasks',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Status(501)
         .Send('{"error":"no worker pool on this build"}');
    end
  );
{$ENDIF}

  // ── PROVIDER-PROBE-1: which transport is this build really using? ──────────
  // THorse descends from the THorseProvider alias that Horse.pas picks from the
  // PROJECT-level defines. A shape whose .dproj sets no provider define builds
  // on Horse's default (Indy on Delphi) even though every CrossSocket unit is
  // compiled in, and nothing else in the response reveals it. Manual check:
  //   curl http://127.0.0.1:9010/diag/provider
  THorse.Get('/diag/provider',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"provider":"%s","crossSocketDefine":%s}',
           [JE(THorse.ClassParent.ClassName),
            JB({$IF DEFINED(HORSE_PROVIDER_CROSSSOCKET) or DEFINED(HORSE_CROSSSOCKET)}True{$ELSE}False{$ENDIF})]));
    end
  );

end;

end.
