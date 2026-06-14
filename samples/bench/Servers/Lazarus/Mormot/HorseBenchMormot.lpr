program HorseBenchMormot;

{
  Horse Performance Benchmark Server — mORMot2 transport (Lazarus)
  =================================================================

  Conditional defines (Project → Project Options → Custom Options):
    -dHORSE_PROVIDER_MORMOT

  Project type: Lazarus console program.
  Target: Linux x86_64 Release (primary); also compiles on Windows FPC.

  Ports:
    9003  bare routes (no middleware)
    9013  routes wrapped in RequestGuard + SecurityHeaders (pass --middleware)

  Run sequence:
    ./HorseBenchMormot               ← bare mode (port 9003)
    ./HorseBenchMormot --middleware  ← middleware mode (port 9013)
    ./HorseBenchMormot --async       ← host THttpAsyncServer instead of THttpServer
    ./HorseBenchMormot --httpapi     ← host Windows http.sys (FPC/Windows only)

  Optional flags (pick at most one backend; combine with any mode):
    --async    Hosts mORMot's THttpAsyncServer (non-blocking event loop) instead
               of the default THttpServer thread pool (ServerKind = mskAsync).
    --httpapi  Hosts the Windows http.sys server (THttpApiServer, mskHttpApi).
               FPC/Windows only — the provider raises at Listen elsewhere; needs
               admin rights or: netsh http add urlacl url=http://+:9003/ user=<acct>
               (and :9013 for the middleware port). --httpapi wins over --async.

  Threading model:
    THttpServer (default) uses a thread pool (default 32) — one thread per
    concurrent request. THttpAsyncServer (--async) uses a non-blocking
    epoll (Linux) / IOCP (Windows) / kqueue event loop, scaling past
    thread-per-request; the thread count then sizes async R/W workers.

  Build:
    lazbuild HorseBenchMormot.lpi

  Required search path additions (-Fu):
    ../../../../../horse/src
    ../../../../../horse-provider-mormot/src
    ../../../../../mORMot2/src/core       ← mormot.core.*
    ../../../../../mORMot2/src/net        ← mormot.net.*
    ../../../../../mORMot2/src/lib        ← static libs (if needed)
    ../../../Common                       ← Horse.BenchRoutes
    ../../../../../horse-request-guard/src
    ../../../../../horse-security-headers/src

  Note: --cors is omitted. Horse.CORS uses Web.HTTPApp (WebBroker), which
  is Delphi-only. Use the Delphi mORMot server for CORS profiling.
}

{$MODE DELPHI}{$H+}
{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_MORMOT}

uses
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  SysUtils,
  StrUtils,
  Horse,
  Horse.Provider.Mormot,
  Horse.Provider.Mormot.Config,   // THorseMormotConfig + TMormotServerKind (--async)
  Horse.Middleware.RequestGuard,
  Horse.Middleware.SecurityHeaders,
  Horse.BenchRoutes in '../../../Common/Horse.BenchRoutes.pas';

const
  BASE_PORT = BENCH_PORT_MORMOT_BARE;

var
  GModeBoth:      Boolean;
  GModeGuard:     Boolean;
  GModeHeaders:   Boolean;
  GModeHdrBefore: Boolean;
  GAnyMiddleware: Boolean;
  GModeLabel:     string;
  GPort:          Integer;
  GMaxConn:       Integer;   // --maxconn N  (accepted; no effect on mORMot)
  GListenQueue:   Integer;   // --listenqueue N  (accepted; no effect on mORMot)
  GAsync:         Boolean;   // --async   : host THttpAsyncServer instead of THttpServer
  GHttpApi:       Boolean;   // --httpapi : host Windows http.sys THttpApiServer (Win only)
  GMormotConfig:  THorseMormotConfig;

{$IFDEF UNIX}
procedure HandleStopSignal(ASignal: cint); cdecl;
begin
  THorse.StopListen;
end;
{$ENDIF}

// Headers-before-route middleware as a plain unit-scope procedure — required
// because Lazarus/FPC without HORSE_FPC_FUNCTIONREFERENCES rejects inline
// anonymous procedures. Same shape as Horse.CORS's `CORS` proc.
procedure HeadersBeforeMiddleware(Req: THorseRequest; Res: THorseResponse;
  Next: {$IFDEF FPC}TNextProc{$ELSE}TProc{$ENDIF});
begin
  Res.AddHeader('X-Content-Type-Options', 'nosniff');
  Res.AddHeader('X-Frame-Options', 'DENY');
  Res.AddHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
  Res.AddHeader('Cache-Control', 'no-store');
  Res.AddHeader('Server', 'unknown');
  Next;
end;

function TrimSwitches(const S: string): string;
var
  I: Integer;
begin
  I := 1;
  while (I <= Length(S)) and (S[I] in ['-', '/']) do
    Inc(I);
  Result := Copy(S, I, MaxInt);
end;

function HasSwitch(const ASwitch: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if SameText(TrimSwitches(ParamStr(I)), ASwitch) then
    begin
      Result := True;
      Exit;
    end;
end;

function GetSwitchInt(const ASwitch: string; ADefault: Integer): Integer;
var
  I:   Integer;
  P:   string;
  Pfx: string;
begin
  Result := ADefault;
  Pfx    := ASwitch + '=';
  for I := 1 to ParamCount do
  begin
    P := TrimSwitches(ParamStr(I));
    if (Length(P) > Length(Pfx)) and
       SameText(Copy(P, 1, Length(Pfx)), Pfx) then
    begin
      Result := StrToIntDef(Copy(P, Length(Pfx) + 1, MaxInt), ADefault);
      Exit;
    end;
    if SameText(P, ASwitch) and (I < ParamCount) then
    begin
      Result := StrToIntDef(ParamStr(I + 1), ADefault);
      Exit;
    end;
  end;
end;

begin
  GModeBoth      := HasSwitch('middleware');
  GModeGuard     := HasSwitch('guard-only');
  GModeHeaders   := HasSwitch('headers-only');
  GModeHdrBefore := HasSwitch('headers-before');
  GMaxConn       := GetSwitchInt('maxconn', 0);
  GListenQueue   := GetSwitchInt('listenqueue', 0);
  GAsync         := HasSwitch('async');
  GHttpApi       := HasSwitch('httpapi');
  GAnyMiddleware := GModeBoth or GModeGuard or GModeHeaders or GModeHdrBefore;
  GPort          := BASE_PORT + (BENCH_PORT_MW_OFFSET * Ord(GAnyMiddleware));

  {$IFDEF UNIX}
  fpSignal(SIGTERM, @HandleStopSignal);
  fpSignal(SIGINT,  @HandleStopSignal);
  fpSignal(SIGPIPE, signalhandler(SIG_IGN));  // mORMot handles peer drops internally
  {$ENDIF}

  if GModeBoth or GModeGuard then
    THorse.Use(THorseRequestGuard.New);
  if GModeBoth or GModeHeaders then
    THorse.Use(THorseSecurityHeaders.New);

  if GModeHdrBefore then
    THorse.Use(HeadersBeforeMiddleware);

  if GModeBoth then
    GModeLabel := '+middleware (guard+headers)'
  else if GModeGuard then
    GModeLabel := '+guard-only'
  else if GModeHeaders then
    GModeLabel := '+headers-only'
  else if GModeHdrBefore then
    GModeLabel := '+headers-before'
  else
    GModeLabel := 'bare';

  RegisterBenchRoutes;

  WriteLn(Format('[HorseBench/mORMot·Laz] Listening on http://127.0.0.1:%d  [%s]  server=%s',
    [GPort, GModeLabel,
     IfThen(GHttpApi, 'THttpApiServer (http.sys)',
       IfThen(GAsync, 'THttpAsyncServer', 'THttpServer'))]));
  WriteLn('Active provider class: ' + THorse.ClassName);
  WriteLn('Press Ctrl-C / SIGTERM to stop.');

  // --maxconn N: accepted for flag parity. mORMot uses its own thread-pool
  // model; there is no WebBroker module-pool cap. Value is stored but not
  // forwarded to the transport.
  if GMaxConn > 0 then
  begin
    THorse.MaxConnections := GMaxConn;
    WriteLn(Format('MaxConnections override: %d (accepted; no transport effect on mORMot)',
      [GMaxConn]));
  end;

  // --listenqueue N: Indy-only concept. Accepted for flag parity; ignored here
  // (mORMot owns its own accept loop and thread pool).
  if GListenQueue > 0 then
    WriteLn(Format('ListenQueue %d ignored (only the Indy provider has ListenQueue)',
      [GListenQueue]));

  // --async / --httpapi: select the mORMot backend via THorseMormotConfig.ServerKind.
  // Routes/middleware/bridge are identical — a clean A/B of the backends. http.sys
  // (--httpapi) only works on FPC/Windows; the provider raises at Listen otherwise,
  // and it needs admin rights or a urlacl. --httpapi wins over --async if both set.
  if GHttpApi or GAsync then
  begin
    GMormotConfig := THorseMormotConfig.Default;
    if GHttpApi then
      GMormotConfig.ServerKind := mskHttpApi
    else
      GMormotConfig.ServerKind := mskAsync;
    // Call on the concrete provider type, not THorse: THorseProviderMormot
    // .ListenWithConfig is declared `reintroduce` with a THorseMormotConfig
    // parameter, while the abstract base's virtual version takes a
    // THorseCrossSocketConfig. FPC's overload resolution through the
    // THorse alias picks the inherited virtual one and refuses the call —
    // qualifying with THorseProviderMormot makes the reintroduced method
    // unambiguous. Same behavior as the Delphi HorseBenchMormot.dpr.
    THorseProviderMormot.ListenWithConfig(GPort, GMormotConfig);
  end
  else
    THorse.Listen(GPort);

  WriteLn('[HorseBench/mORMot·Laz] Stopped cleanly.');
end.
