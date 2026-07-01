program HorseBenchMormot;

{
  Horse Performance Benchmark Server — mORMot2 transport
  =======================================================

  Conditional defines (Project → Options → Conditional Defines):
    HORSE_PROVIDER_MORMOT

  Project type: Console Application.
  Target: Win64 Release.

  Ports:
    9003  bare routes (no middleware)
    9013  routes wrapped in RequestGuard + SecurityHeaders (pass --middleware)

  Run sequence:
    HorseBenchMormot.exe            ← bare mode (port 9003)
    HorseBenchMormot.exe --middleware  ← middleware mode (port 9013)
    HorseBenchMormot.exe --async    ← host THttpAsyncServer instead of THttpServer
    HorseBenchMormot.exe --httpapi  ← host Windows http.sys (THttpApiServer)

  Optional flags (pick at most one backend; combine with any mode):
    --async    Hosts mORMot's THttpAsyncServer (non-blocking event loop) instead
               of the default THttpServer thread pool, via
               THorseMormotConfig.ServerKind = mskAsync. e.g. --async --headers-only.
    --httpapi  Hosts the Windows http.sys kernel-mode server (THttpApiServer,
               ServerKind = mskHttpApi). WINDOWS ONLY — the provider raises at
               Listen elsewhere. Needs Administrator rights or a one-time
               urlacl:  netsh http add urlacl url=http://+:9003/ user=<account>
               (and :9013 for the middleware port). If both --httpapi and --async
               are given, --httpapi wins.

  Threading model:
    THttpServer (default) uses a thread pool (default 32) — one thread per
    concurrent request. THttpAsyncServer (--async) uses a non-blocking IOCP
    (Windows) / epoll (Linux) / kqueue event loop, scaling past thread-per-
    request; its thread count then sizes the async R/W workers, not clients.

  Required search path entries (Project → Options → Library path):
    <mormot2-repo>\src\...           (mORMot2 source tree)
    <horse-provider-mormot-repo>\src
    <horse-request-guard-repo>\src   (only needed for --middleware mode)
    <horse-security-headers-repo>\src (only needed for --middleware mode)
}

{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_MORMOT}

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  System.SysUtils,
  System.StrUtils,
  Horse,
  Horse.Provider.Mormot,
  Horse.Provider.Mormot.Config,   // THorseMormotConfig + TMormotServerKind (--async)
  Horse.Middleware.RequestGuard,
  Horse.Middleware.SecurityHeaders,
  Horse.CORS,
  Horse.BenchRoutes in '..\..\Common\Horse.BenchRoutes.pas';

const
  BASE_PORT = BENCH_PORT_MORMOT_BARE;

var
  GModeBoth:      Boolean;   // --middleware     : RequestGuard + SecurityHeaders
  GModeGuard:     Boolean;   // --guard-only     : RequestGuard only
  GModeHeaders:   Boolean;   // --headers-only   : SecurityHeaders only
  GModeHdrBefore: Boolean;   // --headers-before : same 5 headers, added BEFORE Next
  GModeCors:      Boolean;   // --cors           : Horse.CORS (SetCustomHeader path)
  GAnyMiddleware: Boolean;
  GModeLabel:     string;
  GPort:          Integer;
  GMaxConn:       Integer;   // --maxconn N : THorse.MaxConnections override (0 = leave default)
  GListenQueue:   Integer;   // --listenqueue N : accepted for parity; Indy-only (ignored here)
  GAsync:         Boolean;   // --async   : host THttpAsyncServer instead of THttpServer
  GHttpApi:       Boolean;   // --httpapi : host Windows http.sys THttpApiServer (Win only)
  GTls:           Boolean;   // --tls   : listen HTTPS on BASE_PORT + BENCH_PORT_TLS_OFFSET
  GMtls:          Boolean;   // --mtls  : require + verify a client cert (implies --tls)

{$IFDEF MSWINDOWS}
function CtrlHandler(dwCtrlType: DWORD): BOOL; stdcall;
begin
  case dwCtrlType of
    CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT,
    CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT:
      begin
        THorse.StopListen;
        Result := True;
      end;
  else
    Result := False;
  end;
end;
{$ENDIF}

function HasSwitch(const ASwitch: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if SameText(ParamStr(I).TrimLeft(['-', '/']), ASwitch) then
      Exit(True);
end;

{ Reads an integer-valued switch in either form: "--maxconn 256" (value in the
  next param) or "--maxconn=256". Returns ADefault when absent or unparseable. }
function GetSwitchInt(const ASwitch: string; const ADefault: Integer): Integer;
var
  I: Integer;
  P: string;
begin
  Result := ADefault;
  for I := 1 to ParamCount do
  begin
    P := ParamStr(I).TrimLeft(['-', '/']);
    if P.StartsWith(ASwitch + '=', True) then
      Exit(StrToIntDef(Copy(P, Length(ASwitch) + 2, MaxInt), ADefault));
    if SameText(P, ASwitch) and (I < ParamCount) then
      Exit(StrToIntDef(ParamStr(I + 1), ADefault));
  end;
end;

{ Locate the TLS fixture certs (samples/bench/certs/, or a parent) for --tls. }
function CertPath(const AName: string): string;
const
  CANDIDATES: array[0..3] of string = (
    'certs', '..\certs', '..\..\certs', '..\..\..\certs');
var
  LBase, LCand: string;
  I: Integer;
begin
  LBase := ExtractFilePath(ParamStr(0));
  for I := Low(CANDIDATES) to High(CANDIDATES) do
  begin
    LCand := LBase + CANDIDATES[I] + PathDelim;
    if FileExists(LCand + 'server.crt') then
      Exit(LCand + AName);
  end;
  Result := 'certs' + PathDelim + AName;
end;

begin
  GModeBoth      := HasSwitch('middleware');
  GModeGuard     := HasSwitch('guard-only');
  GModeHeaders   := HasSwitch('headers-only');
  GModeHdrBefore := HasSwitch('headers-before');
  GModeCors      := HasSwitch('cors');
  GMaxConn       := GetSwitchInt('maxconn', 0);
  GListenQueue   := GetSwitchInt('listenqueue', 0);
  GAsync         := HasSwitch('async');
  GHttpApi       := HasSwitch('httpapi');
  GMtls          := HasSwitch('mtls');
  GTls           := GMtls or HasSwitch('tls');
  GAnyMiddleware := GModeBoth or GModeGuard or GModeHeaders or GModeHdrBefore or GModeCors;
  if GTls then
    GPort := BASE_PORT + BENCH_PORT_TLS_OFFSET
  else
    GPort := BASE_PORT + (BENCH_PORT_MW_OFFSET * Ord(GAnyMiddleware));

  {$IFDEF MSWINDOWS}
  SetConsoleCtrlHandler(@CtrlHandler, True);
  {$ENDIF}

  // A/B isolation: --guard-only and --headers-only register a single middleware
  // each so the per-request cost can be attributed to one unit. Order for the
  // combined mode is unchanged (RequestGuard then SecurityHeaders).
  if GModeBoth or GModeGuard then
    THorse.Use(THorseRequestGuard.New);
  if GModeBoth or GModeHeaders then
    THorse.Use(THorseSecurityHeaders.New);

  // --headers-before: SAME 5 headers as SecurityHeaders defaults, but added
  // BEFORE Next (before the route calls Send) instead of after. A/B against
  // --headers-only isolates whether the post-Send mutation is the trigger.
  if GModeHdrBefore then
    THorse.Use(
      procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
      begin
        Res.AddHeader('X-Content-Type-Options', 'nosniff');
        Res.AddHeader('X-Frame-Options', 'DENY');
        Res.AddHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
        Res.AddHeader('Cache-Control', 'no-store');
        Res.AddHeader('Server', 'unknown');
        Next;
      end);

  // --cors: Horse.CORS adds ~5 response headers via Res.RawWebResponse.SetCustomHeader
  // -- a DIFFERENT code path than SecurityHeaders' Res.AddHeader. Tests whether the
  // keep-alive defect covers the whole response-header path or only AddHeader.
  if GModeCors then
  begin
    // Configure CORS (fluent builder sets module-level globals; it returns a
    // HorseCORSConfig record, NOT a callback -- do NOT wrap it in THorse.Use).
    HorseCORS
      .AllowedOrigin('*')
      .AllowedMethods('GET,POST,PUT,DELETE,PATCH')
      .AllowedHeaders('*');
    THorse.Use(CORS);   // CORS is the actual middleware procedure
  end;

  if GModeBoth then
    GModeLabel := '+middleware (guard+headers)'
  else if GModeGuard then
    GModeLabel := '+guard-only'
  else if GModeHeaders then
    GModeLabel := '+headers-only'
  else if GModeHdrBefore then
    GModeLabel := '+headers-before'
  else if GModeCors then
    GModeLabel := '+cors'
  else
    GModeLabel := 'bare';

  RegisterBenchRoutes;

  if GTls then
    GModeLabel := GModeLabel + IfThen(GMtls, '+mtls', '+tls');

  WriteLn(Format('[HorseBench/mORMot] Listening on %s://127.0.0.1:%d  [%s]  server=%s',
    [IfThen(GTls, 'https', 'http'), GPort, GModeLabel,
     IfThen(GHttpApi, 'THttpApiServer (http.sys)',
       IfThen(GAsync, 'THttpAsyncServer', 'THttpServer'))]));
  WriteLn('Active provider class: ' + THorse.ClassName);
  WriteLn('Press Ctrl-C to stop.');

  // --maxconn N: accepted for parity with the Indy server. On mORMot the value
  // is stored but NOT forwarded to the transport (mORMot's THttpServer uses its
  // own thread-pool model), so it has no effect here — mORMot has no WebBroker
  // module-pool cap. 0 = leave default.
  if GMaxConn > 0 then
  begin
    THorse.MaxConnections := GMaxConn;
    WriteLn(Format('MaxConnections override: %d (accepted; no transport effect on mORMot)', [GMaxConn]));
  end;

  // --listenqueue N: Indy-only (THorse.ListenQueue exists only on the Console/Indy
  // provider). The guard disables it under HORSE_PROVIDER_MORMOT; the flag is
  // accepted but ignored here (mORMot owns its own accept loop / thread pool).
  if GListenQueue > 0 then
  begin
    {$IF NOT DEFINED(HORSE_PROVIDER_CROSSSOCKET) AND NOT DEFINED(HORSE_PROVIDER_MORMOT)}
    THorse.ListenQueue := GListenQueue;
    WriteLn(Format('ListenQueue override: %d', [GListenQueue]));
    {$ELSE}
    WriteLn(Format('ListenQueue %d ignored (only the Indy provider has ListenQueue)', [GListenQueue]));
    {$IFEND}
  end;

  // --async / --httpapi: select the mORMot backend at runtime via
  // THorseMormotConfig.ServerKind. Routes/middleware/bridge are identical, so
  // this is a clean A/B of the backends. --httpapi (http.sys) is Windows-only —
  // the provider raises at Listen on other platforms, and needs admin rights or
  // a urlacl (netsh http add urlacl url=http://+:<port>/ user=<acct>).
  // --tls folds into the same config path. TLS applies to the socket backends
  // (default thread-pool, --async); --tls + --httpapi is rejected by the provider
  // (http.sys binds its cert via netsh, not THorseMormotConfig).
  if GHttpApi or GAsync or GTls then
  begin
    var LConfig := THorseMormotConfig.Default;
    if GHttpApi then
      LConfig.ServerKind := mskHttpApi
    else if GAsync then
      LConfig.ServerKind := mskAsync;
    if GTls then
    begin
      LConfig.SSLEnabled     := True;
      LConfig.SSLCertFile    := CertPath('server.crt');
      LConfig.SSLPrivKeyFile := CertPath('server.key');
      if GMtls then
      begin
        LConfig.SSLCACertFile := CertPath('ca.crt');
        LConfig.SSLVerifyPeer := True;
      end;
    end;
    THorse.ListenWithConfig(GPort, LConfig);
  end
  else
    THorse.Listen(GPort);

  WriteLn('[HorseBench/mORMot] Stopped cleanly.');
end.
