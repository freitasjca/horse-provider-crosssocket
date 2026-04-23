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
}

uses
  System.SysUtils,
  System.Classes,
  Web.HTTPApp,
  Horse,
  Horse.Commons,
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
  // GET /status/400 → 400 Bad Request (empty body)
  // GET /status/500 → 500 Internal Server Error (empty body)
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
