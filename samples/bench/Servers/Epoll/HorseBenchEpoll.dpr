program HorseBenchEpoll;

{
  Horse Performance Benchmark Server - built-in epoll provider (Delphi, Linux64 only)
  ==================================================================================

  Delphi counterpart of samples/bench/Servers/Lazarus/Epoll/HorseBenchEpoll.lpr.
  Same ports, same switch, same routes - so the bench drives the Delphi-Linux64
  build and the FPC build identically.

  Conditional defines (Project -> Options -> Conditional Defines):
    HORSE_PROVIDER_EPOLL

  Project type: Console Application. Target: **Linux 64-bit ONLY** (build via
  PAServer). Horse.pas raises $MESSAGE ERROR for HORSE_PROVIDER_EPOLL on any
  non-Linux target, so this project must NOT be built for Win64 - set its only
  platform to Linux64 in the .dproj / exclude it from Win64 group builds.

  Ports:
    9043  bare routes (no middleware)
    9053  routes wrapped in RequestGuard + SecurityHeaders (pass --middleware)

  Why it is in the comparison: the strongest HTTP/1.1 baseline on Linux -
  SO_REUSEPORT with one edge-triggered epoll loop per thread (no per-connection
  thread, no single-loop I/O ceiling). The reference for the connection-scale
  sweep. HTTP/1.1; drive with h2load --h1.
}

{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_EPOLL}

uses
  System.SysUtils,
  Horse,
  Horse.Provider.Epoll,
  Horse.Middleware.RequestGuard,
  Horse.Middleware.SecurityHeaders,
  Horse.BenchRoutes in '..\..\Common\Horse.BenchRoutes.pas';

const
  BASE_PORT = BENCH_PORT_EPOLL_BARE;

var
  GAnyMiddleware: Boolean;
  GPort:          Integer;

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

  if GAnyMiddleware then
  begin
    THorse.Use(THorseRequestGuard.New);
    THorse.Use(THorseSecurityHeaders.New);
  end;

  RegisterBenchRoutes;

  WriteLn('HorseBenchEpoll  port=', GPort,
          '  protocol=HTTP/1.1  middleware=', GAnyMiddleware);
  WriteLn('Active provider class: ' + THorse.ClassName);
  WriteLn('Drive with: h2load --h1 -n 200000 -c 10 http://127.0.0.1:', GPort, '/ping');
  Flush(Output);

  THorse.Listen(GPort);
end.
