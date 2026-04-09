program HorseCSTestClient;

{$APPTYPE CONSOLE}

(*
  Horse + CrossSocket  —  Integration Test Client
  =================================================
  Destination: horse-provider-crosssocket/samples/tests/HorseCSTestClient.dpr

  Requires HorseCSTestServer running on 127.0.0.1:9100 before executing.

  Test matrix:
    01  GET    /ping                       → 200 "pong"
    02  GET    /methods/get                → 200 {"method":"GET"}
    03  POST   /methods/post               → 200 body echo
    04  PUT    /methods/put/42             → 200 {"id":"42"}
    05  DELETE /methods/delete/99          → 200 {"id":"99"}
    06  PATCH  /methods/patch/7            → 200 {"id":"7"}
    07  HEAD   /methods/head               → 200, X-Head-Ok header, empty body
    08  GET    /params/path/hello          → 200 {"id":"hello"}
    09  GET    /params/query?name=...      → 200 query param echo
    10  GET    /cookies/set                → 200 two Set-Cookie headers
    11  GET    /cookies/echo (+ cookies)   → 200 cookie values echoed back
    12  POST   /upload (multipart)         → 200 {"received":true,...}
    13  GET    /download                   → 200 Content-Disposition + body
    14  GET    /headers/echo               → 200 custom header echoed back
*)

uses
  System.SysUtils,
  System.StrUtils,
  System.Classes,
  Net.CrossHttpClient,
  Net.CrossHttpParams,
  Horse.Provider.CrossSocket.WorkerPool in '..\..\src\Horse.Provider.CrossSocket.WorkerPool.pas',
  Horse.Provider.CrossSocket.Server in '..\..\src\Horse.Provider.CrossSocket.Server.pas',
  Horse.Provider.CrossSocket.Response in '..\..\src\Horse.Provider.CrossSocket.Response.pas',
  Horse.Provider.CrossSocket.Request in '..\..\src\Horse.Provider.CrossSocket.Request.pas',
  Horse.Provider.CrossSocket.Pool in '..\..\src\Horse.Provider.CrossSocket.Pool.pas',
  Horse.Provider.CrossSocket in '..\..\src\Horse.Provider.CrossSocket.pas',
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
  ThirdParty.Posix.Syslog in '..\..\..\horse\src\ThirdParty.Posix.Syslog.pas',
  System.SyncObjs  ;

const
  BASE_URL   = 'http://127.0.0.1:9010';
  TIMEOUT_MS = 8000;

// ── Global counters ───────────────────────────────────────────────────────────

var
  GPassCount: Integer = 0;
  GFailCount: Integer = 0;

// ── Helpers ───────────────────────────────────────────────────────────────────

{ Read the complete content of a TStream into a UTF-8 string. }
function StreamToStr(AStream: TStream): string;
var
  LBytes: TBytes;
begin
  Result := '';
  if not Assigned(AStream) or (AStream.Size = 0) then
    Exit;
  AStream.Position := 0;
  SetLength(LBytes, AStream.Size);
  AStream.ReadBuffer(LBytes[0], AStream.Size);
  Result := TEncoding.UTF8.GetString(LBytes);
end;

{ Report a single assertion result. }
procedure Check(const AName: string; const APassed: Boolean;
  const ADetail: string = '');
begin
  if APassed then
  begin
    Writeln(Format('  PASS  %s', [AName]));
    Inc(GPassCount);
  end
  else
  begin
    if ADetail <> '' then
      Writeln(Format('  FAIL  %s  [%s]', [AName, ADetail]))
    else
      Writeln(Format('  FAIL  %s', [AName]));
    Inc(GFailCount);
  end;
end;

// ── Synchronous request wrappers ──────────────────────────────────────────────
//
// TCrossHttpClient is fully async. These thin wrappers use a TEvent to block
// the calling thread until the callback fires or the timeout elapses.
//

type
  TReqResult = record
    StatusCode: Integer;               // 0 on timeout / connection error
    Body:       string;
    Response:   ICrossHttpClientResponse;
    TimedOut:   Boolean;
  end;

{ TBytes body overload — suitable for GET/PUT/POST/PATCH/DELETE/HEAD. }
function DoSync(
  const AClient:  TCrossHttpClient;
  const AMethod:  string;
  const AUrl:     string;
  const AHeaders: THttpHeader;      // caller creates + frees; may be nil
  const ABody:    TBytes;           // may be nil
  out   AResult:  TReqResult
): Boolean;
var
  LEvent:  TEvent;
  LResult: TReqResult;   // captured by the closure; assigned to AResult after wait
begin
  LResult    := Default(TReqResult);
  LEvent     := TEvent.Create(nil, True, False, '');
  try
    AClient.DoRequest(AMethod, AUrl, AHeaders, ABody, nil, nil,
      procedure(const AResp: ICrossHttpClientResponse)
      begin
        if AResp <> nil then
        begin
          LResult.StatusCode := AResp.StatusCode;
          LResult.Body       := StreamToStr(AResp.Content);
          LResult.Response   := AResp;
        end;
        LEvent.SetEvent;
      end);
    LResult.TimedOut := (LEvent.WaitFor(TIMEOUT_MS) <> wrSignaled);
  finally
    LEvent.Free;
  end;
  AResult := LResult;
  Result  := not AResult.TimedOut;
end;

{ multipart/form-data overload. }
function DoSyncMP(
  const AClient:  TCrossHttpClient;
  const AUrl:     string;
  const AHeaders: THttpHeader;
  const ABody:    THttpMultiPartFormData;    // caller creates + frees after return
  out   AResult:  TReqResult
): Boolean;
var
  LEvent:  TEvent;
  LResult: TReqResult;   // captured by the closure; assigned to AResult after wait
begin
  LResult  := Default(TReqResult);
  LEvent   := TEvent.Create(nil, True, False, '');
  try
    AClient.DoRequest('POST', AUrl, AHeaders, ABody, nil, nil,
      procedure(const AResp: ICrossHttpClientResponse)
      begin
        if AResp <> nil then
        begin
          LResult.StatusCode := AResp.StatusCode;
          LResult.Body       := StreamToStr(AResp.Content);
          LResult.Response   := AResp;
        end;
        LEvent.SetEvent;
      end);
    LResult.TimedOut := (LEvent.WaitFor(TIMEOUT_MS) <> wrSignaled);
  finally
    LEvent.Free;
  end;
  AResult := LResult;
  Result  := not AResult.TimedOut;
end;

// ── Test helpers ──────────────────────────────────────────────────────────────

{ Parse a Set-Cookie header line and return the value for the named cookie.
  Expects the wire format "name=value; Path=/; ..." }
function GetSetCookieValue(
  const AResponse: ICrossHttpClientResponse;
  const ACookieName: string
): string;
var
  I:       Integer;
  Line:    string;
  First:   string;
  EqPos:   Integer;
begin
  Result := '';
  if AResponse = nil then Exit;
  for I := 0 to AResponse.Header.Count - 1 do
  begin
    if not SameText(AResponse.Header.Items[I].Name, 'Set-Cookie') then
      Continue;
    Line := AResponse.Header.Items[I].Value;
    // Take only the first segment (before any semicolon)
    First := Trim(Copy(Line, 1, Pos(';', Line + ';') - 1));
    EqPos := Pos('=', First);
    if (EqPos > 0) and SameText(Copy(First, 1, EqPos - 1), ACookieName) then
    begin
      Result := Copy(First, EqPos + 1, MaxInt);
      Exit;
    end;
  end;
end;

// ── Test suite ────────────────────────────────────────────────────────────────

procedure RunTests(const AClient: TCrossHttpClient);
var
  R:              TReqResult;
  LHeaders:       THttpHeader;
  LForm:          THttpMultiPartFormData;
  LFileStream:    TMemoryStream;
  LFileBytes:     TBytes;
  LSessionCookie: string;
  LUserCookie:    string;

  procedure Section(const ATitle: string);
  begin
    Writeln('');
    Writeln('── ' + ATitle);
  end;

begin
(*
  // ── 01  Health check ─────────────────────────────────────────────────────────
  Section('01  GET /ping');
  DoSync(AClient, 'GET', BASE_URL + '/ping', nil, nil, R);
  Check('status 200',      R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('body = "pong"',   R.Body = 'pong',    R.Body);

  // ── 02  GET method ───────────────────────────────────────────────────────────
  Section('02  GET /methods/get');
  DoSync(AClient, 'GET', BASE_URL + '/methods/get', nil, nil, R);
  Check('status 200',              R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('body contains "GET"',     Pos('"GET"', R.Body) > 0, R.Body);
*)
  // ── 03  POST with body ───────────────────────────────────────────────────────
  Section('03  POST /methods/post  (JSON body echo)');
  LHeaders := THttpHeader.Create;
  try
    LHeaders['Content-Type'] := 'application/json; charset=utf-8';
    DoSync(AClient, 'POST', BASE_URL + '/methods/post',
           LHeaders, TEncoding.UTF8.GetBytes('{"hello":"world"}'), R);
  finally
    LHeaders.Free;
  end;
  Check('status 200',                  R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('body contains "POST"',        Pos('"POST"',  R.Body) > 0, R.Body);
  Check('body echoes request payload', Pos('hello',   R.Body) > 0, R.Body);

(*
  // ── 04  PUT with path param ──────────────────────────────────────────────────
  Section('04  PUT /methods/put/42');
  DoSync(AClient, 'PUT', BASE_URL + '/methods/put/42', nil, nil, R);
  Check('status 200',       R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('id = "42"',        Pos('"42"', R.Body) > 0, R.Body);

  // ── 05  DELETE with path param ───────────────────────────────────────────────
  Section('05  DELETE /methods/delete/99');
  DoSync(AClient, 'DELETE', BASE_URL + '/methods/delete/99', nil, nil, R);
  Check('status 200',       R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('id = "99"',        Pos('"99"', R.Body) > 0, R.Body);

  // ── 06  PATCH with path param ────────────────────────────────────────────────
  Section('06  PATCH /methods/patch/7');
  DoSync(AClient, 'PATCH', BASE_URL + '/methods/patch/7', nil, nil, R);
  Check('status 200',       R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('id = "7"',         Pos('"7"', R.Body) > 0, R.Body);

  // ── 07  HEAD — no response body ──────────────────────────────────────────────
  Section('07  HEAD /methods/head  (header only, empty body)');
  DoSync(AClient, 'HEAD', BASE_URL + '/methods/head', nil, nil, R);
  Check('status 200',            R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('body is empty',         R.Body = '', R.Body);
  if Assigned(R.Response) then
    Check('X-Head-Ok header present',
      R.Response.Header['X-Head-Ok'] = 'true',
      R.Response.Header['X-Head-Ok']);

  // ── 08  Path parameter ───────────────────────────────────────────────────────
  Section('08  GET /params/path/hello');
  DoSync(AClient, 'GET', BASE_URL + '/params/path/hello', nil, nil, R);
  Check('status 200',            R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('id = "hello"',          Pos('"hello"', R.Body) > 0, R.Body);

  // ── 09  Query parameters ─────────────────────────────────────────────────────
  Section('09  GET /params/query?name=Horse&value=CrossSocket');
  DoSync(AClient, 'GET',
    BASE_URL + '/params/query?name=Horse&value=CrossSocket', nil, nil, R);
  Check('status 200',               R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('name = "Horse"',           Pos('"Horse"',       R.Body) > 0, R.Body);
  Check('value = "CrossSocket"',    Pos('"CrossSocket"', R.Body) > 0, R.Body);

  // ── 10  Set cookies ──────────────────────────────────────────────────────────
  Section('10  GET /cookies/set  (check Set-Cookie headers)');
  DoSync(AClient, 'GET', BASE_URL + '/cookies/set', nil, nil, R);
  Check('status 200', R.StatusCode = 200, IntToStr(R.StatusCode));
  LSessionCookie := '';
  LUserCookie    := '';
  if Assigned(R.Response) then
  begin
    LSessionCookie := GetSetCookieValue(R.Response, 'session');
    LUserCookie    := GetSetCookieValue(R.Response, 'user');
    Check('Set-Cookie session=abc123', LSessionCookie = 'abc123', LSessionCookie);
    Check('Set-Cookie user=tester',    LUserCookie = 'tester',    LUserCookie);
  end
  else
    Check('response received', False, 'nil response');

  // ── 11  Echo cookies back ────────────────────────────────────────────────────
  Section('11  GET /cookies/echo  (send cookies, verify echo)');
  // Fall back to known-good values if test 10 failed to parse
  if LSessionCookie = '' then LSessionCookie := 'abc123';
  if LUserCookie    = '' then LUserCookie    := 'tester';
  LHeaders := THttpHeader.Create;
  try
    LHeaders['Cookie'] := Format('session=%s; user=%s',
      [LSessionCookie, LUserCookie]);
    DoSync(AClient, 'GET', BASE_URL + '/cookies/echo', LHeaders, nil, R);
  finally
    LHeaders.Free;
  end;
  Check('status 200',                  R.StatusCode = 200,         IntToStr(R.StatusCode));
  Check('session echoed as "abc123"',  Pos('"abc123"', R.Body) > 0, R.Body);
  Check('user echoed as "tester"',     Pos('"tester"', R.Body) > 0, R.Body);

  // ── 12  Multipart file upload ────────────────────────────────────────────────
  Section('12  POST /upload  (multipart/form-data, file field)');
  LFileBytes  := TEncoding.UTF8.GetBytes('This is the uploaded file content.');
  LFileStream := TMemoryStream.Create;
  try
    LFileStream.WriteBuffer(LFileBytes[0], Length(LFileBytes));
    LFileStream.Position := 0;

    LForm := THttpMultiPartFormData.Create;
    try
      LForm.AddField('fieldname', 'myupload.txt'); // text field: original filename
      LForm.AddFile('file', 'myupload.txt', LFileStream, False {not owned});
      // DoSyncMP blocks until the response arrives, so LFileStream is safe here
      DoSyncMP(AClient, BASE_URL + '/upload', nil, LForm, R);
    finally
      LForm.Free;
    end;
  finally
    LFileStream.Free;
  end;
  Check('status 200',           R.StatusCode = 200,                IntToStr(R.StatusCode));
  Check('"received":true',      Pos('"received":true', R.Body) > 0, R.Body);
  Check('filename echoed',      Pos('myupload.txt',    R.Body) > 0, R.Body);
  Check('size > 0 bytes',       Pos('"size":0',        R.Body) = 0, R.Body);

  // ── 13  File download ────────────────────────────────────────────────────────
  Section('13  GET /download  (Content-Disposition + body)');
  DoSync(AClient, 'GET', BASE_URL + '/download', nil, nil, R);
  Check('status 200',                  R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('body contains "Horse"',       Pos('Horse', R.Body) > 0, R.Body);
  if Assigned(R.Response) then
    Check('Content-Disposition: attachment',
      Pos('attachment', R.Response.Header['Content-Disposition']) > 0,
      R.Response.Header['Content-Disposition']);

  // ── 14  Custom request header echo ───────────────────────────────────────────
  Section('14  GET /headers/echo  (X-Test-Header round-trip)');
  LHeaders := THttpHeader.Create;
  try
    LHeaders['X-Test-Header'] := 'HelloFromClient';
    DoSync(AClient, 'GET', BASE_URL + '/headers/echo', LHeaders, nil, R);
  finally
    LHeaders.Free;
  end;
  Check('status 200',                  R.StatusCode = 200,              IntToStr(R.StatusCode));
  Check('X-Test-Header value echoed',  Pos('HelloFromClient', R.Body) > 0, R.Body);
*)
end;

// ── Entry point ───────────────────────────────────────────────────────────────

var
  Client: TCrossHttpClient;
begin
  Writeln('[HorseCSTest] Client — target: ' + BASE_URL);
  Writeln('[HorseCSTest] Ensure HorseCSTestServer is running before proceeding.');
  Writeln('');

  Client := TCrossHttpClient.Create(2 {IoThreads});
  try
    try
      RunTests(Client);
    except
      on E: Exception do
        Writeln('[HorseCSTest] Unexpected exception during tests: ' + E.ClassName
          + ': ' + E.Message);
    end;
  finally
    Client.Free;
  end;

  Writeln('');
  Writeln(Format('[HorseCSTest] %d passed, %d failed  (total %d)',
    [GPassCount, GFailCount, GPassCount + GFailCount]));
  if GFailCount = 0 then
    Writeln('[HorseCSTest] All tests PASSED.')
  else
    Writeln('[HorseCSTest] Some tests FAILED — see details above.');

  ExitCode := GFailCount;

  Writeln('');
  Writeln('[HorseCSTest] Press ENTER to exit...');
  Readln;
end.
