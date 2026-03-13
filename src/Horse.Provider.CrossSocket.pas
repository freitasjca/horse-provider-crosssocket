unit Horse.Provider.CrossSocket;

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
}

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  //Horse,
  Horse.Exception,
  Horse.Provider.Abstract,
  Net.CrossHttpServer,
  Net.CrossHttpParams,
  Horse.Provider.CrossSocket.Server,
  Horse.Provider.CrossSocket.Pool,
  Horse.Provider.CrossSocket.Request,
  Horse.Provider.CrossSocket.Response,
  Horse.Provider.CrossSocket.WorkerPool,
  Horse.Provider.Config;

type
  THorseProviderCrossSocket = class(THorseProviderAbstract)
  private
    class var FServer: THorseCrossSocketServer;

    class procedure HandleRequest(
      const ACrossReq: ICrossHttpRequest;
      const ACrossRes: ICrossHttpResponse
    );

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
    // THorseProviderAbstract (PATCH-ABS-2) declares ListenWithConfig with
    // exactly this signature as 'virtual'.  Now that the base has a matching
    // virtual slot, 'override' is correct and 'reintroduce' would cause E2037
    // because the compiler finds the matching ancestor declaration and rejects
    // a re-introduction of an identical signature.
    class procedure ListenWithConfig(const APort: Integer;
      const AConfig: THorseCrossSocketConfig); override;

    // [FIX-CS-1] StopListen — matches the base virtual.
    class procedure StopListen; override;

    // [FIX-CS-1] No-param Listen — required by base 'virtual; abstract'.
    // Reads the port from the inherited class var (THorseCore.FPort / THorse.Port).
    class procedure Listen; overload; override;

    // ── Non-virtual convenience overloads ─────────────────────────────────

    // Convenience: sets THorse.Port then calls Listen.
    // NOT an override — just an overload without a base counterpart.
    class procedure Listen(APort: Integer); overload;

    // Direct stop — called by StopListen; also available to external code.
    class procedure Stop;

    class property Server: THorseCrossSocketServer read FServer;
  end;

implementation

uses
  Horse,
  // [FIX-CS-6] THTTPStatus lives in Horse.Commons
  Horse.Commons;

{ THorseProviderCrossSocket }

// ── No-param Listen — base override ──────────────────────────────────────────
class procedure THorseProviderCrossSocket.Listen;
begin
  // THorse.Port is the class var added by PATCH-ABS-3 to THorseProviderAbstract.
  // Callers set it via THorse.Port := N before calling Listen.
  ListenWithConfig(THorse.Port, THorseCrossSocketConfig.Default);
end;

// ── Convenience overload: Listen(APort) ──────────────────────────────────────
class procedure THorseProviderCrossSocket.Listen(APort: Integer);
begin
  ListenWithConfig(APort, THorseCrossSocketConfig.Default);
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

  // [FIX-CS-1a] Assign via the RequestCallback procedure-reference property.
  // FServer.Server.OnRequest is TCrossHttpRequestEvent — a method-of-object
  // event that cannot accept an anonymous procedure directly.
  // THorseCrossSocketServer.InternalOnRequest is the method-of-object bridge
  // (wired to FServer.Server.OnRequest in the constructor); it forwards every
  // call to FRequestCallback, which we set here.
  FServer.RequestCallback :=
    procedure(const Req: ICrossHttpRequest; const Res: ICrossHttpResponse)
    begin
      HandleRequest(Req, Res);
    end;

  FServer.Start(APort);
  DoOnListen;
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
  if Assigned(FServer) then
  begin
    FServer.Stop;     // [SEC-30] waits for drain before returning
    FreeAndNil(FServer);
  end;
  THorseWorkerPool.Finalize;
end;

// ── HandleRequest ─────────────────────────────────────────────────────────────
class procedure THorseProviderCrossSocket.HandleRequest(
  const ACrossReq: ICrossHttpRequest;
  const ACrossRes: ICrossHttpResponse
);
begin
  ExecutePipeline(ACrossReq, ACrossRes);
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

    // ── Pool acquire + full population ──────────────────────────────────────
    Ctx := THorseContextPool.Acquire;
    try

      TRequestBridge.Populate(ACrossReq, Ctx.Request, RejectReason);

      // ── Horse pipeline ────────────────────────────────────────────────────
      try
        // [FIX-CS-3 / PATCH-ABS-3] THorse.Execute(Req, Res) runs the pipeline.
        // Execute is declared on THorseProviderAbstract (PATCH-ABS-3) and calls
        // THorseCore.Routes.Resolve(Req, Res, nil).  THorse inherits it via the
        // THorseProvider → THorseProviderAbstract chain.
        THorse.Execute(Ctx.Request, Ctx.Response);
      except
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
          // [FIX-CS-4b] Assigned() takes a var param; a function-call result
          // is a temporary rvalue, not a variable => E2036. Use a local.
          WorkerPool := THorseWorkerPool.Instance;
          if Assigned(WorkerPool) then
          begin
            // [FIX-CS-4] copy the proc-reference property to a local before invoking
            ErrorHandler := WorkerPool.OnTaskError;
            if Assigned(ErrorHandler) then
              ErrorHandler(E, 0);
          end;
          Ctx.Response.Status(THTTPStatus.InternalServerError);
          Ctx.Response.Send('{"error":"Internal Server Error"}');
          Ctx.Response.ContentType('application/json; charset=utf-8');
        end;
      end;

      TResponseBridge.Flush(Ctx.Response, ACrossRes);

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
  Buf: TBytes;
begin
  ACrossRes.StatusCode  := AStatus;
  ACrossRes.ContentType := 'application/json; charset=utf-8';

  // Minimal security headers even on error responses
  ACrossRes.Header['X-Content-Type-Options'] := 'nosniff';
  ACrossRes.Header['X-Frame-Options']        := 'DENY';
  ACrossRes.Header['Server']                 := 'unknown';
  ACrossRes.Header['Cache-Control']          := 'no-store';

  Buf := TEncoding.UTF8.GetBytes(
    Format('{"error":"%s"}', [StringReplace(AMessage, '"', '\"', [rfReplaceAll])])
  );
  // [FIX-CS-5] ICrossHttpResponse.Send(TBytes) — there is no SendBytes method
  ACrossRes.Send(Buf);
end;

end.
