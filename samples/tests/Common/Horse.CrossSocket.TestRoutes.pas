unit Horse.CrossSocket.TestRoutes;

(*
  Horse + CrossSocket — Shared Integration Test Routes
  ====================================================

  This unit registers the same 32-route surface that the integration test
  client (HorseCSTestClient.dpr) exercises. It's the single source of truth
  for the test surface — used by every per-shape server project under
  Delphi/ and Lazarus/ in this samples/tests tree.

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
  Horse,
  Horse.Commons,
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

end;

end.
