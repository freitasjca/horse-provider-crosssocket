program HorseCSTestClient;

{$APPTYPE CONSOLE}

{
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
}

uses
  System.SysUtils,
  System.StrUtils,
  System.Classes,
  System.SyncObjs,
  Net.CrossHttpClient,
  Net.CrossHttpParams;

const
  BASE_URL   = 'http://127.0.0.1:9100';
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
  LEvent: TEvent;
begin
  AResult    := Default(TReqResult);
  LEvent     := TEvent.Create(nil, True, False, '');
  try
    AClient.DoRequest(AMethod, AUrl, AHeaders, ABody, nil, nil,
      procedure(const AResp: ICrossHttpClientResponse)
      begin
        if AResp <> nil then
        begin
          AResult.StatusCode := AResp.StatusCode;
          AResult.Body       := StreamToStr(AResp.Content);
          AResult.Response   := AResp;
        end;
        LEvent.SetEvent;
      end);
    AResult.TimedOut := (LEvent.WaitFor(TIMEOUT_MS) <> wrSignaled);
  finally
    LEvent.Free;
  end;
  Result := not AResult.TimedOut;
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
  LEvent: TEvent;
begin
  AResult  := Default(TReqResult);
  LEvent   := TEvent.Create(nil, True, False, '');
  try
    AClient.DoRequest('POST', AUrl, AHeaders, ABody, nil, nil,
      procedure(const AResp: ICrossHttpClientResponse)
      begin
        if AResp <> nil then
        begin
          AResult.StatusCode := AResp.StatusCode;
          AResult.Body       := StreamToStr(AResp.Content);
          AResult.Response   := AResp;
        end;
        LEvent.SetEvent;
      end);
    AResult.TimedOut := (LEvent.WaitFor(TIMEOUT_MS) <> wrSignaled);
  finally
    LEvent.Free;
  end;
  Result := not AResult.TimedOut;
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
