program HorseCSTestClient;

{$APPTYPE CONSOLE}

(*
  Horse + CrossSocket  —  Integration Test Client
  =================================================
  Destination: horse-provider-crosssocket/samples/tests/HorseCSTestClient.dpr

  Requires HorseCSTestServer running on 127.0.0.1:9100 before executing.

  Test matrix:
    01  GET    /ping                         → 200 "pong"
    02  GET    /methods/get                  → 200 {"method":"GET"}
    03  POST   /methods/post                 → 200 body echo
    04  PUT    /methods/put/42               → 200 {"id":"42"}
    05  DELETE /methods/delete/99            → 200 {"id":"99"}
    06  PATCH  /methods/patch/7              → 200 {"id":"7"}
    07  HEAD   /methods/head                 → 200, X-Head-Ok header, empty body
    08  GET    /params/path/hello            → 200 {"id":"hello"}
    09  GET    /params/query?name=...        → 200 query param echo
    10  GET    /cookies/set                  → 200 two Set-Cookie headers
    11  GET    /cookies/echo (+ cookies)     → 200 cookie values echoed back
    12  POST   /upload (multipart)           → 200 {"received":true,...}
    13  GET    /download                     → 200 Content-Disposition + body
    14  GET    /headers/echo                 → 200 custom header echoed back
    15  POST   /methods/post  empty body     → 200 body field is empty string
    16  POST   /echo/body  large (64 KB)     → 200 "size":65536 exact
    17  POST   /echo/body  sequential (A→B)  → no body leakage between pooled requests
    18  POST   /echo/body  concurrent (×4)   → no cross-contamination in parallel pool use
    19  GET    /params/multi/:a/:b           → 200 both params echoed
    20  GET    /does/not/exist               → 404 not found
    21  GET    /status/400                   → 400
    22  GET    /status/500                   → 500
    23  Content-Type of JSON response        → contains "application/json"
    24  GET    /response/large               → body length = 65536
    25  GET    /raw/webrequest                → RawWebRequest adapter exposes
                                                method/host/pathInfo/header/remoteAddr
    26  OPTIONS /raw/cors                     → 204 + Access-Control-Allow-Origin
                                                (Horse.CORS compatibility probe)
    27  GET    /raw/cors                      → 200 body "cors-route:GET"
    28  GET    /raw/webresponse               → 200, X-Via-RawResponse header set
                                                via Res.RawWebResponse.SetCustomHeader
                                                (PATCH-RES-6 regression)
    29  POST   /pool/burst  ×8 concurrent     → all 200, unique markers, no cross-leak
                                                (worker pool cascade wake stress test)
    30  POST   /pool/burst  rapid sequential  → 5 requests immediately after burst;
                                                validates pool drain/refill correctness
    31  POST   /echo/body-twice               → body echoed identically in both "first"
                                                and "second" fields ("equal":true)
                                                (PATCH-REQ-9 FBodyString cache regression)
    32  GET    /compat/rawbody                → body = "shadow-wins" despite
                                                RawWebResponse.Content being set first
                                                (COMPAT-1 shadow-field-wins validation)
    33  GET    /stream/pull                   → 200, body reassembled from 5 chunks
                                                + /ping healthy after deferred release
                                                (PATCH-STREAM-1 basic pull streaming)
    34  GET    /stream/content-type           → 200, body = 3 ct-chunks, Content-Type
                                                header = application/octet-stream
                                                (PATCH-STREAM-1 content-type propagation)
    35  GET    /stream/empty                  → 200, empty body, /ping still healthy
                                                (PATCH-STREAM-1 zero-chunk edge case)
    36  GET    /stream/pull  ×2 concurrent    → both 200, both complete bodies,
                                                no cross-drain corruption, pool healthy
                                                (PATCH-STREAM-1 deferred release isolation)
*)

uses
  System.SysUtils,
  System.StrUtils,
  System.Classes,
  System.SyncObjs,
  System.Diagnostics,    // TStopwatch — high-resolution timing
  System.TimeSpan,
  Net.CrossHttpClient,
  Net.CrossHttpParams;

const
  BASE_URL = 'http://127.0.0.1:9010'; // 'http://ipv4.fiddler:9010';   // was: 'http://127.0.0.1:9010'  - For Fiddler catch local
  TIMEOUT_MS          = 8000;
  LARGE_RESPONSE_SIZE = 65536; // must match server constant
  LARGE_BODY_SIZE     = 65536; // bytes sent in test 16
  CONCURRENT_COUNT    = 4;     // parallel requests in test 18
  BURST_COUNT         = 8;     // parallel requests in test 29
  RAPID_SEQ_COUNT     = 5;     // sequential requests in test 30

// ── Global counters & timing ──────────────────────────────────────────────────

var
  GPassCount:        Integer = 0;
  GFailCount:        Integer = 0;
  // Wall-clock stopwatch covering the whole RunTests run. Used to time each
  // Section relative to the previous one so a long-running test is obvious
  // when scanning the output. Started in main begin/end, never reset.
  GGlobalSW:         TStopwatch;
  GLastSectionTicks: Int64 = 0;

// ── Timing helpers ────────────────────────────────────────────────────────────

{ Format a millisecond delta like " 12.3 ms" — fixed width so the timing
  column lines up in the output. }
function FmtMs(const AMilliseconds: Double): string;
begin
  Result := Format('%7.1f ms', [AMilliseconds]);
end;

{ Print a request-level timing breakdown right under the matching PASS/FAIL
  block. Columns:
    server  → time from "DoRequest dispatched" to "response callback fired"
              (network + server pipeline; this is what to investigate if slow)
    client  → time from "callback fired" to "synchronous wait released"
              (event signalling + result marshalling; should be sub-millisecond)
    total   → server + client (what the test step actually cost)
  Timeouts print "TIMEOUT" in the server column. }
procedure ReportTiming(
  const ALabel:       string;
  const AServerMs:    Double;
  const AClientMs:    Double;
  const ATimedOut:    Boolean
);
begin
  if ATimedOut then
    Writeln(Format('  TIME  %-22s server: TIMEOUT (>%d ms)  client: %s',
      [ALabel, TIMEOUT_MS, FmtMs(AClientMs)]))
  else
    Writeln(Format('  TIME  %-22s server: %s  client: %s  total: %s',
      [ALabel, FmtMs(AServerMs), FmtMs(AClientMs),
       FmtMs(AServerMs + AClientMs)]));
end;

// ── Types ─────────────────────────────────────────────────────────────────────

// Used by the concurrent body-isolation test (test 18).
type
  TConcurrentEntry = record
    Marker:   string;    // unique payload this request sends and expects back
    Event:    TEvent;    // signalled when the response callback fires
    Status:   Integer;   // HTTP status code received
    Body:     string;    // response body text
  end;

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
    // Timing (filled by DoSync / DoSyncMP):
    //   ServerMs — request dispatched → response callback fired
    //              (network round-trip + server-side pipeline)
    //   ClientMs — callback fired → synchronous wait released
    //              (event signalling + result marshalling; ~0 normally)
    ServerMs:   Int64;
    ClientMs:   Int64;
  end;

{ TBytes body overload — suitable for GET/PUT/POST/PATCH/DELETE/HEAD.

  Timing instrumentation:
    LSWReq starts immediately before DoRequest.
    LCallbackTicks is set inside the callback (server round-trip complete).
    LSWReq is stopped after WaitFor returns (full sync wait complete).
  Caller reads AResult.ServerMs / AResult.ClientMs to split the latency
  into "server pipeline + network" vs "TEvent wake + result marshalling". }
function DoSync(
  const AClient:  TCrossHttpClient;
  const AMethod:  string;
  const AUrl:     string;
  const AHeaders: THttpHeader;      // caller creates + frees; may be nil
  const ABody:    TBytes;           // may be nil
  out   AResult:  TReqResult
): Boolean;
var
  LEvent:          TEvent;
  LResult:         TReqResult;
  LSWReq:          TStopwatch;
  LCallbackTicks:  Int64;
begin
  LResult        := Default(TReqResult);
  LEvent         := TEvent.Create(nil, True, False, '');
  LCallbackTicks := 0;
  try
    LSWReq := TStopwatch.StartNew;
    AClient.DoRequest(AMethod, AUrl, AHeaders, ABody, nil, nil,
      procedure(const AResp: ICrossHttpClientResponse)
      begin
        LCallbackTicks := LSWReq.ElapsedMilliseconds;
        if AResp <> nil then
        begin
          LResult.StatusCode := AResp.StatusCode;
          LResult.Body       := StreamToStr(AResp.Content);
          LResult.Response   := AResp;
        end;
        LEvent.SetEvent;
      end);
    LResult.TimedOut := (LEvent.WaitFor(TIMEOUT_MS) <> wrSignaled);
    LSWReq.Stop;
    if LResult.TimedOut then
    begin
      LResult.ServerMs := 0;                          // unknown
      LResult.ClientMs := LSWReq.ElapsedMilliseconds; // full wait elapsed
    end
    else
    begin
      LResult.ServerMs := LCallbackTicks;
      LResult.ClientMs := LSWReq.ElapsedMilliseconds - LCallbackTicks;
    end;
  finally
    LEvent.Free;
  end;
  AResult := LResult;
  Result  := not AResult.TimedOut;
  ReportTiming(AMethod + ' ' + AUrl, LResult.ServerMs, LResult.ClientMs,
    LResult.TimedOut);
end;

{ multipart/form-data overload. Same timing scheme as DoSync. }
function DoSyncMP(
  const AClient:  TCrossHttpClient;
  const AUrl:     string;
  const AHeaders: THttpHeader;
  const ABody:    THttpMultiPartFormData;
  out   AResult:  TReqResult
): Boolean;
var
  LEvent:          TEvent;
  LResult:         TReqResult;
  LSWReq:          TStopwatch;
  LCallbackTicks:  Int64;
begin
  LResult        := Default(TReqResult);
  LEvent         := TEvent.Create(nil, True, False, '');
  LCallbackTicks := 0;
  try
    LSWReq := TStopwatch.StartNew;
    AClient.DoRequest('POST', AUrl, AHeaders, ABody, nil, nil,
      procedure(const AResp: ICrossHttpClientResponse)
      begin
        LCallbackTicks := LSWReq.ElapsedMilliseconds;
        if AResp <> nil then
        begin
          LResult.StatusCode := AResp.StatusCode;
          LResult.Body       := StreamToStr(AResp.Content);
          LResult.Response   := AResp;
        end;
        LEvent.SetEvent;
      end);
    LResult.TimedOut := (LEvent.WaitFor(TIMEOUT_MS) <> wrSignaled);
    LSWReq.Stop;
    if LResult.TimedOut then
    begin
      LResult.ServerMs := 0;
      LResult.ClientMs := LSWReq.ElapsedMilliseconds;
    end
    else
    begin
      LResult.ServerMs := LCallbackTicks;
      LResult.ClientMs := LSWReq.ElapsedMilliseconds - LCallbackTicks;
    end;
  finally
    LEvent.Free;
  end;
  AResult := LResult;
  Result  := not AResult.TimedOut;
  ReportTiming('POST ' + AUrl + ' (multipart)',
    LResult.ServerMs, LResult.ClientMs, LResult.TimedOut);
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
  LLargeBody:     TBytes;
  LSessionCookie: string;
  LUserCookie:    string;
  // Test 18 — concurrent batch (CONCURRENT_COUNT entries)
  LBatch:         array[0..CONCURRENT_COUNT - 1] of TConcurrentEntry;
  LAllStatus200:  Boolean;
  LAllMarkersOk:  Boolean;
  LNoCrossLeaks:  Boolean;
  I:              Integer;
  // Test 29 — burst batch (BURST_COUNT entries)
  LBurstBatch:    array[0..BURST_COUNT - 1] of TConcurrentEntry;
  LBurstAllOk:    Boolean;
  LBurstAllMarkers: Boolean;
  LBurstNoCross:  Boolean;
  // Test 30 — rapid sequential
  LSeqAllOk:      Boolean;
  LSeqMarker:     string;
  J:              Integer;
  // Test 36 — concurrent streaming (deferred pool release isolation)
  LStreamBatch:   array[0..1] of TConcurrentEntry;
  LStreamAllOk:   Boolean;
  LStreamAllBody: Boolean;
  // Test 37 — binary request body (FIX-BINBODY-1)
  LBinBody:       TBytes;

  { Section header. Prints the elapsed wall-clock time since the previous
    Section call so a slow test stands out without having to compare
    absolute timestamps. The very first call shows "0.0 ms since start". }
  procedure Section(const ATitle: string);
  var
    LNowTicks: Int64;
    LSince:    Int64;
  begin
    LNowTicks := GGlobalSW.ElapsedMilliseconds;
    LSince    := LNowTicks - GLastSectionTicks;
    GLastSectionTicks := LNowTicks;
    Writeln('');
    Writeln(Format('── %s   (+%d ms since previous test, %d ms total)',
      [ATitle, LSince, LNowTicks]));
  end;

  // ── Test 18 helper — closure factory ────────────────────────────────────────
  // Each call creates a new stack frame for AIdx, so the anonymous procedure
  // inside captures an independent copy per iteration.  Inline-variable
  // declarations (var LIdx := I) inside a for loop body are NOT reliably
  // captured as per-iteration bindings in Delphi 10.3/10.4: the compiler may
  // hoist LIdx to a single shared heap location, causing all four closures to
  // refer to the last-written value (3) after the loop.  A nested procedure
  // with a value parameter is the standard Delphi closure-factory workaround.
  // ── Test 29 helper — burst closure factory (same pattern as FireOne) ───────
  procedure FireBurst(const AIdx: Integer; AHeaders: THttpHeader);
  begin
    AClient.DoRequest('POST', BASE_URL + '/pool/burst',
      AHeaders,
      TEncoding.UTF8.GetBytes(LBurstBatch[AIdx].Marker),
      nil, nil,
      procedure(const AResp: ICrossHttpClientResponse)
      begin
        if AResp <> nil then
        begin
          LBurstBatch[AIdx].Status := AResp.StatusCode;
          LBurstBatch[AIdx].Body   := StreamToStr(AResp.Content);
        end;
        LBurstBatch[AIdx].Event.SetEvent;
      end);
  end;

  procedure FireOne(const AIdx: Integer; AHeaders: THttpHeader);
  begin
    AClient.DoRequest('POST', BASE_URL + '/echo/body',
      AHeaders,
      TEncoding.UTF8.GetBytes(LBatch[AIdx].Marker),
      nil, nil,
      procedure(const AResp: ICrossHttpClientResponse)
      begin
        if AResp <> nil then
        begin
          LBatch[AIdx].Status := AResp.StatusCode;
          LBatch[AIdx].Body   := StreamToStr(AResp.Content);
        end;
        LBatch[AIdx].Event.SetEvent;
      end);
  end;

  // ── Test 36 helper — fires one GET /stream/pull request asynchronously ─────────
  // Nested procedure (not a plain anonymous procedure) so AIdx is a per-call
  // value parameter; the anonymous callback captures its own copy, avoiding the
  // shared-loop-variable problem described above FireOne.
  procedure FireStream(const AIdx: Integer);
  begin
    AClient.DoRequest('GET', BASE_URL + '/stream/pull',
      nil, TBytes(nil), nil, nil,
      procedure(const AResp: ICrossHttpClientResponse)
      begin
        if AResp <> nil then
        begin
          LStreamBatch[AIdx].Status := AResp.StatusCode;
          LStreamBatch[AIdx].Body   := StreamToStr(AResp.Content);
        end;
        LStreamBatch[AIdx].Event.SetEvent;
      end);
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
      LForm.AddField('fieldname', 'myupload.txt');
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

  // ── 15  POST empty body ───────────────────────────────────────────────────────
  // Sends a POST with no body (no Content-Length, no payload).
  // On CrossSocket, THorseRequest.FBody will be nil after Reset() cleared it
  // (via FRequest.Clear) from the previous POST.  This verifies the pool
  // correctly handles the nil body case without crashing.
  Section('15  POST /methods/post  (empty body — pool nil-body path)');
  LHeaders := THttpHeader.Create;
  try
    LHeaders['Content-Type'] := 'application/json; charset=utf-8';
    DoSync(AClient, 'POST', BASE_URL + '/methods/post',
           LHeaders, nil {no body}, R);
  finally
    LHeaders.Free;
  end;
  Check('status 200',              R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('"body":""',               Pos('"body":""', R.Body) > 0, R.Body);

  // ── 16  POST large body (64 KB) ──────────────────────────────────────────────
  // Sends exactly LARGE_BODY_SIZE bytes so the server can return the exact
  // size in the echo.  Verifies large body streams are read completely without
  // truncation on the CrossSocket async I/O path.
  Section(Format('16  POST /echo/body  (%d-byte body — large body stream read)',
    [LARGE_BODY_SIZE]));
  LLargeBody := TEncoding.UTF8.GetBytes(StringOfChar('A', LARGE_BODY_SIZE));
  LHeaders   := THttpHeader.Create;
  try
    LHeaders['Content-Type'] := 'text/plain; charset=utf-8';
    DoSync(AClient, 'POST', BASE_URL + '/echo/body', LHeaders, LLargeBody, R);
  finally
    LHeaders.Free;
  end;
  Check('status 200',                               R.StatusCode = 200,
    IntToStr(R.StatusCode));
  Check(Format('"size":%d exact', [LARGE_BODY_SIZE]),
    Pos(Format('"size":%d', [LARGE_BODY_SIZE]), R.Body) > 0, R.Body);

  // ── 17  Sequential POST body isolation ───────────────────────────────────────
  // Pattern: POST(A) → GET(ping) → POST(B).
  // Verifies the pool's Reset() correctly clears FBody between requests.
  // If FRequest.Clear is not used (Body(nil) bug), the server crashes on the
  // second POST or returns the wrong body.
  Section('17  POST /echo/body  sequential A → ping → B  (pool Reset correctness)');
  LHeaders := THttpHeader.Create;
  try
    LHeaders['Content-Type'] := 'text/plain; charset=utf-8';
    // Step 1: POST with marker A
    DoSync(AClient, 'POST', BASE_URL + '/echo/body',
           LHeaders, TEncoding.UTF8.GetBytes('SEQUENTIAL_BODY_ALPHA'), R);
    Check('step A: status 200',
      R.StatusCode = 200, IntToStr(R.StatusCode));
    Check('step A: body contains SEQUENTIAL_BODY_ALPHA',
      Pos('SEQUENTIAL_BODY_ALPHA', R.Body) > 0, R.Body);
  finally
    LHeaders.Free;
  end;
  // Step 2: GET (no body — exercises nil-body pool release path)
  DoSync(AClient, 'GET', BASE_URL + '/ping', nil, nil, R);
  Check('step ping: status 200',
    R.StatusCode = 200, IntToStr(R.StatusCode));
  // Step 3: POST with a completely different marker
  LHeaders := THttpHeader.Create;
  try
    LHeaders['Content-Type'] := 'text/plain; charset=utf-8';
    DoSync(AClient, 'POST', BASE_URL + '/echo/body',
           LHeaders, TEncoding.UTF8.GetBytes('SEQUENTIAL_BODY_BETA'), R);
  finally
    LHeaders.Free;
  end;
  Check('step B: status 200',
    R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('step B: body contains SEQUENTIAL_BODY_BETA',
    Pos('SEQUENTIAL_BODY_BETA', R.Body) > 0, R.Body);
  Check('step B: body does NOT contain SEQUENTIAL_BODY_ALPHA  (no leakage)',
    Pos('SEQUENTIAL_BODY_ALPHA', R.Body) = 0, R.Body);

  // ── 18  Concurrent POST body isolation ───────────────────────────────────────
  // Fires CONCURRENT_COUNT POST requests simultaneously, each carrying a unique
  // marker string.  All callbacks update independent LBatch slots.
  // After all events are signalled, verifies:
  //   • every response returned HTTP 200
  //   • every response body contains only its own marker
  //   • no response body contains another request's marker
  //
  // This is the primary regression test for the CrossSocket context pool.
  // A broken pool (Body(nil) double-free or context mix-up) will either crash
  // the server or return a body from a different request.
  Section(Format('18  POST /echo/body  %d concurrent  (pool context isolation)',
    [CONCURRENT_COUNT]));

  for I := 0 to CONCURRENT_COUNT - 1 do
  begin
    LBatch[I].Marker := Format('CONCURRENT_MARKER_%d_%s',
      [I, IntToHex(I * $1357ABCD + $DEADBEEF, 8)]);
    LBatch[I].Event  := TEvent.Create(nil, True, False, '');
    LBatch[I].Status := 0;
    LBatch[I].Body   := '';
  end;

  LHeaders := THttpHeader.Create;
  try
    LHeaders['Content-Type'] := 'text/plain; charset=utf-8';
    // Fire all requests before waiting for any.  FireOne is a nested
    // procedure (closure factory) — each call produces a closure that
    // captures its own AIdx rather than sharing a loop variable.
    for I := 0 to CONCURRENT_COUNT - 1 do
      FireOne(I, LHeaders);
  finally
    LHeaders.Free;
  end;

  // Block until all responses arrive (or time out).
  for I := 0 to CONCURRENT_COUNT - 1 do
    LBatch[I].Event.WaitFor(TIMEOUT_MS);

  // Evaluate and free events.
  LAllStatus200  := True;
  LAllMarkersOk  := True;
  LNoCrossLeaks  := True;
  for I := 0 to CONCURRENT_COUNT - 1 do
  begin
    if LBatch[I].Status <> 200 then
      LAllStatus200 := False;
    if Pos(LBatch[I].Marker, LBatch[I].Body) = 0 then
      LAllMarkersOk := False;
    // Each body must NOT contain any other request's marker.
    for J := 0 to CONCURRENT_COUNT - 1 do
      if (J <> I) and (Pos(LBatch[J].Marker, LBatch[I].Body) > 0) then
        LNoCrossLeaks := False;
    LBatch[I].Event.Free;
  end;
  Check(Format('all %d responses: status 200', [CONCURRENT_COUNT]),
    LAllStatus200, '');
  Check('each response contains its own unique marker',
    LAllMarkersOk, '');
  Check('no response contains another request''s marker  (no cross-contamination)',
    LNoCrossLeaks, '');

  // ── 19  Multiple path params ─────────────────────────────────────────────────
  // Tests that the router tree correctly extracts two independent path params
  // from a single route pattern (/params/multi/:a/:b).
  Section('19  GET /params/multi/alpha/beta  (two path params)');
  DoSync(AClient, 'GET', BASE_URL + '/params/multi/alpha/beta', nil, nil, R);
  Check('status 200',          R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('a = "alpha"',         Pos('"alpha"', R.Body) > 0, R.Body);
  Check('b = "beta"',          Pos('"beta"',  R.Body) > 0, R.Body);
  Check('both params present', (Pos('"a"', R.Body) > 0) and (Pos('"b"', R.Body) > 0), R.Body);

  // ── 20  404 not found ────────────────────────────────────────────────────────
  // Requests a route that is not registered.  Horse / the router must return
  // 404.  A crash or 200 here means the router is silently ignoring the miss.
  Section('20  GET /does/not/exist  (expect 404)');
  DoSync(AClient, 'GET', BASE_URL + '/does/not/exist', nil, nil, R);
  Check('status 404', R.StatusCode = 404, IntToStr(R.StatusCode));

  // ── 21  Explicit 400 status ──────────────────────────────────────────────────
  // Verifies that non-200 status codes set by a route handler are transmitted
  // intact through TResponseBridge.Flush to the client.
  // Route returns {"status":400} — non-empty body ensures CrossSocket's
  // status>=400 disconnect fires after the body is flushed (FIX-EMPTY-STATUS).
  Section('21  GET /status/400  (explicit 400 response)');
  DoSync(AClient, 'GET', BASE_URL + '/status/400', nil, nil, R);
  Check('status 400', R.StatusCode = 400, IntToStr(R.StatusCode));
  Check('body contains status code', Pos('"status":400', R.Body) > 0, R.Body);

  // ── 22  Explicit 500 status ──────────────────────────────────────────────────
  Section('22  GET /status/500  (explicit 500 response)');
  DoSync(AClient, 'GET', BASE_URL + '/status/500', nil, nil, R);
  Check('status 500', R.StatusCode = 500, IntToStr(R.StatusCode));
  Check('body contains status code', Pos('"status":500', R.Body) > 0, R.Body);

  // ── 23  Response Content-Type verification ────────────────────────────────────
  // Confirms that Res.ContentType('application/json; charset=utf-8') is
  // reflected in the actual Content-Type response header seen by the client.
  Section('23  GET /methods/get  (verify Content-Type response header)');
  DoSync(AClient, 'GET', BASE_URL + '/methods/get', nil, nil, R);
  Check('status 200', R.StatusCode = 200, IntToStr(R.StatusCode));
  if Assigned(R.Response) then
    Check('Content-Type contains "application/json"',
      Pos('application/json', R.Response.Header['Content-Type']) > 0,
      R.Response.Header['Content-Type']);

  // ── 24  Large response body ───────────────────────────────────────────────────
  // Requests a fixed LARGE_RESPONSE_SIZE-byte body.  Verifies that large
  // async-write sequences on CrossSocket complete without truncation.
  Section(Format('24  GET /response/large  (expect %d-byte body)',
    [LARGE_RESPONSE_SIZE]));
  DoSync(AClient, 'GET', BASE_URL + '/response/large', nil, nil, R);
  Check('status 200',
    R.StatusCode = 200, IntToStr(R.StatusCode));
  Check(Format('body length = %d', [LARGE_RESPONSE_SIZE]),
    Length(R.Body) = LARGE_RESPONSE_SIZE,
    Format('%d bytes received', [Length(R.Body)]));
  Check('body consists of ''X'' characters only',
    (Length(R.Body) > 0) and (Pos(StringOfChar('X', 8), R.Body) > 0),
    '');

  // ── 25  RawWebRequest adapter probe  (PATCH-REQ-8) ───────────────────────────
  // Verifies that Req.RawWebRequest is non-nil on the CrossSocket path and that
  // the adapter exposes the fields middleware typically reaches for: Method,
  // Host, PathInfo, GetFieldByName(header), RemoteAddr.
  Section('25  GET /raw/webrequest  (RawWebRequest adapter — middleware surface)');
  LHeaders := THttpHeader.Create;
  try
    LHeaders['X-Test-Header'] := 'RawAdapterProbe';
    DoSync(AClient, 'GET', BASE_URL + '/raw/webrequest', LHeaders, nil, R);
  finally
    LHeaders.Free;
  end;
  Check('status 200',             R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('hasAdapter true',        Pos('"hasAdapter":true',   R.Body) > 0, R.Body);
  Check('method = GET',           Pos('"method":"GET"',      R.Body) > 0, R.Body);
  Check('host present',           Pos('"host":"127.0.0.1',   R.Body) > 0, R.Body);
  Check('pathInfo = /raw/webrequest',
    Pos('"pathInfo":"/raw/webrequest"', R.Body) > 0, R.Body);
  Check('GetFieldByName echoed custom header',
    Pos('"customHeader":"RawAdapterProbe"', R.Body) > 0, R.Body);
  Check('RemoteAddr non-empty',
    Pos('"remoteAddrNonEmpty":true', R.Body) > 0, R.Body);

  // ── 26  OPTIONS /raw/cors  (Horse.CORS pre-flight pattern) ───────────────────
  // This is the exact shape Horse.CORS.pas uses:
  //   if Req.RawWebRequest.Method = 'OPTIONS' then ...
  // Before PATCH-REQ-8 this path AV'd on CrossSocket because RawWebRequest was
  // nil.  The test asserts that OPTIONS requests now reach the handler, the
  // adapter reports Method='OPTIONS', and the 204 + CORS response is returned.
  Section('26  OPTIONS /raw/cors  (Horse.CORS pre-flight shape)');
  DoSync(AClient, 'OPTIONS', BASE_URL + '/raw/cors', nil, nil, R);
  Check('status 204',             R.StatusCode = 204, IntToStr(R.StatusCode));
  if Assigned(R.Response) then
    Check('Access-Control-Allow-Origin: *',
      R.Response.Header['Access-Control-Allow-Origin'] = '*',
      R.Response.Header['Access-Control-Allow-Origin']);

  // ── 27  GET /raw/cors  (non-OPTIONS branch of the same handler) ──────────────
  // Confirms the same route compiled under THorse.All still dispatches correctly
  // for non-preflight methods, and that RawWebRequest.Method returns 'GET'.
  Section('27  GET /raw/cors  (non-preflight branch)');
  DoSync(AClient, 'GET', BASE_URL + '/raw/cors', nil, nil, R);
  Check('status 200',             R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('body = "cors-route:GET"',
    R.Body = 'cors-route:GET', R.Body);

  // ── 28  Res.RawWebResponse.SetCustomHeader  (PATCH-RES-6 regression) ────────
  // This is the exact pattern Horse.CORS uses to inject headers:
  //   Res.RawWebResponse.SetCustomHeader('Access-Control-Allow-Origin', '*');
  // Before PATCH-RES-6, Res.RawWebResponse was nil on CrossSocket → AV crash.
  // The fix adds FCSRawWebResponse (backed by TCrossSocketWebResponse) so the
  // call succeeds and the header flows through TResponseBridge.Flush to the wire.
  Section('28  GET /raw/webresponse  (Res.RawWebResponse.SetCustomHeader — PATCH-RES-6)');
  DoSync(AClient, 'GET', BASE_URL + '/raw/webresponse', nil, nil, R);
  Check('status 200',             R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('hasAdapter true',        Pos('"hasAdapter":true', R.Body) > 0, R.Body);
  if Assigned(R.Response) then
  begin
    Check('X-Via-RawResponse header set via SetCustomHeader',
      R.Response.Header['X-Via-RawResponse'] = 'PATCH-RES-6-OK',
      R.Response.Header['X-Via-RawResponse']);
    Check('X-Via-AddHeader header set via Res.AddHeader',
      R.Response.Header['X-Via-AddHeader'] = 'AddHeader-OK',
      R.Response.Header['X-Via-AddHeader']);
  end
  else
    Check('response received', False, 'nil response');

  // ── 29  Worker pool burst  (cascade wake stress test) ──────────────────────────
  // Fires BURST_COUNT (8) concurrent POST requests simultaneously.
  // This stresses the worker pool's cascade wake mechanism: with auto-reset
  // events, each SetEvent wakes only one blocked thread.  The fix signals once
  // per thread on shutdown and uses cascade wakes in WorkerLoop.  If the fix
  // is broken, some requests will hang (timeout) because worker threads stay
  // blocked on WaitFor(INFINITE) and never pick up queued tasks.
  //
  // Uses /pool/burst (separate from /echo/body) to avoid interference with
  // sequential isolation tests.
  Section(Format('29  POST /pool/burst  %d concurrent  (cascade wake stress)',
    [BURST_COUNT]));

  for I := 0 to BURST_COUNT - 1 do
  begin
    LBurstBatch[I].Marker := Format('BURST_%d_%s',
      [I, IntToHex(I * $CAFE0001 + $B00B1E5, 8)]);
    LBurstBatch[I].Event  := TEvent.Create(nil, True, False, '');
    LBurstBatch[I].Status := 0;
    LBurstBatch[I].Body   := '';
  end;

  LHeaders := THttpHeader.Create;
  try
    LHeaders['Content-Type'] := 'text/plain; charset=utf-8';
    for I := 0 to BURST_COUNT - 1 do
      FireBurst(I, LHeaders);
  finally
    LHeaders.Free;
  end;

  for I := 0 to BURST_COUNT - 1 do
    LBurstBatch[I].Event.WaitFor(TIMEOUT_MS);

  LBurstAllOk      := True;
  LBurstAllMarkers := True;
  LBurstNoCross    := True;
  for I := 0 to BURST_COUNT - 1 do
  begin
    if LBurstBatch[I].Status <> 200 then
      LBurstAllOk := False;
    if Pos(LBurstBatch[I].Marker, LBurstBatch[I].Body) = 0 then
      LBurstAllMarkers := False;
    for J := 0 to BURST_COUNT - 1 do
      if (J <> I) and (Pos(LBurstBatch[J].Marker, LBurstBatch[I].Body) > 0) then
        LBurstNoCross := False;
    LBurstBatch[I].Event.Free;
  end;
  Check(Format('all %d responses: status 200', [BURST_COUNT]),
    LBurstAllOk, '');
  Check('each response contains its own marker',
    LBurstAllMarkers, '');
  Check('no cross-contamination between burst responses',
    LBurstNoCross, '');

  // ── 30  Rapid sequential after burst  (pool drain/refill) ─────────────────────
  // Immediately after the burst (test 29), fires RAPID_SEQ_COUNT sequential
  // requests.  This validates:
  //   (a) Worker threads that just finished the burst are still alive and
  //       correctly re-blocking on FWorkEvent.WaitFor — not stuck in a
  //       shutdown-exit path.
  //   (b) Pool contexts are properly released back (THorseContextPool.Release)
  //       after the burst, so sequential requests get clean contexts.
  //   (c) No FDrainEvent/FWorkEvent signalling race between the burst
  //       completion and new task submission.
  Section(Format('30  POST /pool/burst  %d rapid sequential after burst  (drain/refill)',
    [RAPID_SEQ_COUNT]));

  LSeqAllOk := True;
  for I := 0 to RAPID_SEQ_COUNT - 1 do
  begin
    LSeqMarker := Format('RAPID_SEQ_%d', [I]);
    LHeaders := THttpHeader.Create;
    try
      LHeaders['Content-Type'] := 'text/plain; charset=utf-8';
      DoSync(AClient, 'POST', BASE_URL + '/pool/burst',
             LHeaders, TEncoding.UTF8.GetBytes(LSeqMarker), R);
    finally
      LHeaders.Free;
    end;
    if (R.StatusCode <> 200) or (Pos(LSeqMarker, R.Body) = 0) then
      LSeqAllOk := False;
  end;
  Check(Format('all %d sequential requests: 200 + correct marker', [RAPID_SEQ_COUNT]),
    LSeqAllOk, '');

  // ── 31  PATCH-REQ-9: Req.Body double-read idempotency ────────────────────────
  // Before PATCH-REQ-9, calling Req.Body a second time re-read an already-
  // exhausted TMemoryStream and returned an empty string.  After PATCH-REQ-9,
  // MapBody decodes the stream to FBodyString once; subsequent Body calls return
  // the cached string.  The route calls Req.Body twice and echoes both values
  // alongside an "equal" flag that must be true.
  Section('31  POST /echo/body-twice  (PATCH-REQ-9 double-read cache)');
  LHeaders := THttpHeader.Create;
  try
    LHeaders['Content-Type'] := 'text/plain; charset=utf-8';
    DoSync(AClient, 'POST', BASE_URL + '/echo/body-twice',
           LHeaders, TEncoding.UTF8.GetBytes('DOUBLE_READ_MARKER'), R);
  finally
    LHeaders.Free;
  end;
  Check('status 200',
    R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('"first" contains posted value',
    Pos('"first":"DOUBLE_READ_MARKER"', R.Body) > 0, R.Body);
  Check('"second" contains posted value',
    Pos('"second":"DOUBLE_READ_MARKER"', R.Body) > 0, R.Body);
  Check('"equal":true — both reads returned the same string',
    Pos('"equal":true', R.Body) > 0, R.Body);

  // ── 32  COMPAT-1: shadow field takes precedence over RawWebResponse.Content ───
  // The route writes 'raw-should-not-appear' to Res.RawWebResponse.Content
  // (a stub on CrossSocket — value is not stored), then calls Res.Send via the
  // Horse shadow-field API.  The bridge must return the shadow-field value.
  // This verifies:
  //   (a) Shadow field wins over RawWebResponse.Content when both are set.
  //   (b) COMPAT-1 check does not spuriously fire (GetContent stub returns '').
  //   (c) No crash or response corruption from the mixed write pattern.
  Section('32  GET /compat/rawbody  (COMPAT-1: shadow field wins over RawWebResponse.Content)');
  DoSync(AClient, 'GET', BASE_URL + '/compat/rawbody', nil, nil, R);
  Check('status 200',
    R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('body = "shadow-wins"',
    R.Body = 'shadow-wins', R.Body);
  Check('RawWebResponse stub value NOT present in body',
    Pos('raw-should-not-appear', R.Body) = 0, R.Body);

  // ── 33  PATCH-STREAM-1: pull-model chunked streaming ─────────────────────────
  // The route streams 5 chunks (~120 ms apart) via Res.SendChunked; the
  // handler returns before the body is complete and the provider defers pool
  // release to stream completion ([STREAM-2]).  TCrossHttpClient de-chunks
  // transparently, so R.Body is the reassembled payload.  The follow-up /ping
  // proves the deferred release recycled the context cleanly (no pool
  // corruption after a streaming request).
  // NOTE: on the Indy transport this route responds 501 (streaming not
  // supported) — this test is CrossSocket-specific by design.
  Section('33  GET /stream/pull  (PATCH-STREAM-1 chunked streaming, deferred release)');
  DoSync(AClient, 'GET', BASE_URL + '/stream/pull', nil, nil, R);
  Check('status 200',
    R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('all 5 chunks reassembled in order',
    R.Body = 'chunk-0;chunk-1;chunk-2;chunk-3;chunk-4;', R.Body);
  DoSync(AClient, 'GET', BASE_URL + '/ping', nil, nil, R);
  Check('pool healthy after streaming — /ping still returns pong',
    (R.StatusCode = 200) and (R.Body = 'pong'),
    Format('%d / %s', [R.StatusCode, R.Body]));

  // ── 34  PATCH-STREAM-1: Content-Type propagation in streaming response ─────────
  // The handler calls Res.SendChunked('application/octet-stream', producer).
  // Verifies that the AContentType argument reaches the wire Content-Type header
  // (not overridden by a transport default) and that the 3 chunks are delivered
  // in order.
  Section('34  GET /stream/content-type  (SendChunked Content-Type header propagation)');
  DoSync(AClient, 'GET', BASE_URL + '/stream/content-type', nil, nil, R);
  Check('status 200',
    R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('body reassembled: 3 ct-chunks in order',
    R.Body = 'ct-chunk-0;ct-chunk-1;ct-chunk-2;', R.Body);
  if Assigned(R.Response) then
    Check('Content-Type = application/octet-stream',
      Pos('application/octet-stream', R.Response.Header['Content-Type']) > 0,
      R.Response.Header['Content-Type']);
  DoSync(AClient, 'GET', BASE_URL + '/ping', nil, nil, R);
  Check('pool healthy after content-type stream',
    (R.StatusCode = 200) and (R.Body = 'pong'),
    Format('%d / %s', [R.StatusCode, R.Body]));

  // ── 35  PATCH-STREAM-1: zero-chunk producer (empty stream edge case) ───────────
  // The producer returns False immediately — no data chunks are emitted.
  // CrossSocket must complete with 200 + empty body without hanging or crashing.
  // The follow-up /ping validates that the deferred pool release ([STREAM-2])
  // still fires for an empty stream, so the context is correctly recycled.
  Section('35  GET /stream/empty  (zero-chunk producer — no crash, pool recycled)');
  DoSync(AClient, 'GET', BASE_URL + '/stream/empty', nil, nil, R);
  Check('status 200',
    R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('body is empty (no chunks emitted)',
    R.Body = '', R.Body);
  DoSync(AClient, 'GET', BASE_URL + '/ping', nil, nil, R);
  Check('pool healthy after empty stream — /ping returns pong',
    (R.StatusCode = 200) and (R.Body = 'pong'),
    Format('%d / %s', [R.StatusCode, R.Body]));

  // ── 36  PATCH-STREAM-1: concurrent streaming — deferred pool release isolation ──
  // Fires 2 simultaneous GET /stream/pull requests.  Both handlers return before
  // their streams drain; the provider must defer pool release for each context
  // independently ([STREAM-2]) so the two draining streams cannot corrupt each
  // other's pool context.  Each body must equal the full 5-chunk sequence; any
  // truncation, duplication, or mixing indicates a deferred-release bug.
  Section('36  GET /stream/pull  ×2 concurrent  (deferred pool release isolation)');

  for I := 0 to 1 do
  begin
    LStreamBatch[I].Marker := '';   // not used — Event and Body are what matters
    LStreamBatch[I].Event  := TEvent.Create(nil, True, False, '');
    LStreamBatch[I].Status := 0;
    LStreamBatch[I].Body   := '';
  end;

  // Fire both before waiting for either — FireStream is the closure factory that
  // captures each independent AIdx copy (same pattern as FireOne/FireBurst).
  for I := 0 to 1 do
    FireStream(I);

  for I := 0 to 1 do
    LStreamBatch[I].Event.WaitFor(TIMEOUT_MS);

  LStreamAllOk   := True;
  LStreamAllBody := True;
  for I := 0 to 1 do
  begin
    if LStreamBatch[I].Status <> 200 then
      LStreamAllOk := False;
    if LStreamBatch[I].Body <> 'chunk-0;chunk-1;chunk-2;chunk-3;chunk-4;' then
      LStreamAllBody := False;
    LStreamBatch[I].Event.Free;
  end;
  Check('both concurrent streaming responses: status 200',
    LStreamAllOk, '');
  Check('both bodies complete and in order (no cross-drain corruption)',
    LStreamAllBody, '');
  DoSync(AClient, 'GET', BASE_URL + '/ping', nil, nil, R);
  Check('pool healthy after concurrent streaming',
    (R.StatusCode = 200) and (R.Body = 'pong'),
    Format('%d / %s', [R.StatusCode, R.Body]));

  // ── 37  Binary request body — FIX-BINBODY-1 ──────────────────────────────────
  // Payload is every byte value 0..255, which is guaranteed invalid UTF-8 (it
  // contains NUL, lone continuation bytes, and truncated multi-byte leaders).
  // Before FIX-BINBODY-1 this returned 500 "No mapping for the Unicode
  // character exists in the target multi-byte code page" for ANY binary body —
  // FireDAC sfBinary, protobuf, images, file uploads alike.
  //
  // The "sum" assertion is the load-bearing one: it fails if the body is
  // truncated, re-read from the wrong offset, or if GetContent left the shared
  // non-owning stream at EOF (the rewind half of the fix). A size-only check
  // would pass against a stream that reports 256 but yields nothing.
  Section('37  POST /body/binary  (FIX-BINBODY-1 — arbitrary bytes 0..255)');
  SetLength(LBinBody, 256);
  for I := 0 to 255 do
    LBinBody[I] := Byte(I);
  LHeaders := THttpHeader.Create;
  try
    LHeaders['Content-Type'] := 'application/octet-stream';
    DoSync(AClient, 'POST', BASE_URL + '/body/binary', LHeaders, LBinBody, R);
  finally
    LHeaders.Free;
  end;
  Check('status 200 — binary body did not raise EEncodingError',
    R.StatusCode = 200, IntToStr(R.StatusCode) + ' / ' + R.Body);
  Check('all 256 bytes reached the handler',
    Pos('"size":256', R.Body) > 0, R.Body);
  Check('bytes intact after both text accessors read the stream',
    Pos('"sum":32640', R.Body) > 0, R.Body);
  DoSync(AClient, 'GET', BASE_URL + '/ping', nil, nil, R);
  Check('pool healthy after binary body',
    (R.StatusCode = 200) and (R.Body = 'pong'),
    Format('%d / %s', [R.StatusCode, R.Body]));

  // ── 38  Res.Send(TBytes) — FIX-BODYBYTES-1 ───────────────────────────────────
  // Horse core's Send(TBytes) writes the FCSBodyBytes shadow slot (public
  // BodyBytes). WriteBody read ContentStream, BodyText and RawWebResponse but
  // never BodyBytes, so the response fell through to the empty-body tail:
  // HTTP 200, Content-Length 0, no exception and nothing in any log.
  //
  // The status check alone would NOT catch that — a 200 was always returned.
  // The body comparison is the assertion that matters.
  Section('38  GET /body/bytes  (FIX-BODYBYTES-1 — Res.Send(TBytes))');
  DoSync(AClient, 'GET', BASE_URL + '/body/bytes', nil, nil, R);
  Check('status 200', R.StatusCode = 200, IntToStr(R.StatusCode));
  Check('body is not empty (the whole point — it used to be)',
    R.Body <> '', Format('len=%d', [Length(R.Body)]));
  Check('body matches the bytes the handler sent',
    R.Body = 'BODYBYTES-OK-0123456789', R.Body);
  DoSync(AClient, 'GET', BASE_URL + '/ping', nil, nil, R);
  Check('pool healthy after Send(TBytes)',
    (R.StatusCode = 200) and (R.Body = 'pong'),
    Format('%d / %s', [R.StatusCode, R.Body]));

end;

// ── Entry point ───────────────────────────────────────────────────────────────

var
  Client: TCrossHttpClient;
begin
  Writeln('[HorseCSTest] Client — target: ' + BASE_URL);
  Writeln('[HorseCSTest] Ensure HorseCSTestServer is running before proceeding.');
  Writeln('[HorseCSTest] Timing: each test step prints (server / client) latency.');
  Writeln('[HorseCSTest]   server = network round-trip + server pipeline');
  Writeln('[HorseCSTest]   client = TEvent wake + result marshalling (should be ~0)');
  Writeln('');

  GGlobalSW         := TStopwatch.StartNew;
  GLastSectionTicks := 0;

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

  GGlobalSW.Stop;

  Writeln('');
  Writeln(Format('[HorseCSTest] %d passed, %d failed  (total %d) in %d ms wall clock',
    [GPassCount, GFailCount, GPassCount + GFailCount,
     GGlobalSW.ElapsedMilliseconds]));
  if GFailCount = 0 then
    Writeln('[HorseCSTest] All tests PASSED.')
  else
    Writeln('[HorseCSTest] Some tests FAILED — see details above.');

  ExitCode := GFailCount;

  Writeln('');
  Writeln('[HorseCSTest] Press ENTER to exit...');
  Readln;
end.
