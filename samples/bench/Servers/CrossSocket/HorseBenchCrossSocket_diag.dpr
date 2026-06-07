program HorseBenchCrossSocket_diag;

{
  Horse Performance Benchmark Server — CrossSocket transport — DIAGNOSTIC BUILD
  ================================================================================

  Identical to HorseBenchCrossSocket.dpr (same routes, ports, middleware) but
  wraps the whole pipeline in a diagnostic middleware that captures the exact
  exception behind any HTTP 500, aggregated by class. See HorseBenchIndy_diag.dpr
  for the full rationale and the interpretation guide.

  Log file: horse_500_diag_crosssocket.log  (next to the .exe)
  Distinct from the Indy/mORMot diag log names so all three can run together.

  Run:
    HorseBenchCrossSocket_diag.exe --middleware    ← listens on 9012, captures 500s
    bombardier -c 100 -n 200000 --http1 http://127.0.0.1:9012/ping
}

{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_CROSSSOCKET}

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  System.SysUtils,
  System.StrUtils,
  System.SyncObjs,
  System.IOUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  Horse,
  Horse.Provider.CrossSocket,
  Horse.Provider.CrossSocket.WorkerPool,
  Horse.Exception.Interrupted,
  Horse.Middleware.RequestGuard,
  Horse.Middleware.SecurityHeaders,
  Horse.BenchRoutes in '..\..\Common\Horse.BenchRoutes.pas';

const
  BASE_PORT = BENCH_PORT_CROSSSOCKET_BARE;

var
  GModeBoth:      Boolean;
  GModeGuard:     Boolean;
  GModeHeaders:   Boolean;
  GAnyMiddleware: Boolean;
  GModeLabel:     string;
  GPort:          Integer;
  GMaxConn:       Integer;   // --maxconn N : THorse.MaxConnections override (0 = leave default)
  GListenQueue:   Integer;   // --listenqueue N : accepted for parity; Indy-only (ignored here)
  GLogLock:       TCriticalSection;
  GErrorCounts:   TDictionary<string, Integer>;
  GTotalErrors:   Integer;
  GRequestsEntered: Integer;   // requests that actually reached the Horse pipeline
  GHighStatus:    Integer;     // responses left >=500 by the pipeline WITHOUT raising
  GLogFile:       string;

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

procedure LogLine(const ALine: string);
begin
  GLogLock.Enter;
  try
    try
      TFile.AppendAllText(GLogFile, ALine + sLineBreak, TEncoding.UTF8);
    except
      // swallow — the diagnostic must never become a new failure source
    end;
  finally
    GLogLock.Leave;
  end;
end;

procedure RecordException(const E: Exception; AReq: THorseRequest);
var
  LKey:    string;
  LCount:  Integer;
  LFirst:  Boolean;
  LMethod: string;
  LPath:   string;
begin
  TInterlocked.Increment(GTotalErrors);
  LKey := E.ClassName;

  GLogLock.Enter;
  try
    if GErrorCounts.TryGetValue(LKey, LCount) then
    begin
      GErrorCounts[LKey] := LCount + 1;
      LFirst := False;
    end
    else
    begin
      GErrorCounts.Add(LKey, 1);
      LFirst := True;
    end;
  finally
    GLogLock.Leave;
  end;

  if LFirst then
  begin
    LMethod := '?';
    LPath   := '?';
    try LMethod := AReq.RawWebRequest.Method; except end;
    try LPath   := AReq.PathInfo;             except end;

    LogLine(Format('[FIRST] %s | %s | %s %s | %s',
      [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now),
       E.ClassName, LMethod, LPath, E.Message]));
  end;
end;

procedure WriteSummary;
var
  LKeys: TArray<string>;
  LKey:  string;
begin
  LogLine('');
  LogLine('================ EXCEPTION SUMMARY ================');
  LogLine(Format('Requests that entered the Horse pipeline : %d', [GRequestsEntered]));
  LogLine(Format('Pipeline exceptions (caught + re-raised) : %d', [GTotalErrors]));
  LogLine(Format('Responses >=500 set in-pipeline, no raise: %d', [GHighStatus]));
  LogLine('Compare "entered" against bombardier total requests:');
  LogLine('  entered  < total          -> 500s generated BELOW Horse (transport bridge)');
  LogLine('  exceptions ~ bombardier 5xx -> 500s are pipeline exceptions');
  LogLine('  HighStatus ~ bombardier 5xx -> a callback set 500 without raising');

  WriteLn;
  WriteLn('================ EXCEPTION SUMMARY ================');
  WriteLn(Format('Requests that entered the Horse pipeline : %d', [GRequestsEntered]));
  WriteLn(Format('Pipeline exceptions (caught + re-raised) : %d', [GTotalErrors]));
  WriteLn(Format('Responses >=500 set in-pipeline, no raise: %d', [GHighStatus]));

  GLogLock.Enter;
  try
    LKeys := GErrorCounts.Keys.ToArray;
    TArray.Sort<string>(LKeys);
    for LKey in LKeys do
    begin
      LogLine(Format('  %-40s %d', [LKey, GErrorCounts[LKey]]));
      WriteLn(Format('  %-40s %d', [LKey, GErrorCounts[LKey]]));
    end;
  finally
    GLogLock.Leave;
  end;
  LogLine('===================================================');
  WriteLn('===================================================');
  WriteLn(Format('Full log: %s', [GLogFile]));
end;

begin
  GModeBoth      := HasSwitch('middleware');
  GModeGuard     := HasSwitch('guard-only');
  GModeHeaders   := HasSwitch('headers-only');
  GMaxConn       := GetSwitchInt('maxconn', 0);
  GListenQueue   := GetSwitchInt('listenqueue', 0);
  GAnyMiddleware := GModeBoth or GModeGuard or GModeHeaders;
  GPort          := BASE_PORT + (BENCH_PORT_MW_OFFSET * Ord(GAnyMiddleware));
  if GModeBoth then GModeLabel := '+middleware'
  else if GModeGuard then GModeLabel := '+guard-only'
  else if GModeHeaders then GModeLabel := '+headers-only'
  else GModeLabel := 'bare';
  GLogFile         := TPath.Combine(ExtractFilePath(ParamStr(0)), 'horse_500_diag_crosssocket.log');
  GTotalErrors     := 0;
  GRequestsEntered := 0;
  GHighStatus      := 0;

  GLogLock     := TCriticalSection.Create;
  GErrorCounts := TDictionary<string, Integer>.Create;
  try
    {$IFDEF MSWINDOWS}
    SetConsoleCtrlHandler(@CtrlHandler, True);
    {$ENDIF}

    try TFile.WriteAllText(GLogFile, ''); except end;
    LogLine(Format('Diagnostic run start %s | port %d | %s | provider=CrossSocket',
      [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), GPort,
       GModeLabel]));

    // ── Diagnostic middleware — OUTERMOST. Wraps the full downstream chain. ──
    THorse.Use(
      procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
      var
        LStatus: Integer;
      begin
        TInterlocked.Increment(GRequestsEntered);
        try
          Next;
          LStatus := Res.Status;
          if LStatus >= 500 then
            if TInterlocked.Increment(GHighStatus) = 1 then
              LogLine(Format('[FIRST 5xx-no-exception] %s | status=%d | set in-pipeline without raising',
                [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now), LStatus]));
        except
          on E: EHorseCallbackInterrupted do
            raise;
          on E: Exception do
          begin
            RecordException(E, Req);
            raise;
          end;
        end;
      end);

    if GModeBoth or GModeGuard then
      THorse.Use(THorseRequestGuard.New);
    if GModeBoth or GModeHeaders then
      THorse.Use(THorseSecurityHeaders.New);

    RegisterBenchRoutes;

    WriteLn(Format('[HorseBench/CrossSocket DIAG] Listening on http://127.0.0.1:%d  [%s]',
      [GPort, GModeLabel]));
    WriteLn(Format('[HorseBench/CrossSocket DIAG] Capturing 500-causing exceptions to: %s',
      [GLogFile]));
    WriteLn('Active provider class: ' + THorse.ClassName);
    WriteLn('Press Ctrl-C to stop and print the summary.');

    // --maxconn N: accepted for parity with Indy; stored but not forwarded to the
    // CrossSocket transport (no WebBroker module-pool cap here). 0 = leave default.
    if GMaxConn > 0 then
    begin
      THorse.MaxConnections := GMaxConn;
      WriteLn(Format('MaxConnections override: %d (accepted; no transport effect on CrossSocket)', [GMaxConn]));
    end;

    // --listenqueue N: Indy-only (THorse.ListenQueue). Guarded so this CrossSocket
    // diag build still compiles; accepted but ignored here.
    if GListenQueue > 0 then
    begin
      {$IF NOT DEFINED(HORSE_PROVIDER_CROSSSOCKET) AND NOT DEFINED(HORSE_PROVIDER_MORMOT)}
      THorse.ListenQueue := GListenQueue;
      WriteLn(Format('ListenQueue override: %d', [GListenQueue]));
      {$ELSE}
      WriteLn(Format('ListenQueue %d ignored (only the Indy provider has ListenQueue)', [GListenQueue]));
      {$IFEND}
    end;

    THorse.Listen(GPort);

    WriteSummary;
    WriteLn('[HorseBench/CrossSocket DIAG] Stopped cleanly.');
  finally
    GErrorCounts.Free;
    GLogLock.Free;
  end;
end.
