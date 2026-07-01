program HorseBenchTLSClient;

{
  Horse TLS Performance Benchmark Client
  =======================================
  Benches the three TLS-capable self-hosted providers over **HTTPS** and prints
  RPS + latency percentiles per provider — the TLS counterpart of
  HorseBenchClient (which covers plain HTTP).

  Targets (start the matching servers with --tls first):
    CrossSocket  https://127.0.0.1:9032   HorseBenchCrossSocket.exe --tls
    mORMot       https://127.0.0.1:9033   HorseBenchMormot.exe      --tls
    ICS          https://127.0.0.1:9039   HorseBenchICS.exe         --tls

  Modes:
    (no arg)   one-way TLS — connect over https, no client certificate.
    --mtls     mutual TLS  — present certs/client.crt + client.key. Start the
               servers with --mtls too. Requires certs/ next to the binary.

  Uses TCrossHttpClient as a provider-neutral HTTPS driver (same as the plain
  HTTP bench client). The mutual-TLS client certificate is injected by overriding
  the virtual CreateHttpCli on a TCrossHttpClient subclass.

  Exit code = total error count across all scenarios (0 = clean run).
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.StrUtils,                // IfThen (string)
  System.Classes,
  System.SyncObjs,
  System.Diagnostics,
  System.Generics.Collections,
  System.Generics.Defaults,
  Net.CrossSslSocket.Base,        // ICrossSslSocket.SetCertificateFile
  Net.CrossHttpClient,
  Utils.Logger,                   // TLogger (silence client debug logging)
  Horse.BenchRoutes in '..\Common\Horse.BenchRoutes.pas';

type
  TMTLSHttpClient = class(TCrossHttpClient)
  protected
    function CreateHttpCli(const AProtocol: string): ICrossHttpClientSocket; override;
  end;

  TProviderDef = record
    Name: string;
    Port: Integer;
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
    RPS:    Double;
    Errors: Integer;
    P50Us:  Double;
    P99Us:  Double;
  end;

const
  PROVIDER_COUNT = 3;
  PROVIDERS: array[0..PROVIDER_COUNT - 1] of TProviderDef = (
    (Name: 'CrossSocket'; Port: BENCH_PORT_CROSSSOCKET_BARE + BENCH_PORT_TLS_OFFSET),
    (Name: 'mORMot';      Port: BENCH_PORT_MORMOT_BARE      + BENCH_PORT_TLS_OFFSET),
    (Name: 'ICS';         Port: BENCH_PORT_ICS_BARE         + BENCH_PORT_TLS_OFFSET)
  );

  SCENARIO_COUNT = 2;
  SCENARIOS: array[0..SCENARIO_COUNT - 1] of TScenarioDef = (
    (Num: 1; Method: 'GET';  Route: '/ping'; BodyStr: '';          Concurrency: 50; TotalReqs: 5000),
    (Num: 2; Method: 'POST'; Route: '/echo'; BodyStr: 'bench-tls'; Concurrency: 50; TotalReqs: 5000)
  );

  WARMUP_REQS = 200;

var
  GMtls:       Boolean = False;
  GClientCert: string = '';
  GClientKey:  string = '';

function TMTLSHttpClient.CreateHttpCli(const AProtocol: string): ICrossHttpClientSocket;
begin
  Result := inherited CreateHttpCli(AProtocol);
  if SameText(AProtocol, 'https') and (GClientCert <> '') then
  begin
    Result.SetCertificateFile(GClientCert);
    Result.SetPrivateKeyFile(GClientKey);
  end;
end;

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
    if FileExists(LCand + 'client.crt') then
      Exit(LCand + AName);
  end;
  Result := 'certs' + PathDelim + AName;
end;

function TicksToUs(ATicks: Int64): Double;
begin
  Result := (ATicks / TStopwatch.Frequency) * 1000000.0;
end;

function Percentile(const ASorted: TArray<Double>; APct: Double): Double;
var
  Idx: Integer;
begin
  if Length(ASorted) = 0 then
    Exit(0);
  Idx := Trunc(APct / 100.0 * (Length(ASorted) - 1) + 0.5);
  if Idx < 0 then Idx := 0;
  if Idx > High(ASorted) then Idx := High(ASorted);
  Result := ASorted[Idx];
end;

{ Fires ATotalReqs requests at AConcurrency in flight, measuring per-request
  latency. Returns RPS + p50/p99 (µs). AWarmup skips measurement. }
function RunScenario(const AClient: TCrossHttpClient; const ABaseURL, AMethod, ARoute, ABody: string;
  AConcurrency, ATotalReqs: Integer; AWarmup: Boolean): TBenchResult;
var
  Samples:   TArray<Double>;
  hSem:      TSemaphore;
  DoneEvent: TEvent;
  LURL:      string;
  LBody:     TBytes;
  FErrors:   Integer;
  FRemain:   Integer;
  LSW:       TStopwatch;
  I:         Integer;
begin
  Result := Default(TBenchResult);
  FErrors := 0;
  FRemain := ATotalReqs;
  LURL    := ABaseURL + ARoute;
  SetLength(Samples, ATotalReqs);

  if ABody <> '' then
    LBody := TEncoding.UTF8.GetBytes(ABody)
  else
    LBody := nil;

  hSem      := TSemaphore.Create(nil, AConcurrency, AConcurrency, '');
  DoneEvent := TEvent.Create(nil, True, False, '');
  try
    LSW := TStopwatch.StartNew;
    for I := 0 to ATotalReqs - 1 do
    begin
      hSem.WaitFor;
      var LDispatch := procedure(AIdx: Integer)
        var
          LStart: Int64;
        begin
          LStart := TStopwatch.GetTimestamp;
          AClient.DoRequest(AMethod, LURL, nil, LBody, nil, nil,
            procedure(const AResp: ICrossHttpClientResponse)
            begin
              Samples[AIdx] := TStopwatch.GetTimestamp - LStart;
              if (AResp = nil) or (AResp.StatusCode < 200) or (AResp.StatusCode >= 300) then
                TInterlocked.Increment(FErrors);
              hSem.Release;
              if TInterlocked.Decrement(FRemain) = 0 then
                DoneEvent.SetEvent;
            end);
        end;
      LDispatch(I);
    end;
    DoneEvent.WaitFor;
    LSW.Stop;

    if AWarmup then
      Exit;

    for I := 0 to ATotalReqs - 1 do
      Samples[I] := TicksToUs(Trunc(Samples[I]));
    TArray.Sort<Double>(Samples);

    Result.RPS    := ATotalReqs / (LSW.ElapsedMilliseconds / 1000.0);
    Result.Errors := FErrors;
    Result.P50Us  := Percentile(Samples, 50);
    Result.P99Us  := Percentile(Samples, 99);
  finally
    hSem.Free;
    DoneEvent.Free;
  end;
end;

function MakeClient: TCrossHttpClient;
begin
  if GMtls then
    Result := TMTLSHttpClient.Create(4)
  else
    Result := TCrossHttpClient.Create(4);
end;

var
  ScenIdx, ProvIdx: Integer;
  Scen:    TScenarioDef;
  Prov:    TProviderDef;
  BaseURL: string;
  R:       TBenchResult;
  Client:  TCrossHttpClient;
  TotalErrors: Integer;
begin
  GMtls := False;
  for ScenIdx := 1 to ParamCount do
    if SameText(ParamStr(ScenIdx).TrimLeft(['-', '/']), 'mtls') then
      GMtls := True;

  if GMtls then
  begin
    GClientCert := CertPath('client.crt');
    GClientKey  := CertPath('client.key');
  end;

  WriteLn('[HorseBench/TLS] Horse provider HTTPS performance comparison');
  WriteLn(Format('[HorseBench/TLS] mode: %s', [IfThen(GMtls, 'mutual TLS', 'one-way TLS')]));
  WriteLn('[HorseBench/TLS] Start each server with --tls (or --mtls) first:');
  WriteLn('[HorseBench/TLS]   CrossSocket :9032   mORMot :9033   ICS :9039');
  WriteLn('');

  TLogger.Default.Filters := [];   // silence CrossSocket client debug logging
  TotalErrors := 0;

  for ScenIdx := 0 to SCENARIO_COUNT - 1 do
  begin
    Scen := SCENARIOS[ScenIdx];
    WriteLn(Format('## Scenario %d: %s %s  c=%d  n=%d',
      [Scen.Num, Scen.Method, Scen.Route, Scen.Concurrency, Scen.TotalReqs]));
    WriteLn('| Provider     |      RPS |   P50 µs |   P99 µs | Errors |');
    WriteLn('|--------------|----------|----------|----------|--------|');

    for ProvIdx := 0 to PROVIDER_COUNT - 1 do
    begin
      Prov    := PROVIDERS[ProvIdx];
      BaseURL := Format('https://127.0.0.1:%d', [Prov.Port]);
      Client  := MakeClient;
      try
        RunScenario(Client, BaseURL, Scen.Method, Scen.Route, Scen.BodyStr,
          Scen.Concurrency, WARMUP_REQS, True);
        R := RunScenario(Client, BaseURL, Scen.Method, Scen.Route, Scen.BodyStr,
          Scen.Concurrency, Scen.TotalReqs, False);
      finally
        Client.Free;
      end;
      Inc(TotalErrors, R.Errors);
      WriteLn(Format('| %-12s | %8.0f | %8.0f | %8.0f | %6d |',
        [Prov.Name, R.RPS, R.P50Us, R.P99Us, R.Errors]));
    end;
    WriteLn('');
  end;

  WriteLn(Format('[HorseBench/TLS] Done. Total errors: %d', [TotalErrors]));
  ExitCode := TotalErrors;
end.
