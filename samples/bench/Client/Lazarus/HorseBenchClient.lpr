program HorseBenchClient;

(*
  Horse Performance Benchmark Client (Lazarus)
  =============================================

  FPC adaptation of Client/HorseBenchClient.dpr.

  Drives the three Lazarus-native bench server endpoints through five scenarios
  and prints a Markdown comparison table identical in format to the Delphi client.

  Servers that must be running before this client:
    ./HorseBenchCrossSocket                 → port 9002  (Lazarus or Delphi)
    ./HorseBenchCrossSocket --middleware    → port 9012
    ./HorseBenchFPCHttp                     → port 9007  (Lazarus only)
    ./HorseBenchFPCHttp --middleware        → port 9017
    ./HorseBenchMormot                      → port 9003  (Lazarus or Delphi)
    ./HorseBenchMormot --middleware         → port 9013
    ./HorseBenchRawCrossSocket              → port 9004  (Lazarus or Delphi)
    ./HorseBenchRawMormot                   → port 9005  (Lazarus or Delphi)
    ./HorseBenchRawFPCHttp                  → port 9008  (Lazarus only)

  To also benchmark Delphi's Indy server, start that binary on port 9001/9011
  and add it to the PROVIDERS constant below.

  Scenarios:
    1  GET  /ping   c=10    n=50 000   baseline, low concurrency
    2  GET  /ping   c=100   n=200 000  medium concurrency
    3  GET  /ping   c=500   n=500 000  high concurrency (thread stress on FPCHttp)
    4  POST /echo   c=100   n=100 000  body round-trip
    5  GET  /alloc  c=100   n=100 000  allocation + serialisation

  Each run is preceded by a 2 000-request warmup at c=20.

  Timing:
    On Linux/Unix: fpgettimeofday (1 µs resolution).
    On Windows FPC: QueryPerformanceCounter.

  Build:
    lazbuild HorseBenchClient.lpi

  Required search path additions (-Fu):
    ../../../../Delphi-Cross-Socket/Net
    ../../../../Delphi-Cross-Socket/Utils
    ../../../../Delphi-Cross-Socket/Lib/OpenSSL
    ../../Common                              ← Horse.BenchRoutes
*)

{$MODE DELPHI}{$H+}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  {$IFDEF WINDOWS} Windows, {$ENDIF}
  SysUtils,
  StrUtils,
  Classes,
  SyncObjs,
  Generics.Collections,
  Net.CrossHttpClient,
  Net.CrossHttpParams,
  Utils.Logger,
  Horse.BenchRoutes in '../../Common/Horse.BenchRoutes.pas';

// ── High-resolution timer ──────────────────────────────────────────────────────

{$IF DEFINED(UNIX)}
function BenchTimestamp: Int64; inline;
var
  TV: TTimeVal;
begin
  fpgettimeofday(@TV, nil);
  Result := Int64(TV.tv_sec) * 1000000 + TV.tv_usec;
end;

const BENCH_FREQ = Int64(1000000);  // fpgettimeofday returns microseconds

{$ELSEIF DEFINED(WINDOWS)}
var
  GBenchFreq: Int64;

function BenchTimestamp: Int64; inline;
begin
  QueryPerformanceCounter(Result);
end;
{$ELSE}
function BenchTimestamp: Int64; inline;
begin
  Result := Int64(GetTickCount64) * 1000;  // millisecond fallback
end;

const BENCH_FREQ = Int64(1000000);
{$IFEND}

function TicksToUs(ATicks: Int64): Int64; inline;
begin
  {$IF DEFINED(UNIX)}
  Result := ATicks;              // already microseconds
  {$ELSEIF DEFINED(WINDOWS)}
  Result := ATicks * 1000000 div GBenchFreq;
  {$ELSE}
  Result := ATicks;
  {$IFEND}
end;

type
  TBenchWatch = record
  private
    FStart: Int64;
    FStop:  Int64;
  public
    class function StartNew: TBenchWatch; static;
    procedure Stop;
    function ElapsedMilliseconds: Int64;
  end;

class function TBenchWatch.StartNew: TBenchWatch;
begin
  Result.FStart := BenchTimestamp;
  Result.FStop  := 0;
end;

procedure TBenchWatch.Stop;
begin
  FStop := BenchTimestamp;
end;

function TBenchWatch.ElapsedMilliseconds: Int64;
var
  Ticks: Int64;
begin
  Ticks := FStop - FStart;
  {$IF DEFINED(UNIX)}
  Result := Ticks div 1000;
  {$ELSEIF DEFINED(WINDOWS)}
  Result := Ticks * 1000 div GBenchFreq;
  {$ELSE}
  Result := Ticks div 1000;
  {$IFEND}
end;

// ── Constants ─────────────────────────────────────────────────────────────────

const
  WARMUP_REQS = 2000;
  WARMUP_CONC = 20;
  ECHO_BODY   = '{"bench":true,"padding":"' +
    'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' +
    'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' +
    'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' +
    'XXXXXXXXXXXX"}';
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
    BodyStr:     string;
    Concurrency: Integer;
    TotalReqs:   Integer;
  end;

  TBenchResult = record
    ProviderName: string;
    ModeName:     string;
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
  PROVIDER_COUNT  = 6;
  SCENARIO_COUNT  = 5;

  // MwPort = 0 means no middleware variant — the MwIdx=1 loop iteration is skipped.
  PROVIDERS: array[0..PROVIDER_COUNT - 1] of TProviderDef = (
    (Name: 'CrossSocket';
     BarePort: BENCH_PORT_CROSSSOCKET_BARE;
     MwPort:   BENCH_PORT_CROSSSOCKET_BARE + BENCH_PORT_MW_OFFSET),
    (Name: 'FPC-HTTP';
     BarePort: BENCH_PORT_FPC_HTTP_BARE;
     MwPort:   BENCH_PORT_FPC_HTTP_BARE + BENCH_PORT_MW_OFFSET),
    (Name: 'mORMot';
     BarePort: BENCH_PORT_MORMOT_BARE;
     MwPort:   BENCH_PORT_MORMOT_BARE + BENCH_PORT_MW_OFFSET),
    (Name: 'Raw-CrossSocket';
     BarePort: BENCH_PORT_RAW_CROSSSOCKET;
     MwPort:   0),
    (Name: 'Raw-mORMot';
     BarePort: BENCH_PORT_RAW_MORMOT;
     MwPort:   0),
    (Name: 'Raw-FPCHttp';
     BarePort: BENCH_PORT_RAW_FPC_HTTP;
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

procedure QuickSortInt64(var A: TArray<Int64>; L, R: Integer);
var
  I, J: Integer;
  P, T: Int64;
begin
  if L >= R then Exit;
  P := A[(L + R) div 2];
  I := L; J := R;
  while I <= J do
  begin
    while A[I] < P do Inc(I);
    while A[J] > P do Dec(J);
    if I <= J then
    begin
      T := A[I]; A[I] := A[J]; A[J] := T;
      Inc(I); Dec(J);
    end;
  end;
  QuickSortInt64(A, L, J);
  QuickSortInt64(A, I, R);
end;

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

  QuickSortInt64(Samples, 0, N - 1);

  AMin  := Samples[0];
  AMax  := Samples[N - 1];
  Sum   := 0;
  for I := 0 to N - 1 do
    Inc(Sum, Samples[I]);
  AMean := Sum / N;

  AP50  := Samples[Trunc(N * 0.50)];
  AP90  := Samples[Trunc(N * 0.90)];
  AP99  := Samples[Trunc(N * 0.99)];
  AP999 := Samples[Trunc(N * 0.999)];
end;

function FmtUs(AUs: Int64): string;
begin
  Result := Format('%7.2f ms', [AUs / 1000.0]);
end;

// ── Encode body string to UTF-8 bytes ─────────────────────────────────────────

function StrToBytes(const S: string): TBytes;
var
  U: UTF8String;
begin
  U := UTF8Encode(S);
  SetLength(Result, Length(U));
  if Length(U) > 0 then
    Move(U[1], Result[0], Length(U));
end;

// ── Core benchmark runner ─────────────────────────────────────────────────────

function RunScenario(
  const AClient:    TCrossHttpClient;
  const ABaseURL:   string;
  const AMethod:    string;
  const ARoute:     string;
  const ABodyBytes: TBytes;
  AConcurrency:     Integer;
  ATotalReqs:       Integer;
  AWarmup:          Boolean
): TBenchResult;
var
  hSem:      TSemaphore;
  DoneEvent: TEvent;
  Samples:   TArray<Int64>;
  FErrors:   Integer;
  FRemain:   Integer;
  LURL:      string;
  I:         Integer;
  LSW:       TBenchWatch;
  LMinUs,
  LMaxUs,
  LP50Us,
  LP90Us,
  LP99Us,
  LP999Us:   Int64;
  LMeanUs:   Double;
  LDispatch: TProc<Integer>;
begin
  Result  := Default(TBenchResult);
  FErrors := 0;
  FRemain := ATotalReqs;
  LURL    := ABaseURL + ARoute;

  SetLength(Samples, ATotalReqs);
  // FPC TSemaphore constructor: (InitialCount, MaxCount)
  hSem      := TSemaphore.Create(AConcurrency, AConcurrency);
  DoneEvent := TEvent.Create(nil, True, False, '');
  try
    LDispatch := procedure(AIdx: Integer)
      var
        LStart: Int64;
      begin
        LStart := BenchTimestamp;
        AClient.DoRequest(AMethod, LURL, nil, ABodyBytes, nil, nil,
          procedure(const AResp: ICrossHttpClientResponse)
          begin
            Samples[AIdx] := BenchTimestamp - LStart;

            if (AResp = nil) or (AResp.StatusCode < 200) or (AResp.StatusCode >= 300) then
              TInterlocked.Increment(FErrors);

            hSem.Release;

            if TInterlocked.Decrement(FRemain) = 0 then
              DoneEvent.SetEvent;
          end);
      end;

    LSW := TBenchWatch.StartNew;

    for I := 0 to ATotalReqs - 1 do
    begin
      hSem.WaitFor;
      LDispatch(I);
    end;

    DoneEvent.WaitFor;
    LSW.Stop;

    if AWarmup then
      Exit;

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
    hSem.Free;
    DoneEvent.Free;
  end;
end;

// ── Output helpers ────────────────────────────────────────────────────────────

procedure PrintScenarioHeader(const AScen: TScenarioDef;
  var AOut: TStringList);
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
  MwIdx:      Integer;
  Scen:       TScenarioDef;
  Prov:       TProviderDef;
  Port:       Integer;
  BaseURL:    string;
  Mode:       string;
  BodyBytes:  TBytes;
  R:          TBenchResult;
  FileName:   string;

begin
  {$IFDEF WINDOWS}
  QueryPerformanceFrequency(GBenchFreq);
  {$ENDIF}

  WriteLn('[HorseBench·Laz] Horse provider performance comparison (Lazarus)');
  WriteLn('[HorseBench·Laz] Ensure server binaries are listening before proceeding.');
  WriteLn('[HorseBench·Laz]   CrossSocket bare :9002  CrossSocket +mw :9012');
  WriteLn('[HorseBench·Laz]   FPC-HTTP bare    :9007  FPC-HTTP +mw    :9017');
  WriteLn('[HorseBench·Laz]   mORMot bare      :9003  mORMot +mw      :9013');
  WriteLn('[HorseBench·Laz]   Raw-CrossSocket  :9004  Raw-mORMot      :9005');
  WriteLn('[HorseBench·Laz]   Raw-FPCHttp      :9008');
  WriteLn('');

  Results    := TList<TBenchResult>.Create;
  OutputFile := TStringList.Create;
  // Suppress CrossSocket internal debug logging.
  TLogger.Default.Filters := [];

  Client := TCrossHttpClient.Create(4 {IoThreads});
  try
    OutputFile.Add('# Horse Provider Benchmark Results (Lazarus)');
    OutputFile.Add(Format('Generated: %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now)]));
    OutputFile.Add('');
    OutputFile.Add('Servers: CrossSocket (9002/9012), FPC-HTTP (9007/9017), mORMot (9003/9013), Raw-CrossSocket (9004), Raw-mORMot (9005), Raw-FPCHttp (9008)');
    OutputFile.Add('Scenarios: 1=ping c=10, 2=ping c=100, 3=ping c=500, 4=echo c=100, 5=alloc c=100');
    OutputFile.Add('All latency values in milliseconds.  Errors = non-2xx + timeout responses.');
    OutputFile.Add('');

    for ScenIdx := 0 to SCENARIO_COUNT - 1 do
    begin
      Scen := SCENARIOS[ScenIdx];

      if Scen.BodyStr <> '' then
        BodyBytes := StrToBytes(Scen.BodyStr)
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
              Continue;
            Port := Prov.MwPort;
            Mode := 'middleware';
          end;

          BaseURL := Format('http://127.0.0.1:%d', [Port]);

          Write(Format('[HorseBench·Laz] Warming up  %s/%s S%d ... ',
            [Prov.Name, Mode, Scen.Num]));
          RunScenario(Client, BaseURL, Scen.Method, Scen.Route,
            BodyBytes, WARMUP_CONC, WARMUP_REQS, True);
          WriteLn('done');

          Write(Format('[HorseBench·Laz] Running     %s/%s S%d ... ',
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

    FileName := Format('bench-results-lazarus-%s.md',
      [FormatDateTime('yyyymmdd-hhnnss', Now)]);
    OutputFile.SaveToFile(FileName);
    WriteLn('');
    WriteLn(Format('[HorseBench·Laz] Results saved to %s', [FileName]));

  finally
    Client.Free;
    Results.Free;
    OutputFile.Free;
  end;
end.
