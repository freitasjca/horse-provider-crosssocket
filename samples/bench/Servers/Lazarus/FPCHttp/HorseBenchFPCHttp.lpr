program HorseBenchFPCHttp;

{
  Horse Performance Benchmark Server — FPC fphttpserver / HTTPApplication transport
  ===================================================================================

  No extra conditional defines needed: omitting HORSE_PROVIDER_CROSSSOCKET causes
  Horse on FPC to use the default fphttpserver / THTTPApplication transport
  (Horse.Provider.FPC.HTTPApplication).  This is the FPC equivalent of the Indy
  Console provider on Delphi — both are the respective compiler's default.

  Project type: Lazarus console program.
  Target: Linux x86_64 Release (primary); also compiles on Windows FPC.

  Ports:
    9007  bare routes (no middleware)
    9017  routes wrapped in RequestGuard + SecurityHeaders (pass --middleware)

  Run sequence:
    ./HorseBenchFPCHttp               ← bare mode (port 9007)
    ./HorseBenchFPCHttp --middleware  ← middleware mode (port 9017)

  Optional flags:
    --listenqueue N   Sets THorse.ListenQueue := N before Listen, which maps to
                      THTTPApplication.QueueSize (TCP accept backlog; default 15).
                      Raise it to >= the concurrency level to avoid connection
                      refusals at the ramp.  e.g. --listenqueue 512
    --maxconn N       Accepted for flag parity; fphttpserver has no module-pool cap
                      analogous to Indy/WebBroker, so this flag is ignored here.

  Threading model:
    fphttpserver with THTTPApplication.Threaded = True allocates one OS thread per
    accepted connection (same model as Indy).  At concurrency = 500 this means
    ~500 OS threads.  This is expected — it is exactly what the benchmark measures
    relative to CrossSocket's fixed IO thread pool.

  Build:
    lazbuild HorseBenchFPCHttp.lpi   (or: fpc ...)
    NO -dHORSE_PROVIDER_CROSSSOCKET.

  Required search path additions in Project Options → Compiler Options → Paths:
    Other unit files (-Fu):
      ../../../../../horse/src
      ../../../Common                           ← Horse.BenchRoutes
      ../../../../../horse-request-guard/src    ← for --middleware / --guard-only
      ../../../../../horse-security-headers/src

  Shutdown:
    Ctrl-C sends SIGINT. Without a custom handler the default disposition terminates
    the process — this is the normal way to stop the bench server. THTTPApplication
    does not expose a public stop API usable from a signal handler.
}

{$MODE DELPHI}{$H+}
{$APPTYPE CONSOLE}
// No HORSE_PROVIDER_CROSSSOCKET — selects FPC's fphttpserver / HTTPApplication

uses
  SysUtils,
  StrUtils,
  Horse,
  Horse.Middleware.RequestGuard,
  Horse.Middleware.SecurityHeaders,
  Horse.BenchRoutes in '../../../Common/Horse.BenchRoutes.pas';

const
  BASE_PORT = BENCH_PORT_FPC_HTTP_BARE;

var
  GModeBoth:      Boolean;   // --middleware     : RequestGuard + SecurityHeaders
  GModeGuard:     Boolean;   // --guard-only     : RequestGuard only
  GModeHeaders:   Boolean;   // --headers-only   : SecurityHeaders only
  GModeHdrBefore: Boolean;   // --headers-before : headers added BEFORE Next
  GAnyMiddleware: Boolean;
  GModeLabel:     string;
  GPort:          Integer;
  GMaxConn:       Integer;   // --maxconn N  (accepted; no effect on fphttpserver)
  GListenQueue:   Integer;   // --listenqueue N  (sets THTTPApplication.QueueSize)

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
  GAnyMiddleware := GModeBoth or GModeGuard or GModeHeaders or GModeHdrBefore;
  GPort          := BASE_PORT + (BENCH_PORT_MW_OFFSET * Ord(GAnyMiddleware));

  if GModeBoth or GModeGuard then
    THorse.Use(THorseRequestGuard.New);
  if GModeBoth or GModeHeaders then
    THorse.Use(THorseSecurityHeaders.New);

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

  WriteLn(Format('[HorseBench/FPCHttp] Listening on http://127.0.0.1:%d  [%s]',
    [GPort, GModeLabel]));
  WriteLn('Active provider class: ' + THorse.ClassName);
  WriteLn('Press Ctrl-C to stop.');

  // --maxconn N: fphttpserver has no module-pool MaxConnections concept.
  // Accepted for flag parity; stored but not forwarded to the transport.
  if GMaxConn > 0 then
  begin
    THorse.MaxConnections := GMaxConn;
    WriteLn(Format('MaxConnections override: %d (accepted; no effect on fphttpserver)',
      [GMaxConn]));
  end;

  // --listenqueue N: sets THorse.ListenQueue which maps to
  // THTTPApplication.QueueSize (TCP accept backlog, default 15).
  // Must be set BEFORE Listen. Raise to >= concurrency to avoid connection
  // refusals, e.g. --listenqueue 512 for a c=500 bombardier run.
  if GListenQueue > 0 then
  begin
    THorse.ListenQueue := GListenQueue;
    WriteLn(Format('ListenQueue override: %d (→ THTTPApplication.QueueSize)', [GListenQueue]));
  end;

  THorse.Listen(GPort);

  WriteLn('[HorseBench/FPCHttp] Stopped cleanly.');
end.
