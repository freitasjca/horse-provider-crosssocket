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
{$IFDEF HORSE_CROSSSOCKET}
  Horse.Provider.CrossSocket.WorkerPool in '..\..\src\Horse.Provider.CrossSocket.WorkerPool.pas',
  Horse.Provider.CrossSocket.Server in '..\..\src\Horse.Provider.CrossSocket.Server.pas',
  Horse.Provider.CrossSocket.Response in '..\..\src\Horse.Provider.CrossSocket.Response.pas',
  Horse.Provider.CrossSocket.Request in '..\..\src\Horse.Provider.CrossSocket.Request.pas',
  Horse.Provider.CrossSocket.Pool in '..\..\src\Horse.Provider.CrossSocket.Pool.pas',
  Horse.Provider.CrossSocket in '..\..\src\Horse.Provider.CrossSocket.pas',
  Net.CrossHttpClient in '..\..\..\Delphi-Cross-Socket\Net\Net.CrossHttpClient.pas',
  Net.CrossHttpParams in '..\..\..\Delphi-Cross-Socket\Net\Net.CrossHttpParams.pas',
  CnSM3 in '..\..\..\Delphi-Cross-Socket\CnPack\Crypto\CnSM3.pas',
  CnSHA3 in '..\..\..\Delphi-Cross-Socket\CnPack\Crypto\CnSHA3.pas',
  CnSHA2 in '..\..\..\Delphi-Cross-Socket\CnPack\Crypto\CnSHA2.pas',
  CnSHA1 in '..\..\..\Delphi-Cross-Socket\CnPack\Crypto\CnSHA1.pas',
  CnRandom in '..\..\..\Delphi-Cross-Socket\CnPack\Crypto\CnRandom.pas',
  CnPemUtils in '..\..\..\Delphi-Cross-Socket\CnPack\Crypto\CnPemUtils.pas',
  CnNative in '..\..\..\Delphi-Cross-Socket\CnPack\Crypto\CnNative.pas',
  CnMD5 in '..\..\..\Delphi-Cross-Socket\CnPack\Crypto\CnMD5.pas',
  CnKDF in '..\..\..\Delphi-Cross-Socket\CnPack\Crypto\CnKDF.pas',
  CnFloat in '..\..\..\Delphi-Cross-Socket\CnPack\Crypto\CnFloat.pas',
  CnDES in '..\..\..\Delphi-Cross-Socket\CnPack\Crypto\CnDES.pas',
  CnConsts in '..\..\..\Delphi-Cross-Socket\CnPack\Crypto\CnConsts.pas',
  CnBase64 in '..\..\..\Delphi-Cross-Socket\CnPack\Crypto\CnBase64.pas',
  CnAES in '..\..\..\Delphi-Cross-Socket\CnPack\Crypto\CnAES.pas',
  DTF.Hash in '..\..\..\Delphi-Cross-Socket\DelphiToFPC\DTF.Hash.pas',
  Net.Wship6 in '..\..\..\Delphi-Cross-Socket\Net\Net.Wship6.pas',
  Net.Winsock2 in '..\..\..\Delphi-Cross-Socket\Net\Net.Winsock2.pas',
  Net.SocketAPI in '..\..\..\Delphi-Cross-Socket\Net\Net.SocketAPI.pas',
  Net.OpenSSL in '..\..\..\Delphi-Cross-Socket\Net\Net.OpenSSL.pas',
  Net.CrossSslSocket.Types in '..\..\..\Delphi-Cross-Socket\Net\Net.CrossSslSocket.Types.pas',
  Net.CrossSslSocket in '..\..\..\Delphi-Cross-Socket\Net\Net.CrossSslSocket.pas',
  Net.CrossSslSocket.OpenSSL in '..\..\..\Delphi-Cross-Socket\Net\Net.CrossSslSocket.OpenSSL.pas',
  Net.CrossSslSocket.Base in '..\..\..\Delphi-Cross-Socket\Net\Net.CrossSslSocket.Base.pas',
  Net.CrossSocket in '..\..\..\Delphi-Cross-Socket\Net\Net.CrossSocket.pas',
  Net.CrossSocket.Iocp in '..\..\..\Delphi-Cross-Socket\Net\Net.CrossSocket.Iocp.pas',
  Net.CrossSocket.Base in '..\..\..\Delphi-Cross-Socket\Net\Net.CrossSocket.Base.pas',
  Net.CrossServer in '..\..\..\Delphi-Cross-Socket\Net\Net.CrossServer.pas',
  Net.CrossHttpUtils in '..\..\..\Delphi-Cross-Socket\Net\Net.CrossHttpUtils.pas',
  Net.CrossHttpServer in '..\..\..\Delphi-Cross-Socket\Net\Net.CrossHttpServer.pas',
  Net.CrossHttpRouterDirUtils in '..\..\..\Delphi-Cross-Socket\Net\Net.CrossHttpRouterDirUtils.pas',
  Net.CrossHttpRouter in '..\..\..\Delphi-Cross-Socket\Net\Net.CrossHttpRouter.pas',
  Net.CrossHttpParser in '..\..\..\Delphi-Cross-Socket\Net\Net.CrossHttpParser.pas',
  Utils.Utils in '..\..\..\Delphi-Cross-Socket\Utils\Utils.Utils.pas',
  Utils.SyncObjs in '..\..\..\Delphi-Cross-Socket\Utils\Utils.SyncObjs.pas',
  Utils.StrUtils in '..\..\..\Delphi-Cross-Socket\Utils\Utils.StrUtils.pas',
  Utils.Rtti in '..\..\..\Delphi-Cross-Socket\Utils\Utils.Rtti.pas',
  Utils.RegEx in '..\..\..\Delphi-Cross-Socket\Utils\Utils.RegEx.pas',
  Utils.Logger in '..\..\..\Delphi-Cross-Socket\Utils\Utils.Logger.pas',
  Utils.IOUtils in '..\..\..\Delphi-Cross-Socket\Utils\Utils.IOUtils.pas',
  Utils.Hash in '..\..\..\Delphi-Cross-Socket\Utils\Utils.Hash.pas',
  Utils.DateTime in '..\..\..\Delphi-Cross-Socket\Utils\Utils.DateTime.pas',
  Utils.ArrayUtils in '..\..\..\Delphi-Cross-Socket\Utils\Utils.ArrayUtils.pas',
  Utils.AnonymousThread in '..\..\..\Delphi-Cross-Socket\Utils\Utils.AnonymousThread.pas',
{$ENDIF}
  ThirdParty.Posix.Syslog in '..\..\..\horse\src\ThirdParty.Posix.Syslog.pas',
  Horse.WebModule in '..\..\..\horse\src\Horse.WebModule.pas' {HorseWebModule: TWebModule},
  Horse.Session in '..\..\..\horse\src\Horse.Session.pas',
  Horse.Rtti in '..\..\..\horse\src\Horse.Rtti.pas',
  Horse.Rtti.Helper in '..\..\..\horse\src\Horse.Rtti.Helper.pas',
  Horse.Response in '..\..\..\horse\src\Horse.Response.pas',
  Horse.Request in '..\..\..\horse\src\Horse.Request.pas',
  Horse.Provider.VCL in '..\..\..\horse\src\Horse.Provider.VCL.pas',
  Horse.Provider.ISAPI in '..\..\..\horse\src\Horse.Provider.ISAPI.pas',
  Horse.Provider.IOHandleSSL in '..\..\..\horse\src\Horse.Provider.IOHandleSSL.pas',
  Horse.Provider.IOHandleSSL.Contract in '..\..\..\horse\src\Horse.Provider.IOHandleSSL.Contract.pas',
  Horse.Provider.FPC.LCL in '..\..\..\horse\src\Horse.Provider.FPC.LCL.pas',
  Horse.Provider.FPC.HTTPApplication in '..\..\..\horse\src\Horse.Provider.FPC.HTTPApplication.pas',
  Horse.Provider.FPC.FastCGI in '..\..\..\horse\src\Horse.Provider.FPC.FastCGI.pas',
  Horse.Provider.FPC.Daemon in '..\..\..\horse\src\Horse.Provider.FPC.Daemon.pas',
  Horse.Provider.FPC.CGI in '..\..\..\horse\src\Horse.Provider.FPC.CGI.pas',
  Horse.Provider.FPC.Apache in '..\..\..\horse\src\Horse.Provider.FPC.Apache.pas',
  Horse.Provider.Daemon in '..\..\..\horse\src\Horse.Provider.Daemon.pas',
  Horse.Provider.Console in '..\..\..\horse\src\Horse.Provider.Console.pas',
  Horse.Provider.Config in '..\..\..\horse\src\Horse.Provider.Config.pas',
  Horse.Provider.CGI in '..\..\..\horse\src\Horse.Provider.CGI.pas',
  Horse.Provider.Apache in '..\..\..\horse\src\Horse.Provider.Apache.pas',
  Horse.Provider.Abstract in '..\..\..\horse\src\Horse.Provider.Abstract.pas',
  Horse.Proc in '..\..\..\horse\src\Horse.Proc.pas',
  Horse in '..\..\..\horse\src\Horse.pas',
  Horse.Core.Param in '..\..\..\horse\src\Horse.Core.Param.pas',
  Horse.Core.Param.Field in '..\..\..\horse\src\Horse.Core.Param.Field.pas',
  Horse.Commons in '..\..\..\horse\src\Horse.Commons.pas',
  Horse.Callback in '..\..\..\horse\src\Horse.Callback.pas',
  Horse.Core.RouterTree in '..\..\..\horse\src\Horse.Core.RouterTree.pas';

const
  TEST_PORT = 9010;

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
