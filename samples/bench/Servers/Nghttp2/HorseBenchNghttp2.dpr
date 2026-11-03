program HorseBenchNghttp2;

{
  Horse Performance Benchmark Server - nghttp2 transport (Delphi)
  ==============================================================

  Delphi counterpart of samples/bench/Servers/Lazarus/Nghttp2/HorseBenchNghttp2.lpr.
  Same ports, same switches, same routes - so h2load drives the Delphi and the
  FPC build identically.

  Conditional defines (Project -> Options -> Conditional Defines):
    HORSE_PROVIDER_NGHTTP2

  Project type: Console Application. Target: Win64 Release or Linux64 Release.

  Ports:
    9041  bare routes (no middleware)
    9051  routes wrapped in RequestGuard + SecurityHeaders (pass --middleware)

  Runtime dependency: libnghttp2 (Windows: nghttp2.dll on PATH;
  Linux: apt install libnghttp2-14). The provider loads it dynamically at
  Listen time and raises a clear error if it is missing.

  -- THIS SERVER SPEAKS HTTP/2, EVERY OTHER BENCH SERVER SPEAKS HTTP/1.1 --

  That is the whole reason this binary exists, and the reason its numbers
  cannot be read as a straight ranking against the others:

    * On a trivial route at one request in flight per connection (bench-h2
      S1), HTTP/2 is EXPECTED to lose. It pays for frame headers, HPACK
      encoder state, per-stream flow control and a stream state machine that
      HTTP/1.1 keep-alive does not have. That is protocol cost, not an
      implementation defect.

    * Where it is expected to win is the multiplexing scenario (S4) - many
      requests in flight per connection: h2load -c 10 -m 100 puts 1000
      requests in flight over 10 sockets here, against 1000 sockets everywhere
      else.

  Drive it with h2load (NOT bombardier/wrk, which are HTTP/1.1 only), and use
  the SAME h2load binary against the HTTP/1.1 servers with --h1 so client-side
  cost is held constant and only the protocol varies. scripts\bench-h2.bat
  (Windows) / scripts\bench-h2.sh (Linux) do exactly that.

  Dispatch (pin it for any published run - auto-sizing means comparing
  different configurations and blaming the transport for it):
    --workers=N   pin the pipeline pool to N threads
    --inline      no pool; pipeline runs on the connection thread
    --eventloop   epoll engine instead of thread-per-connection (h2c, Linux only)
}

{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_NGHTTP2}

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  System.SysUtils,
  Horse,
  Horse.Provider.Nghttp2,
  {$IFDEF LINUX}
  Nghttp2.Engine.Epoll,          // linking this is what makes --eventloop work (Linux, h2c)
  {$ENDIF}
  Horse.Middleware.RequestGuard,
  Horse.Middleware.SecurityHeaders,
  Horse.BenchRoutes in '..\..\Common\Horse.BenchRoutes.pas';

const
  BASE_PORT = BENCH_PORT_NGHTTP2_BARE;

var
  GAnyMiddleware: Boolean;
  GPort:          Integer;
  GWorkers:       Integer;
  GInline:        Boolean;
  GEventLoop:     Boolean;

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
    attributed to a configuration is not a measurement - an earlier apparent
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
  {$IFDEF LINUX}
  WriteLn('  driver requested=', GEventLoop,
          '   (resolved driver is reported below once listening)');
  {$ELSE}
  if GEventLoop then
    WriteLn('  NOTE: --eventloop is Linux/h2c only; ignored on Windows (thread-per-conn)');
  {$ENDIF}
  WriteLn('Active provider class: ' + THorse.ClassName);
  WriteLn('Drive with: h2load -n 200000 -c 10 -m 1 http://127.0.0.1:', GPort, '/ping');
  Flush(Output);

  THorse.Listen(GPort);
end.
