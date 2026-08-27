program HorseBenchEpoll;

{
  Horse Performance Benchmark Server — built-in epoll provider (Lazarus / FPC)
  ===========================================================================

  Conditional defines (Project → Project Options → Custom Options):
    -dHORSE_PROVIDER_EPOLL

  Ports:
    9043  bare routes (no middleware)
    9053  routes wrapped in RequestGuard + SecurityHeaders (--middleware)

  Linux only — Horse.pas raises a compile-time error for HORSE_PROVIDER_EPOLL
  on any other target, and the provider is mutually exclusive with every other
  transport Provider (one per build).

  Required unit search paths (-Fu):
    ../../../../../horse/src
    ../../../Common
    ../../../../../horse-request-guard/src
    ../../../../../horse-security-headers/src

  Why this server is in the comparison:
    It is the strongest HTTP/1.1 baseline on Linux — SO_REUSEPORT with one
    edge-triggered epoll loop per thread, so it has neither a per-connection
    thread nor a single-loop I/O ceiling. That makes it the reference the
    nghttp2 epoll engine has to be measured against, since that engine
    currently runs ONE loop thread with no SO_REUSEPORT. Expect this server to
    win the connection-scale sweep (S3) until that changes.
}

{$MODE DELPHI}{$H+}
{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_EPOLL}

uses
  {$IFDEF UNIX} cthreads, BaseUnix, {$ENDIF}
  SysUtils,
  Horse,
  Horse.Provider.Epoll,
  Horse.Middleware.RequestGuard,
  Horse.Middleware.SecurityHeaders,
  Horse.BenchRoutes in '../../../Common/Horse.BenchRoutes.pas';

const
  BASE_PORT = BENCH_PORT_EPOLL_BARE;

var
  GAnyMiddleware: Boolean;
  GPort:          Integer;

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
      Exit(True);
end;

begin
  GAnyMiddleware := HasSwitch('middleware');
  GPort          := BASE_PORT + (BENCH_PORT_MW_OFFSET * Ord(GAnyMiddleware));

  {$IFDEF UNIX}
  fpSignal(SIGTERM, @HandleStopSignal);
  fpSignal(SIGINT,  @HandleStopSignal);
  {$ENDIF}

  if GAnyMiddleware then
  begin
    THorse.Use(THorseRequestGuard.New);
    THorse.Use(THorseSecurityHeaders.New);
  end;

  RegisterBenchRoutes;

  WriteLn('HorseBenchEpoll  port=', GPort,
          '  protocol=HTTP/1.1  middleware=', GAnyMiddleware);
  WriteLn('Drive with: h2load --h1 -n 200000 -c 10 http://127.0.0.1:', GPort, '/ping');
  Flush(Output);

  THorse.Listen(GPort);
end.
