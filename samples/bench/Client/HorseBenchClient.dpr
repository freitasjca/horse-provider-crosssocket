program HorseBenchClient;

(*
  Horse Performance Benchmark Client
  ====================================
  Drives all six bench server endpoints (3 providers × 2 modes) through five
  scenarios and prints a Markdown comparison table.

  Prerequisites: all six server binaries must be listening before running this.

    HorseBenchIndy.exe                          → port 9001
    HorseBenchIndy.exe --middleware             → port 9011
    HorseBenchCrossSocket.exe                   → port 9002
    HorseBenchCrossSocket.exe --middleware      → port 9012
    HorseBenchMormot.exe                        → port 9003
    HorseBenchMormot.exe --middleware           → port 9013
    HorseBenchRawCrossSocket.exe                → port 9004
    HorseBenchRawMormot.exe                     → port 9005

  Scenarios:
    1  GET  /ping   c=10    n=50 000   baseline, low concurrency
    2  GET  /ping   c=100   n=200 000  medium concurrency
    3  GET  /ping   c=500   n=500 000  high concurrency (Indy thread stress)
    4  POST /echo   c=100   n=100 000  body round-trip
    5  GET  /alloc  c=100   n=100 000  allocation + serialisation

  Total: 30 measurement runs (5 scenarios × 3 providers × 2 modes).

  Each run is preceded by a 2 000-request warmup at c=20 to prime the
  provider's thread pool and CrossSocket's context pool.

  Concurrency model:
    Sliding window using a Windows semaphore.  The main thread dispatches
    requests one by one; each dispatch waits on the semaphore first.  The
    async callback releases the semaphore as soon as the response arrives,
    allowing the next request to be dispatched.  This keeps exactly
    Concurrency requests in-flight at all times.

  Timing:
    Per-request latency is measured as (callback entry tick - pre-dispatch tick)
    using TStopwatch.GetTimestamp (QueryPerformanceCounter on Windows, 100 ns
    resolution).  Samples are stored in a pre-allocated Int64 array using
    TInterlocked.Increment for thread-safe index assignment.  Percentiles are
    computed by in-place sort after all responses have arrived.

  Output:
    - Markdown table per scenario printed to stdout
    - Full results written to bench-results-<yyyymmdd-hhmmss>.md
*)

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.StrUtils,
  System.Classes,
  System.SyncObjs,
  System.Diagnostics,
  System.Generics.Collections,
  System.Generics.Defaults,
  Net.CrossHttpClient,
  Net.CrossHttpParams,
  Utils.Logger,
  Horse.BenchRoutes in '..\Common\Horse.BenchRoutes.pas';

// ── Constants ─────────────────────────────────────────────────────────────────

const
  WARMUP_REQS  = 2000;
  WARMUP_CONC  = 20;
  ECHO_BODY    = '{"bench":true,"padding":"XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"}';
  // ↑ 256 bytes total (including JSON overhead)

// ── Types ─────────────────────────────────────────────────────────────────────

type
  TProviderDef = record
    Name:     string;
    BarePort: Integer;
    MwPort:   Integer;
  end;

  TScenarioDef = record
    Num:         Integer;
    Method:      string;
    Route:       string;
    BodyStr:     string;   // '' for GET
    Concurrency: Integer;
    TotalReqs:   Integer;
  end;

  TBenchResult = record
    ProviderName: string;
    ModeName:     string;   // 'bare' or 'middleware'
    ScenarioNum:  Integer;
    RPS:          Double;
    MinUs:        Int64;
    MaxUs:        Int64;
    MeanUs:       Double;
    P50Us:        Int64;
    P90Us:        Int64;
    P99Us:        Int64;
    P999Us:       Int64;
    Errors:       Integer;
  end;

// ── Provider and scenario definitions ─────────────────────────────────────────

const
  PROVIDER_COUNT  = 5;
  SCENARIO_COUNT  = 5;

  // MwPort = 0 means this provider has no middleware variant — the middleware
  // loop iteration is skipped automatically.
  PROVIDERS: array[0..PROVIDER_COUNT - 1] of TProviderDef = (
    (Name: 'Indy';           BarePort: BENCH_PORT_INDY_BARE;
                             MwPort:   BENCH_PORT_INDY_BARE        + BENCH_PORT_MW_OFFSET),
    (Name: 'CrossSocket';    BarePort: BENCH_PORT_CROSSSOCKET_BARE;
                             MwPort:   BENCH_PORT_CROSSSOCKET_BARE + BENCH_PORT_MW_OFFSET),
    (Name: 'mORMot';         BarePort: BENCH_PORT_MORMOT_BARE;
                             MwPort:   BENCH_PORT_MORMOT_BARE      + BENCH_PORT_MW_OFFSET),
    (Name: 'Raw-CrossSocket';BarePort: BENCH_PORT_RAW_CROSSSOCKET;
                             MwPort:   0),
    (Name: 'Raw-mORMot';     BarePort: BENCH_PORT_RAW_MORMOT;
                             MwPort:   0)
  );

  SCENARIOS: array[0..SCENARIO_COUNT - 1] of TScenarioDef = (
    (Num: 1; Method: 'GET';  Route: '/ping';  BodyStr: ''; Concurrency:  10; TotalReqs:  50000),
    (Num: 2; Method: 'GET';  Route: '/ping';  BodyStr: ''; Concurrency: 100; TotalReqs: 200000),
    (Num: 3; Method: 'GET';  Route: '/ping';  BodyStr: ''; Concurrency: 500; TotalReqs: 500000),
    (Num: 4; Method: 'POST'; Route: '/echo';  BodyStr: ECHO_BODY; Concurrency: 100; TotalReqs: 100000),
    (Num: 5; Method: 'GET';  Route: '/alloc'; BodyStr: ''; Concurrency: 100; TotalReqs: 100000)
  );

// ── Statistics ────────────────────────────────────────────────────────────────

{ Convert QueryPerformanceCounter ticks to microseconds. }
function TicksToUs(ATicks: Int64): Int64;
begin
  Result := ATicks * 1000000 div TStopwatch.Frequency;
end;

{ Format microseconds as "N.NN ms" for table output. }
function FmtUs(AUs: Int64): string;
begin
  Result := Format('%7.2f ms', [AUs / 1000.0]);
end;

{ Sort samples in-place and compute min/max/mean/percentiles. }
procedure ComputeStats(
  var   Samples: TArray<Int64>;
  out   AMin:    Int64;
  out   AMax:    Int64;
  out   AMean:   Double;
  out   AP50:    Int64;
  out   AP90:    Int64;
  out   AP99:    Int64;
  out   AP999:   Int64
);
var
  N:   Integer;
  I:   Integer;
  Sum: Int64;
begin
  N := Length(Samples);
  if N = 0 then
  begin
    AMin := 0; AMax := 0; AMean := 0;
    AP50 := 0; AP90 := 0; AP99  := 0; AP999 := 0;
    Exit;
  end;

  TArray.Sort<Int64>(Samples);

  AMin  := Samples[0];
  AMax  := Samples[N - 1];

  Sum := 0;
  for I := 0 to N - 1 do
    Inc(Sum, Samples[I]);
  AMean := Sum / N;

  AP50  := Samples[Trunc(N * 0.50)];
  AP90  := Samples[Trunc(N * 0.90)];
  AP99  := Samples[Trunc(N * 0.99)];
  AP999 := Samples[Trunc(N * 0.999)];
end;

// ── Core benchmark runner ─────────────────────────────────────────────────────

{
  Run ATotalReqs requests against ABaseURL + ARoute at AConcurrency concurrency.
  Returns timing stats for all completed requests.

  Sliding-window dispatch:
    hSem (Windows semaphore, initial = AConcurrency) throttles dispatch.
    Main thread: WaitForSingleObject before each DoRequest.
    Callback:    ReleaseSemaphore after recording the sample.
    DoneEvent:   signalled when FRemain reaches 0 (all callbacks fired).

  Per-request timing:
    LDispatch(I) is a TProc<Integer> call — each invocation creates its own
    stack frame with its own AIdx (value parameter) and LStart (local var).
    The inner closure captures AIdx and LStart from THAT frame, not from the
    loop.  Inline `var LIdx := I` inside a Delphi for-loop does NOT guarantee
    a new closure cell per iteration; the value-parameter approach is reliable.
}
function RunScenario(
  const AClient:      TCrossHttpClient;
  const ABaseURL:     string;
  const AMethod:      string;
  const ARoute:       string;
  const ABodyBytes:   TBytes;
  AConcurrency:       Integer;
  ATotalReqs:         Integer;
  AWarmup:            Boolean
): TBenchResult;
var
  hSem:       THandle;
  DoneEvent:  TEvent;
  Samples:    TArray<Int64>;
  FErrors:    Integer;
  FRemain:    Integer;
  LURL:       string;
  I:          Integer;
  LSW:        TStopwatch;
  LMinUs,
  LMaxUs,
  LP50Us,
  LP90Us,
  LP99Us,
  LP999Us:    Int64;
  LMeanUs:    Double;
  LDispatch:  TProc<Integer>;
begin
  Result  := Default(TBenchResult);
  FErrors := 0;
  FRemain := ATotalReqs;
  LURL    := ABaseURL + ARoute;

  SetLength(Samples, ATotalReqs);
  hSem      := CreateSemaphore(nil, AConcurrency, AConcurrency, nil);
  DoneEvent := TEvent.Create(nil, True, False, '');
  try
    // Each call LDispatch(I) is a distinct procedure invocation.
    // AIdx is a value parameter — each invocation owns its copy.
    // LStart is a local var in that invocation's frame — owned per call.
    // The inner anonymous method captures AIdx + LStart from that frame,
    // giving every request its own private timing state.
    LDispatch := procedure(AIdx: Integer)
      var
        LStart: Int64;
      begin
        LStart := TStopwatch.GetTimestamp;
        AClient.DoRequest(AMethod, LURL, nil, ABodyBytes, nil, nil,
          procedure(const AResp: ICrossHttpClientResponse)
          begin
            Samples[AIdx] := TStopwatch.GetTimestamp - LStart;

            if (AResp = nil) or (AResp.StatusCode < 200) or (AResp.StatusCode >= 300) then
              TInterlocked.Increment(FErrors);

            ReleaseSemaphore(hSem, 1, nil);

            if TInterlocked.Decrement(FRemain) = 0 then
              DoneEvent.SetEvent;
          end);
      end;

    LSW := TStopwatch.StartNew;

    for I := 0 to ATotalReqs - 1 do
    begin
      WaitForSingleObject(hSem, INFINITE);
      LDispatch(I);
    end;

    DoneEvent.WaitFor(INFINITE);   // block until all ATotalReqs callbacks have fired
    LSW.Stop;

    if AWarmup then
      Exit;

    // Convert tick samples to microseconds.
    for I := 0 to ATotalReqs - 1 do
      Samples[I] := TicksToUs(Samples[I]);

    ComputeStats(Samples, LMinUs, LMaxUs, LMeanUs, LP50Us, LP90Us, LP99Us, LP999Us);

    Result.RPS    := ATotalReqs / (LSW.ElapsedMilliseconds / 1000.0);
    Result.Errors := FErrors;
    Result.MinUs  := LMinUs;
    Result.MaxUs  := LMaxUs;
    Result.MeanUs := LMeanUs;
    Result.P50Us  := LP50Us;
    Result.P90Us  := LP90Us;
    Result.P99Us  := LP99Us;
    Result.P999Us := LP999Us;

  finally
    CloseHandle(hSem);
    DoneEvent.Free;
  end;
end;

// ── Output helpers ────────────────────────────────────────────────────────────

procedure PrintScenarioHeader(const AScen: TScenarioDef; var AOut: TStringList);
var
  LLine: string;
begin
  LLine := Format('## Scenario %d: %s %s  c=%d  n=%d',
    [AScen.Num, AScen.Method, AScen.Route, AScen.Concurrency, AScen.TotalReqs]);
  WriteLn('');
  WriteLn(LLine);
  WriteLn('');
  WriteLn('| Provider       | Mode       |      RPS |     P50 |     P90 |     P99 |   P99.9 | Errors |');
  WriteLn('|----------------|------------|----------|---------|---------|---------|---------|--------|');
  AOut.Add('');
  AOut.Add(LLine);
  AOut.Add('');
  AOut.Add('| Provider       | Mode       |      RPS |     P50 |     P90 |     P99 |   P99.9 | Errors |');
  AOut.Add('|----------------|------------|----------|---------|---------|---------|---------|--------|');
end;

procedure PrintResultRow(const R: TBenchResult; var AOut: TStringList);
var
  LRow: string;
begin
  LRow := Format('| %-14s | %-10s | %8.0f | %s | %s | %s | %s | %6d |',
    [R.ProviderName, R.ModeName,
     R.RPS,
     FmtUs(R.P50Us), FmtUs(R.P90Us), FmtUs(R.P99Us), FmtUs(R.P999Us),
     R.Errors]);
  WriteLn(LRow);
  AOut.Add(LRow);
end;

// ── Entry point ───────────────────────────────────────────────────────────────

var
  Client:     TCrossHttpClient;
  Results:    TList<TBenchResult>;
  OutputFile: TStringList;
  ScenIdx:    Integer;
  ProvIdx:    Integer;
  MwIdx:      Integer;   // 0 = bare, 1 = middleware
  Scen:       TScenarioDef;
  Prov:       TProviderDef;
  Port:       Integer;
  BaseURL:    string;
  Mode:       string;
  BodyBytes:  TBytes;
  R:          TBenchResult;
  FileName:   string;

begin
  WriteLn('[HorseBench] Horse provider performance comparison');
  WriteLn('[HorseBench] Ensure all 8 server binaries are listening before proceeding.');
  WriteLn('[HorseBench]   Indy bare        :9001  CrossSocket bare    :9002  mORMot bare    :9003');
  WriteLn('[HorseBench]   Indy +mw         :9011  CrossSocket +mw     :9012  mORMot +mw     :9013');
  WriteLn('[HorseBench]   Raw-CrossSocket  :9004  Raw-mORMot          :9005');
  WriteLn('');

  Results    := TList<TBenchResult>.Create;
  OutputFile := TStringList.Create;
  // Suppress CrossSocket internal debug logging — all log types filtered out.
  // The gate is in TLogger._AppendLogToBuffer: `if not (ALogType in FFilters) then Exit`.
  TLogger.Default.Filters := [];

  Client     := TCrossHttpClient.Create(4 {IoThreads});
  try
    OutputFile.Add('# Horse Provider Benchmark Results');
    OutputFile.Add(Format('Generated: %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now)]));
    OutputFile.Add('');
    OutputFile.Add('Scenarios: 1=ping c=10, 2=ping c=100, 3=ping c=500, 4=echo c=100, 5=alloc c=100');
    OutputFile.Add('All latency values in milliseconds.  Errors = non-2xx + timeout responses.');
    OutputFile.Add('');

    for ScenIdx := 0 to SCENARIO_COUNT - 1 do
    begin
      Scen := SCENARIOS[ScenIdx];

      if Scen.BodyStr <> '' then
        BodyBytes := TEncoding.UTF8.GetBytes(Scen.BodyStr)
      else
        BodyBytes := nil;

      PrintScenarioHeader(Scen, OutputFile);

      for ProvIdx := 0 to PROVIDER_COUNT - 1 do
      begin
        Prov := PROVIDERS[ProvIdx];

        for MwIdx := 0 to 1 do
        begin
          if MwIdx = 0 then
          begin
            Port := Prov.BarePort;
            Mode := 'bare';
          end
          else
          begin
            if Prov.MwPort = 0 then
              Continue;   // raw providers have no middleware variant
            Port := Prov.MwPort;
            Mode := 'middleware';
          end;

          BaseURL := Format('http://127.0.0.1:%d', [Port]);

          Write(Format('[HorseBench] Warming up  %s/%s S%d ... ',
            [Prov.Name, Mode, Scen.Num]));
          RunScenario(Client, BaseURL, Scen.Method, Scen.Route,
            BodyBytes, WARMUP_CONC, WARMUP_REQS, True {warmup});
          WriteLn('done');

          Write(Format('[HorseBench] Running     %s/%s S%d ... ',
            [Prov.Name, Mode, Scen.Num]));
          R := RunScenario(Client, BaseURL, Scen.Method, Scen.Route,
            BodyBytes, Scen.Concurrency, Scen.TotalReqs, False);
          R.ProviderName := Prov.Name;
          R.ModeName     := Mode;
          R.ScenarioNum  := Scen.Num;
          WriteLn(Format('done  (%.0f RPS)', [R.RPS]));

          Results.Add(R);
          PrintResultRow(R, OutputFile);
        end;
      end;
    end;

    // ── Save results file ─────────────────────────────────────────────────────
    FileName := Format('bench-results-%s.md',
      [FormatDateTime('yyyymmdd-hhnnss', Now)]);
    OutputFile.SaveToFile(FileName, TEncoding.UTF8);
    WriteLn('');
    WriteLn(Format('[HorseBench] Results saved to %s', [FileName]));
    WriteLn('[HorseBench] Validate with: bombardier -c 100 -n 200000 --print r http://127.0.0.1:9002/ping');

  finally
    Client.Free;
    Results.Free;
    OutputFile.Free;
  end;
end.
