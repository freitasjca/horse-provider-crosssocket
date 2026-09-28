program HorseCSDrainTest;

{$APPTYPE CONSOLE}

{
  Horse + CrossSocket  —  graceful-shutdown drain probe
  =====================================================
  Destination: horse-provider-crosssocket/tests/HorseCSDrainTest.dpr

  Requires HORSE_PROVIDER_CROSSSOCKET in Project Options -> Conditional defines.
  Plain HTTP on port 9232 — no TLS, no certs, nothing to install.
  (mORMot's probe uses 9202, ICS's 9212, the CrossSocket TLS suite 9101.
  NOT 9222: that is the Chrome/Edge DevTools remote-debugging default. See below.)

  ONE QUESTION: when you call StopListenGraceful(N) with a request in flight,
  does that request finish and does its reply reach the client?

  That is the question a graceful shutdown exists to answer, and it is NOT the
  same as "is the call bounded by N". The elapsed time cannot be bounded below
  the remaining work without abandoning the thread running it — IOCP's StopLoop
  asks its IO threads to exit and bounds its own completion drain at 3000 ms, but
  an IO thread inside a 5000 ms handler cannot observe that until the handler
  returns. An earlier version of this probe asserted that bound and scored every
  provider as failing it, which conflated a real defect (the reply is discarded)
  with correct behaviour (teardown waits for handler threads).

  Why it needs asking. THorseProviderAbstract.StopListenGraceful sets the
  shutting-down flag, calls StopListen and never references ATimeoutMS:

      class procedure THorseProviderAbstract.StopListenGraceful(
        const ATimeoutMS: Integer);
      begin
        THorseCore.SetIsShuttingDown(True);
        try
          StopListen;
        finally
          THorseCore.SetIsShuttingDown(False);
        end;
      end;

  Seven internal providers override it — Console, Daemon, FPC.Daemon, FPC.LCL,
  HttpSys, IOCP, VCL. The Console one is the reference: it polls
  GetActiveRequests until zero, bounded by ATimeoutMS. NONE of the three
  external providers (CrossSocket, mORMot, ICS) overrides it, so all three
  inherit the version above — and horse/.agents/AGENTS.md makes the override
  mandatory for any provider that owns the TCP socket.

  Each of those providers does drain, but on its OWN clock: Stop waits
  FConfig.DrainTimeoutMs. So the caller's number is silently replaced by a
  config value, and a caller asking for 30 s may get 5 s, or vice versa.

  Measured 2026-09-24, both 5/5 with a control, both FAILING this assertion:
    mORMot  4200 ms, in-flight response lost at 5012 ms (when the handler ended)
    ICS     4204 ms, in-flight response lost at  816 ms (the instant shutdown began)
  Neither was bounded by its argument OR by its own DrainTimeoutMs, because a
  later teardown step blocks on the very work the timeout was meant to bound.

  ── 2026-09-26/27: INVERTED, and the 404 explained ─────────────────────────
  The first version of this probe ran the SERVER on a worker thread and the
  shutdown on the main thread, and it never measured anything: /ping came back
  404, so it exited VOID.

  THE 404 WAS NOT HORSE. It was not the threading either. The probe was bound to
  port 9222, which is the Chrome/Edge DevTools remote-debugging default, and a
  browser was already listening there. The DevTools HTTP endpoint answers 404 to
  any path it does not recognise, so the probe asked a browser for /ping and
  faithfully reported what it said. Everything that looked like evidence for a
  provider defect was consistent with that: the port was LISTENING, something
  answered, and mORMot (9202), ICS (9212) and this provider's own TLS suite
  (9101) all routed /ping fine — because none of them shares a port with a
  browser. Killing the listener produced a NEW pid immediately, which is what a
  multi-process browser does and what finally gave it away.

  So this probe is now on 9232, and it refuses to start when anything already
  answers on the port (PreflightPortIsFree) rather than testing a stranger.
  WaitReady also requires the body 'pong', not merely a 200: a foreign server
  that happens to return 200 must never be mistaken for ours.

  The thread inversion was kept anyway, on its own merits. The server runs on the
  MAIN thread, which is what the provider is built for — ListenWithConfig parks
  the caller on FStopEvent when IsConsole is True, and the provider's comment
  says why: the block is what keeps RTL finalization from running while IOCP
  threads are alive. It is also the shape every real console Horse app uses, so
  the probe now measures the configuration people actually ship:

      main thread    RegisterRoutes, then ListenWithConfig — which BLOCKS. Stop
                     signals FStopEvent, so the main thread resumes only after
                     the drain.
      driver thread  readiness, the C0 control, the in-flight request, and the
                     StopListenGraceful call being measured.

  Four candidate causes for the 404 are ELIMINATED. Do not re-test them:
    1. A foreign listener on the port — this was it. Guarded now, not diagnosed
       again.
    2. Build paths. build-drain-dcc.bat resolves PROV/ROOT from its own
       directory, so it compiles ..\src and ..\..\horse\src — the same two trees
       build-tls-tests.bat uses. Not a stale- or wrong-source problem.
    3. Host validation (SEC-17). TRequestBridge.Populate rejects a bad Host with
       rvBadRequest, which is 400. It cannot produce a 404.
    4. Multi-Instance resolution. THorseProviderAbstract.Execute picks a router
       by ARequest.RawWebRequest.ServerPort, which looked like a way to reach an
       empty instance router — but GetHorseInstanceByPort falls back to
       GetHorseCoreInstance() when the port is not registered, so the static
       facade's routes are what a plain program gets.

  The counters described under DIAGNOSTICS stay regardless: they cost nothing and
  they are what would have named this in one run instead of two sessions.

  ── TWO MODES ──────────────────────────────────────────────────────────────
  deliver (default)   GET /quick (1500 ms), shutdown fired 800 ms in,
                      StopListenGraceful(4000). The timeout is LONGER than the
                      700 ms of work left, which is the shape Horse's own DUnitX
                      fixture uses for Indy. Two assertions:
                        G1  the reply arrives - 200 + body 'done'
                        G2  the call returns inside its 4000 ms timeout
                      G1 is the regression test for FIX-CS-GRACEFUL-1 and FAILS
                      against the unpatched provider, where CloseAll severs the
                      connection at the shutdown point and the client gets 12152.

  bound               GET /slow (5000 ms), shutdown fired 800 ms in,
                      StopListenGraceful(500) - timeout SHORTER than the work
                      left. REPORT-ONLY: the reply is legitimately abandoned
                      because the timeout expired while work was still running,
                      and the total is expected to exceed the timeout because
                      teardown waits for the handler thread. Run it as
                      `HorseCSDrainTest.exe bound`. The three distances it prints
                      say which of 500 / 3000 / 4200 the elapsed time matches.

  Elapsed time alone never distinguished a delivered reply from a severed one -
  that is why G1 asserts the BODY. A status code cannot carry that, and neither
  can a duration.

  ── DIAGNOSTICS: what a 404 means, from counters ───────────────────────────
  An onRequest hook counts entries into Horse's router and records what it was
  given. The hook fires BEFORE path matching (Horse.Core.RouterTree.pas:418
  wraps GetPathSegments and ExecuteInternal inside it), so its count separates
  "never reached Horse" from "reached Horse, matched nothing":

    pipeline=0                     the request never reached Horse's router.
                                   CrossSocket or the request bridge answered by
                                   itself. Read the status: 400 = Host/SEC-17,
                                   413 = size limit, 404 with pipeline=0 means
                                   CrossSocket answered a route Horse never saw.
    pipeline>0, /ping handler=0,
    hook saw PathInfo '/ping'      the router was handed the right path and did
                                   not match it. A routing defect, and the body
                                   will be Horse's own 'Not Found'.
    pipeline>0, /ping handler=0,
    hook saw something else        PathInfo/segmentation defect — GetPathSegments
                                   delegates to RawPathInfo, which keeps the
                                   FCSPathInfo branch on this provider.
    /ping handler>0 but 404        the handler ran and the reply was lost coming
                                   back: a response-bridge defect, not routing.

  A deliberately unregistered path is requested too, so "everything 404s" and
  "only /ping 404s" are distinguishable rather than guessed at.
}

{$IFNDEF HORSE_PROVIDER_CROSSSOCKET}
  {$MESSAGE FATAL 'Set HORSE_PROVIDER_CROSSSOCKET in Project Options -> Conditional defines'}
{$ENDIF}

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Diagnostics,
  System.Net.HttpClient,
  System.Net.URLClient,
  Horse,
  Horse.Commons,
  Horse.Provider.CrossSocket.Server,
  Horse.Provider.CrossSocket;

const
  PORT            = 9232;
  SLOW_MS         = 5000;   // how long /slow occupies a worker
  DRAIN_CFG_MS    = 3000;   // THorseCrossSocketConfig.DrainTimeoutMs
  STOP_TIMEOUT_MS = 500;    // StopListenGraceful argument in `bound` mode
  SHUTDOWN_AT_MS  = 800;    // how far into the request the shutdown is fired

  // ── G1, the deliver case (default mode) ─────────────────────────────────
  // Timeout LONGER than the work left, which is the shape Horse's own DUnitX
  // fixture uses for Indy (1500 ms handler, StopListenGraceful(4000)) and the
  // only shape in which "graceful" has an observable meaning: the in-flight
  // request finishes and its reply reaches the client.
  QUICK_MS        = 1500;   // /quick occupies a worker for this long
  G1_TIMEOUT_MS   = 4000;   // StopListenGraceful argument for G1
  G1_MARGIN_MS    = 1500;   // slack over (QUICK_MS - SHUTDOWN_AT_MS)
  UNREG_PATH      = '/__never-registered__';

  // The three outcomes the elapsed time can name, as VALUES rather than as
  // windows. Overlapping windows are what made this probe lie — see VerdictFor.
  EXPECT_PARAM_MS = STOP_TIMEOUT_MS;            //  500 — the argument governed
  EXPECT_CFG_MS   = DRAIN_CFG_MS;               // 3000 — the config governed
  EXPECT_FULL_MS  = SLOW_MS - SHUTDOWN_AT_MS;   // 4200 — waited out the request
  NEAREST_TOL_MS  = 400;    // how close to an expectation still counts as it

var
  GLock:       TCriticalSection;
  GFailCount:  Integer = 0;
  GCheckCount: Integer = 0;

  // ── instrumentation (written from CrossSocket's IOCP threads) ────────────
  GPipelineHits:    Integer = 0;
  GPingHits:        Integer = 0;
  GSlowHits:        Integer = 0;
  GQuickHits:       Integer = 0;
  GSeenMethod:      string  = '';
  GSeenPathInfo:    string  = '';
  GSeenRawPathInfo: string  = '';
  GSeenServerPort:  Integer = -1;
  GSeenRawNil:      Boolean = True;

  // ── lifecycle ───────────────────────────────────────────────────────────
  GListenError:    string  = '';
  GListenReturned: Boolean = False;
  GGracefulCalled: Boolean = False;
  GExitCode:       Integer = 0;
  GBoundMode:      Boolean = False;  // argv[1] = 'bound'
  GModeName:       string  = 'deliver';

  // ── observations ────────────────────────────────────────────────────────
  GReadyStatus: Integer = 0;
  GReadyBody:   string  = '';
  GUnregStatus: Integer = 0;
  GUnregBody:   string  = '';
  GSlowStatus:  Integer = 0;
  GSlowBody:    string  = '';
  GSlowError:   string  = '';
  GSlowMs:      Int64   = 0;
  GLastHeaders: string  = '';
  GSlowHeaders: string  = '';

procedure Check(const AName: string; const APassed: Boolean; const ADetail: string);
begin
  Inc(GCheckCount);
  if APassed then
    Writeln(Format('  PASS  %s', [AName]))
  else
  begin
    Writeln(Format('  FAIL  %s', [AName]));
    Writeln(Format('        %s', [ADetail]));
    Inc(GFailCount);
  end;
end;

procedure RegisterRoutes;
begin
  // Counts entries into Horse's router and records what it was handed. Fires
  // before path matching, so its count is the discriminator described above.
  // Guarded, and it must always call Next or every request stalls.
  THorse.AddOnRequest(
    procedure(Req: THorseRequest; Res: THorseResponse; Next: TNextProc)
    begin
      TInterlocked.Increment(GPipelineHits);
      GLock.Enter;
      try
        // `= nil`, not Assigned(): RawWebRequest is a FUNCTION, and Assigned on a
        // function result is ambiguous with testing a function pointer — dcc64
        // answers E2036 "Variable required" and then cascades into bogus
        // overload errors on the route registrations below.
        GSeenRawNil := Req.RawWebRequest = nil;
        if GSeenRawNil then
          GSeenMethod := '(RawWebRequest is nil)'
        else
        begin
          GSeenMethod     := Req.RawWebRequest.Method;
          GSeenServerPort := Req.RawWebRequest.ServerPort;
        end;
        GSeenPathInfo    := Req.PathInfo;
        GSeenRawPathInfo := Req.RawPathInfo;
      finally
        GLock.Leave;
      end;
      if Assigned(Next) then
        Next();
    end);

  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      TInterlocked.Increment(GPingHits);
      Res.Send('pong').Status(THTTPStatus.OK);
    end);

  // G1's route: short enough to finish inside G1_TIMEOUT_MS, long enough that
  // the shutdown is guaranteed to land while it is running.
  THorse.Get('/quick',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      TInterlocked.Increment(GQuickHits);
      Sleep(QUICK_MS);
      Res.Send('done').Status(THTTPStatus.OK);
    end);

  // Occupies a request slot long enough that the shutdown below is guaranteed
  // to find work in flight.
  THorse.Get('/slow',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      TInterlocked.Increment(GSlowHits);
      Sleep(SLOW_MS);
      Res.Send('done').Status(THTTPStatus.OK);
    end);
end;

// AGENTS.md: use System.Net.HttpClient for shutdown/concurrency tests, and send
// Connection: close so the socket is released immediately rather than parked in
// a pool where a later request blocks on a connection the server is tearing down.
function Get(const AUrl: string; ATimeoutMs: Integer; out AStatus: Integer;
  out ABody: string): Boolean;
var
  LClient: THTTPClient;
  LResp:   IHTTPResponse;
  LHdr:    TNameValuePair;
begin
  Result  := False;
  AStatus := 0;
  ABody   := '';
  GLastHeaders := '(no response)';
  LClient := THTTPClient.Create;
  try
    LClient.ConnectionTimeout := ATimeoutMs;
    LClient.ResponseTimeout   := ATimeoutMs;
    LClient.CustomHeaders['Connection'] := 'close';
    try
      LResp   := LClient.Get(AUrl);
      AStatus := LResp.StatusCode;
      ABody   := LResp.ContentAsString;
      // A 200 with an empty body and NO client error means the framing the
      // server sent was self-consistent, so the headers say which framing it
      // chose: Content-Length: 0 means the server built an empty body, a
      // non-zero Content-Length with no bytes would have raised instead, and
      // chunked or close-delimited says the body was simply never written.
      // Guessing between those three is what this captures.
      GLastHeaders := '';
      for LHdr in LResp.Headers do
        GLastHeaders := GLastHeaders + LHdr.Name + ': ' + LHdr.Value + ' | ';
      Result  := True;
    except
      on E: Exception do
        ABody := E.ClassName + ': ' + E.Message;
    end;
  finally
    LClient.Free;
  end;
end;

function Url(const APath: string): string;
begin
  Result := Format('http://127.0.0.1:%d%s', [PORT, APath]);
end;

// The probe must never test a stranger. Nothing of ours is listening yet, so any
// HTTP answer on this port belongs to someone else — and that is not a rare
// accident: the first version of this probe spent two sessions reporting a 404
// that came from a browser's DevTools endpoint on 9222.
function PreflightPortIsFree: Boolean;
var
  LStatus: Integer;
  LBody:   string;
begin
  Result := not Get(Url('/ping'), 600, LStatus, LBody);
  if not Result then
  begin
    Writeln('  VOID  something is ALREADY answering on this port - refusing to test it.');
    Writeln(Format('        GET %s -> status=%d body=%s', [Url('/ping'), LStatus, LBody]));
    Writeln(Format('        Find the owner:   netstat -ano | findstr :%d', [PORT]));
    Writeln('        A NEW pid appearing after you kill it means a multi-process');
    Writeln('        owner - a browser - not a Horse server restarting.');
  end;
end;

// Wait for the server by asking it a question, not by checking the port. A
// bound port does not mean the pipeline is ready to answer. Bails out early if
// the main thread's ListenWithConfig has already failed or returned, so a dead
// server is reported rather than waited out.
function WaitReady(ATries: Integer): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ATries do
  begin
    // Body, not just status: a foreign server returning 200 must never be
    // mistaken for ours. That is the whole lesson of the 9222 collision.
    if Get(Url('/ping'), 1000, GReadyStatus, GReadyBody)
       and (GReadyStatus = 200) and (GReadyBody = 'pong') then
      Exit(True);
    if (GListenError <> '') or GListenReturned then
      Exit(False);
    Sleep(200);
  end;
end;

procedure ReportVoid;
begin
  Writeln('  VOID  server never answered /ping with 200 - nothing was tested.');
  Writeln(Format('        GET /ping            -> status=%d body=%s',
    [GReadyStatus, GReadyBody]));

  // Distinguishes "everything 404s" from "only /ping 404s". Guessing between
  // those two was what stalled the first attempt.
  Get(Url(UNREG_PATH), 1000, GUnregStatus, GUnregBody);
  Writeln(Format('        GET %s -> status=%d body=%s',
    [UNREG_PATH, GUnregStatus, GUnregBody]));

  if GListenError <> '' then
    Writeln(Format('        ListenWithConfig raised: %s', [GListenError]))
  else if GListenReturned then
    Writeln('        ListenWithConfig RETURNED on its own - it did not block, so '
          + 'the server was torn down immediately (IsConsole False?)')
  else
    Writeln('        the main thread is still inside ListenWithConfig, so the '
          + 'server is up and listening');

  Writeln;
  Writeln(Format('        pipeline entries (onRequest hook): %d', [GPipelineHits]));
  Writeln(Format('        /ping handler runs:               %d', [GPingHits]));
  GLock.Enter;
  try
    Writeln(Format('        last request the router saw:      method=%s', [GSeenMethod]));
    Writeln(Format('                                          PathInfo="%s"', [GSeenPathInfo]));
    Writeln(Format('                                          RawPathInfo="%s"', [GSeenRawPathInfo]));
    Writeln(Format('                                          ServerPort=%d  RawWebRequest nil=%s',
      [GSeenServerPort, BoolToStr(GSeenRawNil, True)]));
  finally
    GLock.Leave;
  end;

  Writeln;
  Writeln('        -> reading:');
  if (GPipelineHits = 0) and (GReadyStatus > 0) and (GReadyBody <> 'pong') then
    Writeln('           SOMEONE ELSE ANSWERED. Horse''s router was never entered and '
          + 'the reply is not ours, so the port belongs to another program. Check '
          + 'the owner before reading this as a provider defect.')
  else if GPipelineHits = 0 then
    Writeln('           the request NEVER REACHED Horse''s router. CrossSocket or '
          + 'TRequestBridge.Populate answered it. 400 = Host/SEC-17, 413 = size '
          + 'limit; a 404 here is CrossSocket answering a route Horse never saw.')
  else if GPingHits > 0 then
    Writeln('           the handler RAN and the reply did not arrive intact - a '
          + 'response-bridge defect, not routing.')
  else if GSeenPathInfo = '/ping' then
    Writeln('           the router was handed "/ping" and did not match it. A '
          + 'routing defect; the body should be Horse''s own ''Not Found''.')
  else
    Writeln('           the router was handed a path that is NOT "/ping", so '
          + 'GetPathSegments/RawPathInfo (the FCSPathInfo branch) is the suspect.');
end;

// Which of the three possible bounds explains the elapsed time — by NEAREST
// expectation, not by overlapping windows.
//
// This probe's first classifier used a symmetric +/-1200 ms window around each
// expectation. That window around 3000 reaches 4200 and
// the window around 5000-1200 = 3800 reaches down to 3800, so everything in
// [3800, 4200] matched BOTH and the first branch won by accident. Measured five
// times, the real behaviour never varied by more than 5 ms — yet 4201 ms printed
// "waited out the whole request" and 4200, 4199, 4198 and 4196 ms printed
// "DrainTimeoutMs governed", which is a different and incompatible claim. Four
// of five runs were diagnosed wrong by one millisecond of jitter.
//
// 4200 = 5000 - 800 is the rest of the request, and that is what this measures:
// if DrainTimeoutMs really governed, the call would return at ~3000.
function VerdictFor(const AElapsedMs: Int64): string;
var
  LToParam, LToCfg, LToFull: Int64;
begin
  LToParam := Abs(AElapsedMs - EXPECT_PARAM_MS);
  LToCfg   := Abs(AElapsedMs - EXPECT_CFG_MS);
  LToFull  := Abs(AElapsedMs - EXPECT_FULL_MS);

  if (LToParam <= LToCfg) and (LToParam <= LToFull) and (LToParam <= NEAREST_TOL_MS) then
    Result := Format('the parameter governed (%d ms)', [EXPECT_PARAM_MS])
  else if (LToCfg <= LToFull) and (LToCfg <= NEAREST_TOL_MS) then
    Result := Format('DrainTimeoutMs (%d) governed - the parameter was ignored',
      [EXPECT_CFG_MS])
  else if LToFull <= NEAREST_TOL_MS then
    Result := Format('waited out the rest of the request (%d = %d - %d) - '
                   + 'bounded by NEITHER timeout',
      [EXPECT_FULL_MS, SLOW_MS, SHUTDOWN_AT_MS])
  else
    Result := Format('unexplained: %d ms is near none of %d (arg), %d (config), '
                   + '%d (rest of request)',
      [AElapsedMs, EXPECT_PARAM_MS, EXPECT_CFG_MS, EXPECT_FULL_MS]);
end;

type
  TDriverThread = class(TThread)
  private
    FDone: TEvent;
    procedure RunProbe;
    procedure ReleaseMainThread;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    function WaitForSignal(ATimeoutMs: Cardinal): Boolean;
  end;

constructor TDriverThread.Create;
begin
  FDone := TEvent.Create(nil, True, False, '');
  inherited Create(False);
end;

destructor TDriverThread.Destroy;
begin
  inherited;
  FDone.Free;
end;

function TDriverThread.WaitForSignal(ATimeoutMs: Cardinal): Boolean;
begin
  Result := FDone.WaitFor(ATimeoutMs) = wrSignaled;
end;

// The main thread is parked inside ListenWithConfig and only wakes when Stop
// signals FStopEvent. Every exit path from this thread must therefore stop the
// server, or the process hangs with its results already printed — the one
// failure mode that would make a real finding unreportable.
procedure TDriverThread.ReleaseMainThread;
begin
  if GGracefulCalled or GListenReturned or (GListenError <> '') then
    Exit;
  try
    THorseProviderCrossSocket.StopListen;
  except
    on E: Exception do
      Writeln(Format('   NOTE: forced StopListen raised %s: %s',
        [E.ClassName, E.Message]));
  end;
end;

procedure TDriverThread.RunProbe;
var
  LSlow:      TThread;
  LWatch:     TStopwatch;
  LElapsed:   Int64;
  LRoute:     string;
  LWorkMs:    Integer;
  LTimeout:   Integer;
  LRemaining: Integer;
begin
  if not WaitReady(25) then
  begin
    ReportVoid;
    GExitCode := 2;
    Exit;
  end;

  // ── The scenario ─────────────────────────────────────────────────────────
  // G1 (default) is the DELIVER case: the timeout is longer than the work left,
  // so a correct provider finishes the request and the client gets its reply.
  // That is the assertion that distinguishes a graceful shutdown from a kill,
  // and it is the one the fix is for.
  //
  // `bound` mode is the opposite case — timeout SHORTER than the work left —
  // and it is REPORT-ONLY on purpose. See the note where it prints.
  if GBoundMode then
  begin
    LRoute    := '/slow';
    LWorkMs   := SLOW_MS;
    LTimeout  := STOP_TIMEOUT_MS;
  end
  else
  begin
    LRoute    := '/quick';
    LWorkMs   := QUICK_MS;
    LTimeout  := G1_TIMEOUT_MS;
  end;
  LRemaining := LWorkMs - SHUTDOWN_AT_MS;

  Writeln(Format('  mode: %s - GET %s (%d ms) with StopListenGraceful(%d)',
    [GModeName, LRoute, LWorkMs, LTimeout]));
  Writeln;

  // ── C0, the control ───────────────────────────────────────────────────────
  // Prove /slow works when nobody is shutting the server down. Without this,
  // "the in-flight request failed" is unreadable: a route that never worked and
  // a route killed by shutdown produce the same client error, and the first
  // would make every line below meaningless.
  // C0 uses the MODE'S OWN route, not always /slow. Its job is to prove the
  // exact route this run will exercise answers when nobody is shutting down —
  // which is stronger than proving a different route does — and in deliver mode
  // it drops the run from ~7 s to ~2.5 s, because /slow sleeps 5000 ms and
  // /quick 1500 ms. That matters: characterising a 1-in-20 intermittent needs
  // ~60 runs per arm (0.95^60 = 4.6%), which is 4 minutes at the short route and
  // 12 at the long one.
  Writeln(Format('  control: GET %s with no shutdown in progress...', [LRoute]));
  if not Get(Url(LRoute), LWorkMs * 3, GSlowStatus, GSlowBody) then
  begin
    Writeln(Format('  VOID  %s fails even undisturbed: %s', [LRoute, GSlowBody]));
    Writeln('        Nothing below would mean anything. Fix this first.');
    GExitCode := 2;
    Exit;
  end;
  Check(Format('C0  GET %s completes normally when not shutting down', [LRoute]),
        (GSlowStatus = 200) and (GSlowBody = 'done'),
        Format('status=%d body=%s', [GSlowStatus, GSlowBody]));
  GSlowStatus := 0;
  GSlowBody   := '';
  Writeln;

  // Put one request in flight and leave it there.
  LSlow := TThread.CreateAnonymousThread(
    procedure
    var
      LW: TStopwatch;
    begin
      LW := TStopwatch.StartNew;
      if not Get(Url(LRoute), LWorkMs * 3, GSlowStatus, GSlowBody) then
        GSlowError := GSlowBody;
      GSlowMs      := LW.ElapsedMilliseconds;
      GSlowHeaders := GLastHeaders;
    end);
  LSlow.FreeOnTerminate := False;
  LSlow.Start;
  try
    // Long enough that the handler is certainly inside its Sleep, short enough
    // that it is nowhere near finishing.
    Sleep(SHUTDOWN_AT_MS);

    Writeln('  shutting down with a request in flight...');
    LWatch := TStopwatch.StartNew;
    GGracefulCalled := True;
    THorseProviderCrossSocket.StopListenGraceful(LTimeout);
    LElapsed := LWatch.ElapsedMilliseconds;

    Writeln(Format('  StopListenGraceful(%d) returned after %d ms', [LTimeout, LElapsed]));
    LSlow.WaitFor;

    if GSlowError <> '' then
      Writeln(Format('  in-flight GET %s after %d ms: %s', [LRoute, GSlowMs, GSlowError]))
    else
      Writeln(Format('  in-flight GET %s after %d ms: status=%d body=%s',
        [LRoute, GSlowMs, GSlowStatus, GSlowBody]));
    Writeln(Format('  handler runs: /ping %d | /quick %d | /slow %d | pipeline entries %d',
      [GPingHits, GQuickHits, GSlowHits, GPipelineHits]));
    if GSlowError <> '' then
      Writeln(Format('  NO RESPONSE (the text above is the client exception, %d chars) '
                   + '| headers: %s', [Length(GSlowBody), GSlowHeaders]))
    else
      Writeln(Format('  body length %d | response headers: %s',
        [Length(GSlowBody), GSlowHeaders]));
    Writeln;

    if GBoundMode then
    begin
      // REPORT-ONLY, and the reason matters. Bounding the TOTAL call below the
      // in-flight handler's remaining time would require abandoning the thread
      // running it, which Delphi cannot do safely. IOCP's StopLoop asks its IO
      // threads to exit and bounds its own completion drain at 3000 ms, but an
      // IO thread sitting inside a 5000 ms handler cannot observe that request
      // until the handler returns. So a total of ~(work - shutdown point) is
      // CORRECT behaviour here, not a defect, and asserting otherwise would be
      // inventing a contract no provider can keep.
      //
      // What the timeout legitimately bounds is how long the server waits for a
      // graceful finish before it stops being graceful. This mode records the
      // numbers so that claim stays honest.
      Writeln(Format('  (report-only) elapsed %d ms against a %d ms timeout and %d ms '
                   + 'of work left', [LElapsed, LTimeout, LRemaining]));
      Writeln(Format('  -> %s', [VerdictFor(LElapsed)]));
      Writeln(Format('     distance to %d (arg) %d | %d (config) %d | %d (rest of request) %d',
        [EXPECT_PARAM_MS, Abs(LElapsed - EXPECT_PARAM_MS),
         EXPECT_CFG_MS,   Abs(LElapsed - EXPECT_CFG_MS),
         EXPECT_FULL_MS,  Abs(LElapsed - EXPECT_FULL_MS)]));
      Writeln('  A total above the timeout is expected: teardown waits for the');
      Writeln('  in-flight handler thread to return. The reply is legitimately');
      Writeln('  abandoned here - the timeout expired while work was still running.');
    end
    else
    begin
      // ── The two assertions that matter ───────────────────────────────────
      // G1 is what FIX-CS-GRACEFUL-1 buys, and it FAILS against the unpatched
      // provider: THorseCrossSocketServer.Stop calls TCrossServer.Stop, whose
      // CloseAll closes live CONNECTIONS before the drain wait is reached, so
      // the client is severed at the shutdown point and never sees this body.
      Check('G1  the in-flight reply is DELIVERED when it finishes inside the timeout',
            (GSlowError = '') and (GSlowStatus = 200) and (GSlowBody = 'done'),
            Format('status=%d body=%s err=%s. Unpatched, CloseAll severs the '
                 + 'connection at the shutdown point and this is a 12152.',
                 [GSlowStatus, GSlowBody, GSlowError]));

      // And the wait must not exceed the timeout it was given: the work left
      // (LRemaining) is well inside LTimeout, so a correct drain returns at
      // roughly LRemaining and certainly below LTimeout.
      Check(Format('G2  the drain returned within its %d ms timeout', [LTimeout]),
            LElapsed <= LTimeout,
            Format('elapsed=%d ms with only %d ms of work left - the drain did '
                 + 'not honour its own bound.', [LElapsed, LRemaining]));

      Writeln(Format('     elapsed %d ms | work left at shutdown %d ms | timeout %d ms',
        [LElapsed, LRemaining, LTimeout]));
    end;
  finally
    LSlow.Free;
  end;
end;

procedure TDriverThread.Execute;
begin
  try
    try
      RunProbe;
    except
      on E: Exception do
      begin
        Writeln(Format('  Driver fatal: %s: %s', [E.ClassName, E.Message]));
        GExitCode := 2;
      end;
    end;
  finally
    ReleaseMainThread;
    FDone.SetEvent;
  end;
end;

var
  LDriver: TDriverThread;
  LConfig: THorseCrossSocketConfig;
begin
  // Created first: the onRequest hook runs on CrossSocket's IOCP threads, and
  // ReportVoid reads what it recorded.
  GLock := TCriticalSection.Create;
  try
    GBoundMode := SameText(ParamStr(1), 'bound');
    if GBoundMode then
      GModeName := 'bound';

    Writeln('Horse + CrossSocket  -  graceful-shutdown drain probe');
    Writeln(Format('  DrainTimeoutMs %d ms | mode %s', [DRAIN_CFG_MS, GModeName]));
    Writeln('  server on the MAIN thread, shutdown from a worker - the shape every');
    Writeln('  console Horse app uses, and the one this provider''s TLS suite uses.');
    Writeln;

    // Before anything else: prove the port is ours to use.
    if not PreflightPortIsFree then
    begin
      ExitCode := 2;
      Flush(Output);
      Halt(2);
    end;

    RegisterRoutes;

    LConfig                := THorseCrossSocketConfig.Default;
    LConfig.DrainTimeoutMs := DRAIN_CFG_MS;

    LDriver := TDriverThread.Create;

    // Blocks here until the driver stops the server: IsConsole is True, so
    // ListenWithConfig parks the main thread on FStopEvent and returns only
    // after every IOCP and worker thread has exited.
    try
      THorseProviderCrossSocket.ListenWithConfig(PORT, LConfig);
    except
      // Without this the failure reads as "the server never answered", which
      // names the symptom and hides the cause — a held port, most often.
      on E: Exception do
        GListenError := E.ClassName + ': ' + E.Message;
    end;
    GListenReturned := True;

    // The driver is still printing its results. Bounded, because TThread.WaitFor
    // cannot time out and a hang here would swallow a finding already measured.
    if LDriver.WaitForSignal(4000 + SLOW_MS * 3) then
      LDriver.Free
    else
      // Deliberately NOT freed: TThread.Destroy does Terminate + WaitFor, which
      // cannot time out, so freeing a stuck driver would hang the process right
      // after it printed a result — the exact failure the bounded wait exists to
      // avoid. The process is about to Halt; the leak lasts microseconds.
      Writeln('   NOTE: driver thread still running after the server stopped - '
            + 'not joined, so this result still prints');

    if GListenError <> '' then
    begin
      Writeln;
      Writeln(Format('  VOID  ListenWithConfig failed: %s', [GListenError]));
      Writeln(Format('        Is port %d already held? netstat -ano | findstr :%d',
        [PORT, PORT]));
      GExitCode := 2;
    end;

    Writeln;
    if GCheckCount = 0 then
      Writeln('Results: nothing was scored - see the VOID lines above')
    else
      Writeln(Format('Results: %d passed, %d failed',
        [GCheckCount - GFailCount, GFailCount]));
    if GFailCount > GExitCode then
      GExitCode := GFailCount;
    ExitCode := GExitCode;
    // GLock is deliberately not freed: the driver thread above may not have been
    // joined, and Halt is the next statement. Freeing it here would risk a
    // use-after-free to save a few bytes from a process that is exiting.
    // Halt rather than fall off the end: if any CrossSocket thread is still
    // winding down, a normal exit would block on teardown and turn a reported
    // result into a hang.
    Flush(Output);
    Halt(ExitCode);
  except
    on E: Exception do
    begin
      Writeln('Fatal: ' + E.ClassName + ': ' + E.Message);
      ExitCode := 2;
    end;
  end;
end.
