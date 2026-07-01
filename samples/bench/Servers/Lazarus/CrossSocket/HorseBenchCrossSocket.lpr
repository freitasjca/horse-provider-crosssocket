program HorseBenchCrossSocket;

{
  Horse Performance Benchmark Server — CrossSocket transport (Lazarus)
  =====================================================================

  Conditional defines (Project → Project Options → Custom Options):
    -dHORSE_PROVIDER_CROSSSOCKET

  Project type: Lazarus console program.
  Target: Linux x86_64 Release (primary); also compiles on Windows FPC.

  Ports:
    9002  bare routes (no middleware)
    9012  routes wrapped in RequestGuard + SecurityHeaders (pass --middleware)

  Run sequence:
    ./HorseBenchCrossSocket                  ← bare mode (port 9002)
    ./HorseBenchCrossSocket --middleware     ← middleware mode (port 9012)

  Build:
    lazbuild HorseBenchCrossSocket.lpi   (or: fpc -dHORSE_PROVIDER_CROSSSOCKET ...)

  Required search path additions in Project Options → Compiler Options → Paths:
    Other unit files (-Fu):
      ../../../../../horse/src
      ../../../../../horse-provider-crosssocket/src
      ../../../../../Delphi-Cross-Socket/Net
      ../../../../../Delphi-Cross-Socket/Utils
      ../../../Common                          ← Horse.BenchRoutes
      ../../../../../horse-request-guard/src   ← for --middleware / --guard-only
      ../../../../../horse-security-headers/src

  Threading model:
    IOCP (Windows) / epoll (Linux): CPUCount*2+1 IO threads regardless of
    connection count — no per-connection thread allocation.

  Note: --cors is omitted. Horse.CORS uses Web.HTTPApp (WebBroker) which is
  not available on FPC. Use the Delphi CrossSocket server for CORS profiling.
}

{$MODE DELPHI}{$H+}
{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_CROSSSOCKET}

uses
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  SysUtils,
  StrUtils,
  Horse,
  Horse.Provider.CrossSocket,
  Horse.Provider.CrossSocket.WorkerPool,
  Horse.Middleware.RequestGuard,
  Horse.Middleware.SecurityHeaders,
  Horse.BenchRoutes in '../../../Common/Horse.BenchRoutes.pas',
  FPC.StackChkStubs in 'FPC.StackChkStubs.pas';

const
  BASE_PORT = BENCH_PORT_CROSSSOCKET_BARE;

var
  GModeBoth:      Boolean;   // --middleware     : RequestGuard + SecurityHeaders
  GModeGuard:     Boolean;   // --guard-only     : RequestGuard only
  GModeHeaders:   Boolean;   // --headers-only   : SecurityHeaders only
  GModeHdrBefore: Boolean;   // --headers-before : headers added BEFORE Next
  GAnyMiddleware: Boolean;
  GModeLabel:     string;
  GPort:          Integer;
  GMaxConn:       Integer;   // --maxconn N  (accepted; no effect on CrossSocket)
  GListenQueue:   Integer;   // --listenqueue N  (accepted; no effect on CrossSocket)

{$IFDEF UNIX}
procedure HandleStopSignal(ASignal: cint); cdecl;
begin
  THorse.StopListen;
end;
{$ENDIF}

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

  {$IFDEF UNIX}
  fpSignal(SIGTERM, @HandleStopSignal);
  fpSignal(SIGINT,  @HandleStopSignal);
  {$ENDIF}

  if GModeBoth or GModeGuard then
    THorse.Use(THorseRequestGuard.New);
  if GModeBoth or GModeHeaders then
    THorse.Use(THorseSecurityHeaders.New);

  // --headers-before: same 5 headers as SecurityHeaders but BEFORE Next — A/B
  // against --headers-only to isolate whether post-Send mutation is the trigger.
  if GModeHdrBefore then
    THorse.Use(
      procedure(Req: THorseRequest; Res: THorseResponse; Next: TNextProc)
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

  WriteLn(Format('[HorseBench/CrossSocket·Laz] Listening on http://127.0.0.1:%d  [%s]',
    [GPort, GModeLabel]));
  WriteLn('Active provider class: ' + THorse.ClassName);
  WriteLn('Press Ctrl-C / SIGTERM to stop.');

  // --maxconn N: accepted for flag parity with the Indy server. On CrossSocket
  // the value is stored but not forwarded to the transport (no WebBroker cap).
  if GMaxConn > 0 then
  begin
    THorse.MaxConnections := GMaxConn;
    WriteLn(Format('MaxConnections override: %d (accepted; no transport effect on CrossSocket)',
      [GMaxConn]));
  end;

  // --listenqueue N: Indy-only concept. Accepted for flag parity; ignored here.
  if GListenQueue > 0 then
    WriteLn(Format('ListenQueue %d ignored (only the Indy provider has ListenQueue)',
      [GListenQueue]));

  THorse.Listen(GPort);

  WriteLn('[HorseBench/CrossSocket·Laz] Stopped cleanly.');
end.
