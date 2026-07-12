unit Horse.Provider.CrossSocket;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

{
  Horse CrossSocket Provider  (hardened)
  =======================================
  Security fixes applied vs previous version
  -------------------------------------------
  [SEC-29] Validation rejection path.
           TRequestBridge.Populate now returns a TRequestValidationResult.
           If validation fails (smuggling, bad Host, disallowed method, etc.)
           the pipeline is NOT invoked — a minimal error response is sent
           directly and the context is never acquired from the pool.
           The previous version called ExecutePipeline unconditionally.

  [SEC-30] Active-request tracking for graceful drain.
           The previous Stop() called FServer.Stop and immediately freed the
           server, cutting off in-flight requests.  This version increments
           a counter when a request enters the pipeline and decrements when
           it exits (via THorseCrossSocketServer.IncrementActive /
           DecrementActive), allowing Stop to wait for all requests to
           complete before returning.

  [SEC-31] Exception in pipeline does NOT leak internal detail to clients.
           The generic Exception handler previously echoed 'Internal Server
           Error' as a plain string.  This version returns a structured JSON
           error body and logs the real exception message through the worker
           pool's OnTaskError mechanism.  Stack traces are never sent to
           clients.

  [SEC-32] Double-start guard.
           If Listen/ListenWithConfig is called while already listening, the
           previous server is cleanly stopped (with drain) before the new one
           starts, preventing port reuse races.

  ── Fix log ─────────────────────────────────────────────────────────────────
  [FIX-CS-1] Listen/Stop signature mismatch (E2137 x2).
             THorseProviderAbstract declares:
               class procedure Listen;            virtual; abstract;
               class procedure StopListen;        virtual;
             Our original provider declared Listen(APort) and Stop, neither
             of which matches the base — E2137 "Method not found in base class".
             Fix: override the no-param Listen and rename Stop→StopListen.
             The convenience overloads Listen(APort) and ListenWithConfig keep
             their port argument but are declared WITHOUT 'override'.
             Stop is kept as a non-virtual public class procedure called by
             StopListen; external callers may also call Stop directly.

  [FIX-CS-2] ListenWithConfig E2037 resolved.
             PATCH-ABS-2 added ListenWithConfig(APort,AConfig) as 'virtual'
             to THorseProviderAbstract with exactly the same signature as our
             override here.  Because the base now provides a matching virtual
             slot, 'override' is the correct keyword.  Using 'reintroduce'
             when a matching virtual exists causes E2037 because the compiler
             finds the ancestor declaration and rejects the re-introduction
             of an identical signature.

  [FIX-CS-3] THorse.Execute undeclared (E2003) + cascades (E2035/E2010/E2036).
             THorseCore (Horse.Core.pas) has NO Execute method — the pipeline
             runner lives on THorse in Horse.pas.  The previous fix incorrectly
             removed the 'THorse.' qualifier, causing E2003 because
             THorseProviderCrossSocket itself also has no Execute.
             Fix: restore THorse.Execute(Ctx.Request, Ctx.Response).
             The E2035 / E2010 / E2036 errors on lines 270/275/284 were
             cascading parse failures from this E2003; they clear automatically.

  [FIX-CS-4] OnTaskError invoked directly as a property (E2036).
             In Delphi, invoking a property whose type is a proc reference
             requires assigning it to a local variable first; calling the
             property directly is E2036 "Variable required".
             Fix: local 'ErrorHandler: TWorkerErrorProc' copies the property
             before the call.

  [FIX-CS-5] SendBytes undeclared (E2003).
             ICrossHttpResponse has no SendBytes method.  The correct overload
             for TBytes is Send(const ABody: TBytes; ...).
             Fix: ACrossRes.Send(Buf) — matches Send(const ABody: TBytes).

  [FIX-CS-6] Cascading type errors on Ctx.Response.Send/Status (E2035/E2010).
             These were downstream of FIX-CS-3; once Execute parses correctly
             the pipeline block compiles cleanly.  Confirmed:
               Ctx.Response.Status(THTTPStatus.X)  — valid (THTTPStatus overload)
               Ctx.Response.Send('string')          — valid (returns THorseResponse,
                                                       result discarded as statement)
             No separate fix required.


  ── Improvement log ─────────────────────────────────────────────────────────
  [BUG-2]  EHorseCallbackInterrupted not caught.
           Horse raises EHorseCallbackInterrupted as the normal signal for
           pipeline completion (when a middleware calls Next with no further
           handlers).  All other Horse providers swallow this silently.
           The previous version let it fall into the generic Exception handler,
           which logged every request as a worker-pool error and sent a 500
           response over the real response.  Fixed by adding an explicit
           on E: EHorseCallbackInterrupted do clause before the generic catch.

  [IMP-3]  HandleRequest was a pointless indirection.
           The private HandleRequest method did nothing but call ExecutePipeline.
           It has been removed; the RequestCallback anonymous procedure calls
           ExecutePipeline directly, eliminating an unnecessary call frame.

  [Config] ServerBanner forwarded to TResponseBridge.Flush.
           The provider passes FServer.Config.ServerBanner to Flush and to
           SendError so the Server: response header reflects the configured
           value (or 'unknown' when empty) on both normal and error responses.
}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes,
  SyncObjs,
{$ELSE}
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
{$ENDIF}
  //Horse,
  Horse.Exception,
  Horse.Provider.Abstract,
  Net.CrossHttpServer,
  Net.CrossHttpParams,
  Horse.Provider.CrossSocket.Server,
  Horse.Provider.CrossSocket.Pool,
  Horse.Provider.CrossSocket.Request,
  Horse.Provider.CrossSocket.Response,
  Horse.Provider.CrossSocket.WebResponseAdapter,
  Horse.Provider.CrossSocket.WorkerPool,
  Horse.Provider.Config;

type
  THorseProviderCrossSocket = class(THorseProviderAbstract)
  private
    class var FServer: THorseCrossSocketServer;
    // CrossSocket owns its own FPort — completely independent of any FPort that
    // may exist in THorseProviderAbstract or in the Console provider.  Class vars
    // on sibling/parent classes are separate storage locations; sharing one would
    // cause silent port-not-changing bugs when both providers are compiled.
    class var FPort: Integer;
    // Bind host set by the Listen overload family (upstream 2026-07 sync).
    // '' or '0.0.0.0' = all interfaces; anything else is passed to
    // THorseCrossSocketServer.Start as the CrossSocket Addr.
    class var FHost: string;
    // Manual-reset event used to block the main thread in Listen (console apps).
    // Created signalled=False; SetEvent is called by Stop/StopListen to unblock.
    class var FStopEvent: TEvent;
    class var FRunning: Boolean;

    class function  GetPort: Integer; static;
    class procedure SetPort(const AValue: Integer); static;

    class procedure ExecutePipeline(
      const ACrossReq: ICrossHttpRequest;
      const ACrossRes: ICrossHttpResponse
    );

    // [SEC-31] Send a minimal, non-leaking error response directly via CrossSocket
    class procedure SendError(
      const ACrossRes: ICrossHttpResponse;
      AStatus:         Integer;
      const AMessage:  string
    );

  public
    // ── Overrides matching THorseProviderAbstract ──────────────────────────

    // [FIX-CS-2] ListenWithConfig — override.
    class procedure ListenWithConfig(const APort: Integer;
      const AConfig: THorseCrossSocketConfig); override;

    // [FIX-CS-1] StopListen — matches the base virtual.
    class procedure StopListen; override;

    // [FIX-CS-1] No-param Listen — required by base 'virtual; abstract'.
    class procedure Listen; overload; override;

    // ── Non-virtual convenience overloads ─────────────────────────────────

    // Listen overload family — signatures mirror the Console provider.
    // Required since the 2026-07 upstream sync: Horse.Instance
    // (THorseInstance.Listen) calls the 4-argument form directly.
    class procedure Listen(const APort: Integer; const AHost: string = '0.0.0.0'; const ACallbackListen: TProc = nil; const ACallbackStopListen: TProc = nil); reintroduce; overload; static;
    class procedure Listen(const APort: Integer; const ACallbackListen: TProc; const ACallbackStopListen: TProc = nil); reintroduce; overload; static;
    class procedure Listen(const AHost: string; const ACallbackListen: TProc = nil; const ACallbackStopListen: TProc = nil); reintroduce; overload; static;
    class procedure Listen(const ACallbackListen: TProc; const ACallbackStopListen: TProc = nil); reintroduce; overload; static;

    // Direct stop — called by StopListen; also available to external code.
    class procedure Stop;

    // Port — CrossSocket's own storage; set by ListenWithConfig; read by no-arg Listen.
    // Shadows the Port property that THorseProviderAbstract previously declared
    // (Abstract no longer declares it — see patches/horse/src/Horse.Provider.Abstract.pas).
    class property Port: Integer read GetPort write SetPort;

    class property Server: THorseCrossSocketServer read FServer;
  end;

implementation

uses
  Horse,
  // [FIX-CS-6] THTTPStatus lives in Horse.Commons
  Horse.Commons,
  // DEFAULT_PORT = 9000 — matches the Console provider fallback
  Horse.Constants,
  // [BUG-2] EHorseCallbackInterrupted — the normal pipeline-end signal
  Horse.Exception.Interrupted;

{ THorseProviderCrossSocket }

// ── Port accessors ────────────────────────────────────────────────────────────
class function THorseProviderCrossSocket.GetPort: Integer;
begin
  Result := FPort;
end;

class procedure THorseProviderCrossSocket.SetPort(const AValue: Integer);
begin
  FPort := AValue;
end;

// ── No-param Listen — base override ──────────────────────────────────────────
class procedure THorseProviderCrossSocket.Listen;
var
  LPort: Integer;
begin
  // Read CrossSocket's own FPort (set by a prior ListenWithConfig or Listen(APort)
  // call).  Fall back to DEFAULT_PORT (9000) when FPort has never been assigned,
  // mirroring the Console provider's behaviour.
  LPort := FPort;
  if LPort <= 0 then
    LPort := DEFAULT_PORT;
  ListenWithConfig(LPort, THorseCrossSocketConfig.Default);
end;

// ── Listen overload family ────────────────────────────────────────────────────
// Master overload: stores host + lifecycle callbacks, then starts with the
// default config. DoOnListen (fired inside ListenWithConfig) invokes the
// just-set ACallbackListen; DoOnStopListen fires from StopListen.
class procedure THorseProviderCrossSocket.Listen(const APort: Integer; const AHost: string; const ACallbackListen, ACallbackStopListen: TProc);
begin
  FHost := AHost;
  SetOnListen(ACallbackListen);
  SetOnStopListen(ACallbackStopListen);
  ListenWithConfig(APort, THorseCrossSocketConfig.Default);
end;

class procedure THorseProviderCrossSocket.Listen(const APort: Integer; const ACallbackListen, ACallbackStopListen: TProc);
begin
  Listen(APort, FHost, ACallbackListen, ACallbackStopListen);
end;

class procedure THorseProviderCrossSocket.Listen(const AHost: string; const ACallbackListen, ACallbackStopListen: TProc);
var
  LPort: Integer;
begin
  LPort := FPort;
  if LPort <= 0 then
    LPort := DEFAULT_PORT;
  Listen(LPort, AHost, ACallbackListen, ACallbackStopListen);
end;

class procedure THorseProviderCrossSocket.Listen(const ACallbackListen, ACallbackStopListen: TProc);
begin
  Listen(FHost, ACallbackListen, ACallbackStopListen);
end;

// ── ListenWithConfig ─────────────────────────────────────────────────────────
class procedure THorseProviderCrossSocket.ListenWithConfig(
  const APort:   Integer;
  const AConfig: THorseCrossSocketConfig
);
begin
  // [SEC-32] Drain and stop any existing listener before starting a new one
  if Assigned(FServer) then
    Stop;

  THorseWorkerPool.Initialize;

  FServer := THorseCrossSocketServer.Create(AConfig);

  // [IMP-3] Assign directly to ExecutePipeline — HandleRequest was a
  // pointless wrapper that did nothing but forward the call.
  FServer.RequestCallback :=
    procedure(const Req: ICrossHttpRequest; const Res: ICrossHttpResponse)
    begin
      ExecutePipeline(Req, Res);
    end;

  // Keep our own FPort in sync so the no-arg Listen correctly re-uses the
  // port on a restart.  We write directly to FPort (CrossSocket's own class
  // var) — not to THorseProviderAbstract's Port, which no longer exists after
  // the Abstract patch removed it.
  FPort := APort;

  FServer.Start(APort, FHost);
  DoOnListen;

  // Block the main thread when running as a console application so the
  // program does not fall through to `end.` and trigger RTL finalization
  // while IOCP threads are still alive.  Matches the Console/Indy
  // provider's 'while FRunning do GetDefaultEvent.WaitFor' pattern.
  //
  // When IsConsole is False (VCL, service, LCL) the caller's own message
  // loop or service dispatcher keeps the process alive — no blocking needed.
  //
  // Stop sets FRunning := False, joins all threads, THEN signals FStopEvent.
  // The main thread wakes only after every IOCP and worker thread has exited,
  // so finalization runs against a fully quiescent process.
  if IsConsole then
  begin
    FRunning := True;
    if not Assigned(FStopEvent) then
      FStopEvent := TEvent.Create(nil, True, False, '');
    while FRunning do
      FStopEvent.WaitFor(INFINITE);
    FreeAndNil(FStopEvent);
  end;
end;

// ── StopListen — base override ────────────────────────────────────────────────
class procedure THorseProviderCrossSocket.StopListen;
begin
  Stop;
  DoOnStopListen;
end;

// ── Stop ─────────────────────────────────────────────────────────────────────
class procedure THorseProviderCrossSocket.Stop;
begin
  FRunning := False;

  if Assigned(FServer) then
  begin
    FServer.Stop;     // [SEC-30] waits for drain before returning
    FreeAndNil(FServer);
  end;
  THorseWorkerPool.Finalize;

  // Unblock the main thread (ListenWithConfig is waiting on FStopEvent)
  if Assigned(FStopEvent) then
  begin
    FStopEvent.SetEvent;
    // Do NOT free FStopEvent here — ListenWithConfig is still in its
    // WaitFor loop and needs to see FRunning = False after the wake.
  end;
end;

// ── ExecutePipeline ───────────────────────────────────────────────────────────
class procedure THorseProviderCrossSocket.ExecutePipeline(
  const ACrossReq: ICrossHttpRequest;
  const ACrossRes: ICrossHttpResponse
);
var
  Ctx:          THorseContext;
  ValResult:    TRequestValidationResult;
  RejectReason: string;
  // [FIX-CS-4] local copy of the proc-reference property avoids E2036
  ErrorHandler: TWorkerErrorProc;
  // [FIX-CS-4b] local to avoid passing a function-call rvalue to Assigned(var)
  WorkerPool:   THorseWorkerPool;
  Banner:       string;
begin
  // [SEC-30] Track this request for graceful-drain accounting
  if Assigned(FServer) then
    FServer.IncrementActive;

  try

    // ── [SEC-29] Validate BEFORE touching the pool ──────────────────────────
    ValResult := TRequestBridge.Populate(ACrossReq, nil {probe-only}, RejectReason);

    if ValResult <> rvOK then
    begin
      case ValResult of
        rvMethodNotAllowed:
          SendError(ACrossRes, 405, 'Method Not Allowed');
        rvBadRequest:
          SendError(ACrossRes, 400, 'Bad Request');
      else
        SendError(ACrossRes, 400, 'Bad Request');
      end;
      Exit;
    end;

    // Capture banner once — used for both normal and error responses
    if Assigned(FServer) then
      Banner := FServer.Config.ServerBanner
    else
      Banner := '';

    // ── Pool acquire + full population ──────────────────────────────────────
    Ctx := THorseContextPool.Acquire;
    try

      TRequestBridge.Populate(ACrossReq, Ctx.Request, RejectReason);

      // PATCH-RES-6 — Create the RawWebResponse adapter so middleware that
      // calls Res.RawWebResponse.SetCustomHeader (e.g. Horse.CORS) gets a
      // non-nil TWebResponse backed by ICrossHttpResponse.
      // Ownership transfers to THorseResponse; freed by Clear on pool release.
      Ctx.Response.SetCSRawWebResponse(
        TCrossSocketWebResponse.Create(ACrossRes));

      // ── Horse pipeline ────────────────────────────────────────────────────
      try
        // [FIX-CS-3 / PATCH-ABS-3] THorse.Execute(Req, Res) runs the pipeline.
        THorse.Execute(Ctx.Request, Ctx.Response);
      except
        // [BUG-2] EHorseCallbackInterrupted is Horse's normal pipeline-end
        // signal — raised by NextCaller when the middleware chain is exhausted.
        // Swallow silently; the response has already been populated.
        on EHorseCallbackInterrupted do
          ; // normal completion — do nothing

        on E: EHorseException do
        begin
          Ctx.Response.Status(E.Status);
          // [SEC-31] App-controlled message — safe to relay
          Ctx.Response.Send(Format('{"error":"%s"}', [E.Message]));
          Ctx.Response.ContentType('application/json; charset=utf-8');
        end;
        on E: Exception do
        begin
          // [SEC-31] Log internally — NEVER leak stack or detail to client
          WorkerPool := THorseWorkerPool.Instance;
          if Assigned(WorkerPool) then
          begin
            // [FIX-CS-4] copy proc-reference property to a local before invoking
            ErrorHandler := WorkerPool.OnTaskError;
            if Assigned(ErrorHandler) then
              ErrorHandler(E, 0);
          end;
          Ctx.Response.Status(THTTPStatus.InternalServerError);
          Ctx.Response.Send('{"error":"Internal Server Error"}');
          Ctx.Response.ContentType('application/json; charset=utf-8');
        end;
      end;

      // [Config] Pass ServerBanner so the Server: header reflects the config
      TResponseBridge.Flush(Ctx.Response, ACrossRes, Banner);

    finally
      THorseContextPool.Release(Ctx);
    end;

  finally
    // [SEC-30] Always decrement — even on validation reject or exception
    if Assigned(FServer) then
      FServer.DecrementActive;
  end;
end;

// ── [SEC-31] SendError ────────────────────────────────────────────────────────
class procedure THorseProviderCrossSocket.SendError(
  const ACrossRes: ICrossHttpResponse;
  AStatus:         Integer;
  const AMessage:  string
);
var
  Buf:    TBytes;
  Banner: string;
begin
  ACrossRes.StatusCode  := AStatus;
  ACrossRes.ContentType := 'application/json; charset=utf-8';

  // [Config] Apply ServerBanner from server config on error responses too
  if Assigned(FServer) and (FServer.Config.ServerBanner <> '') then
    Banner := FServer.Config.ServerBanner
  else
    Banner := 'unknown';

  ACrossRes.Header['X-Content-Type-Options'] := 'nosniff';
  ACrossRes.Header['X-Frame-Options']        := 'DENY';
  ACrossRes.Header['Server']                 := Banner;
  ACrossRes.Header['Cache-Control']          := 'no-store';

  Buf := TEncoding.UTF8.GetBytes(
    Format('{"error":"%s"}', [StringReplace(AMessage, '"', '\"', [rfReplaceAll])])
  );
  // [FIX-CS-5] ICrossHttpResponse.Send(TBytes) — there is no SendBytes method
  ACrossRes.Send(Buf);
end;

end.
