program HorseBenchNghttp2;

{
  Horse Performance Benchmark Server — nghttp2 transport (Lazarus / FPC)
  =====================================================================

  Conditional defines (Project → Project Options → Custom Options):
    -dHORSE_PROVIDER_NGHTTP2

  Ports:
    9041  bare routes (no middleware)
    9051  routes wrapped in RequestGuard + SecurityHeaders (--middleware)

  Build (no .lpi — this tree builds with fpc directly, see run-p1.sh):
    fpc -dHORSE_PROVIDER_NGHTTP2 -MDelphi -O2 <search paths> HorseBenchNghttp2.lpr

  Required unit search paths (-Fu):
    ../../../../../horse/src
    ../../../../../horse-provider-nghttp2/src
    ../../../../../Delphi-nghttp2/src
    ../../../Common
    ../../../../../horse-request-guard/src
    ../../../../../horse-security-headers/src

  Runtime dependency: libnghttp2.so.14 (apt install libnghttp2-14).

  ── THIS SERVER SPEAKS HTTP/2, EVERY OTHER BENCH SERVER SPEAKS HTTP/1.1 ──

  That is the whole reason this binary exists, and the reason its numbers
  cannot be read as a straight ranking against the others:

    * On a trivial route at one request in flight per connection (scenario
      S1), HTTP/2 is EXPECTED to lose. It pays for frame headers, HPACK
      encoder state, per-stream flow control and a stream state machine that
      HTTP/1.1 keep-alive simply does not have. That is protocol cost, not an
      implementation defect, and reporting it as "nghttp2 is slower" measures
      the wrong thing.

    * Where it is expected to win is scenario S4 — many requests in flight
      per connection. h2load -c 10 -m 100 puts 1000 requests in flight over
      10 sockets here, against 1000 sockets everywhere else.

  Drive it with `h2load` (NOT bombardier/wrk, which are HTTP/1.1 only), and
  use the same h2load binary against the HTTP/1.1 servers with --h1 so that
  client-side cost is held constant and only the protocol varies.

  Dispatch:
    --workers=N   pin the pipeline pool to N threads
    --inline      no pool; pipeline runs on the connection thread
    --eventloop   epoll engine instead of thread-per-connection (h2c, Linux)

  Pin the thread count explicitly for any published run. Auto-sizing means
  comparing different configurations and blaming the transport for it.
}

{$MODE DELPHI}{$H+}
{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_NGHTTP2}

uses
  {$IFDEF UNIX} cthreads, BaseUnix, {$ENDIF}
  SysUtils,
  Horse,
  Horse.Provider.Nghttp2,
  Nghttp2.Engine.Epoll,          { linking this is what makes --eventloop work }
  Horse.Middleware.RequestGuard,
  Horse.Middleware.SecurityHeaders,
  Horse.BenchRoutes in '../../../Common/Horse.BenchRoutes.pas';

const
  BASE_PORT = BENCH_PORT_NGHTTP2_BARE;

var
  GAnyMiddleware: Boolean;
  GPort:          Integer;
  GWorkers:       Integer;
  GInline:        Boolean;
  GEventLoop:     Boolean;

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
    if (Length(P) > Length(Pfx)) and SameText(Copy(P, 1, Length(Pfx)), Pfx) then
      Exit(StrToIntDef(Copy(P, Length(Pfx) + 1, MaxInt), ADefault));
  end;
end;

begin
  GAnyMiddleware := HasSwitch('middleware');
  GInline        := HasSwitch('inline');
  GEventLoop     := HasSwitch('eventloop');
  GWorkers       := GetSwitchInt('workers', 0);
  GPort          := BASE_PORT + (BENCH_PORT_MW_OFFSET * Ord(GAnyMiddleware));

  {$IFDEF UNIX}
  fpSignal(SIGTERM, @HandleStopSignal);
  fpSignal(SIGINT,  @HandleStopSignal);
  {$ENDIF}

  if GInline then
    THorseProviderNghttp2.WorkerThreads := WORKER_THREADS_INLINE
  else if GWorkers > 0 then
    THorseProviderNghttp2.WorkerThreads := GWorkers;

  THorseProviderNghttp2.UseEventLoop := GEventLoop;

  if GAnyMiddleware then
  begin
    THorse.Use(THorseRequestGuard.New);
    THorse.Use(THorseSecurityHeaders.New);
  end;

  RegisterBenchRoutes;

  { Every line here goes into the results file. A benchmark run that cannot be
    attributed to a configuration is not a measurement — an earlier apparent
    21x swing "between identical runs" turned out to be two configurations
    behind a banner that did not say which was which. }
  WriteLn('HorseBenchNghttp2  port=', GPort,
          '  protocol=HTTP/2 (h2c)',
          '  middleware=', GAnyMiddleware);
  if GInline then
    WriteLn('  dispatch=INLINE (no pool)')
  else if GWorkers > 0 then
    WriteLn('  dispatch=pool workers=', GWorkers, ' (pinned)')
  else
    WriteLn('  dispatch=pool workers=auto  <-- PIN IT for a published run');
  WriteLn('  driver requested=', GEventLoop,
          '   (resolved driver is reported below once listening)');
  WriteLn('Drive with: h2load -n 200000 -c 10 -m 1 http://127.0.0.1:', GPort, '/ping');
  Flush(Output);

  THorse.Listen(GPort);
end.
