program HorseCSTestServer;

{$APPTYPE CONSOLE}
{$DEFINE HORSE_CROSSSOCKET}

{
  Horse + CrossSocket  —  Integration Test Server
  ================================================
  Destination: horse-provider-crosssocket/samples/tests/HorseCSTestServer.dpr

  Run this program first, then run HorseCSTestClient.

  Routes exercised by the client test suite:
    GET    /ping                      health check
    GET    /methods/get               GET method probe
    POST   /methods/post              POST body echo
    PUT    /methods/put/:id           PUT with path param
    DELETE /methods/delete/:id        DELETE with path param
    PATCH  /methods/patch/:id         PATCH with path param
    HEAD   /methods/head              HEAD — header only, no body
    GET    /params/path/:id           path param echo
    GET    /params/query              query param echo  (?name=X&value=Y)
    GET    /cookies/set               sets session + user cookies
    GET    /cookies/echo              echoes Cookie values back as JSON
    POST   /upload                    multipart: 'file' stream + 'fieldname' text
    GET    /download                  text/plain with Content-Disposition header
    GET    /headers/echo              echoes X-Test-Header back
}

uses
  System.SysUtils,
  System.Classes,
  Horse,
  Horse.Commons,
  Horse.Provider.CrossSocket,
  Horse.Provider.CrossSocket.WorkerPool,
  Horse.Core.Param,
  Horse.Core.Param.Field;

const
  TEST_PORT = 9100;

// ── Helpers ───────────────────────────────────────────────────────────────────

{ Minimal JSON string escaping for inline Format() calls. }
function JE(const S: string): string;
begin
  Result := StringReplace(S,  '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
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

end;

// ── Entry point ───────────────────────────────────────────────────────────────

begin
  try
    RegisterRoutes;
    THorseProviderCrossSocket.Listen(TEST_PORT);
    Writeln(Format('[HorseCSTest] Server listening on http://127.0.0.1:%d', [TEST_PORT]));
    Writeln('[HorseCSTest] Run HorseCSTestClient to execute the test suite.');
    Writeln('[HorseCSTest] Press ENTER to stop...');
    Readln;
    THorseProviderCrossSocket.Stop;
    Writeln('[HorseCSTest] Server stopped.');
  except
    on E: Exception do
    begin
      Writeln('[HorseCSTest] Fatal: ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
