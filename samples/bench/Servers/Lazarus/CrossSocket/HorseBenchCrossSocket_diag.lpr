program HorseBenchCrossSocket_diag;

{
  Horse Performance Benchmark Server — CrossSocket transport — DIAGNOSTIC (Lazarus)
  ==================================================================================

  Identical to HorseBenchCrossSocket.lpr (same routes, ports, middleware) but
  wraps the full pipeline in a diagnostic middleware that captures every exception
  that causes an HTTP 500, aggregated by class name.

  Log file: horse_500_diag_crosssocket.log  (written next to the executable)

  Run:
    ./HorseBenchCrossSocket_diag --middleware    ← listens on 9012, captures 500s
    bombardier -c 100 -n 200000 --http1 http://127.0.0.1:9012/ping

  Same search path requirements as HorseBenchCrossSocket.lpr.
}

{$MODE DELPHI}{$H+}
{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_CROSSSOCKET}

uses
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  SysUtils,
  StrUtils,
  SyncObjs,
  Generics.Collections,
  Horse,
  Horse.Provider.CrossSocket,
  Horse.Provider.CrossSocket.WorkerPool,
  Horse.Exception.Interrupted,
  Horse.Middleware.RequestGuard,
  Horse.Middleware.SecurityHeaders,
  Horse.BenchRoutes in '../../../Common/Horse.BenchRoutes.pas';

const
  BASE_PORT = BENCH_PORT_CROSSSOCKET_BARE;

var
  GModeBoth:        Boolean;
  GModeGuard:       Boolean;
  GModeHeaders:     Boolean;
  GAnyMiddleware:   Boolean;
  GModeLabel:       string;
  GPort:            Integer;
  GMaxConn:         Integer;
  GListenQueue:     Integer;
  GLogLock:         TCriticalSection;
  GErrorCounts:     TDictionary<string, Integer>;
  GTotalErrors:     Integer;
  GRequestsEntered: Integer;
  GHighStatus:      Integer;
  GLogFile:         string;

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

function CombinePath(const ADir, AFile: string): string;
begin
  if (ADir <> '') and (ADir[Length(ADir)] <> DirectorySeparator) then
    Result := ADir + DirectorySeparator + AFile
  else
    Result := ADir + AFile;
end;

procedure LogLine(const ALine: string);
var
  F: TextFile;
begin
  GLogLock.Enter;
  try
    try
      AssignFile(F, GLogFile);
      {$I-} Append(F); {$I+}
      if IOResult <> 0 then Rewrite(F);
      WriteLn(F, ALine);
      CloseFile(F);
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

procedure SortStrArray(var A: array of string; L, R: Integer);
var
  I, J: Integer;
  P, T: string;
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
  SortStrArray(A, L, J);
  SortStrArray(A, I, R);
end;

procedure WriteSummary;
var
  LPair: TPair<string, Integer>;
  LKeys: array of string;
  LKey:  string;
  I:     Integer;
begin
  LogLine('');
  LogLine('================ EXCEPTION SUMMARY ================');
  LogLine(Format('Requests that entered the Horse pipeline : %d', [GRequestsEntered]));
  LogLine(Format('Pipeline exceptions (caught + re-raised) : %d', [GTotalErrors]));
  LogLine(Format('Responses >=500 set in-pipeline, no raise: %d', [GHighStatus]));

  WriteLn;
  WriteLn('================ EXCEPTION SUMMARY ================');
  WriteLn(Format('Requests that entered the Horse pipeline : %d', [GRequestsEntered]));
  WriteLn(Format('Pipeline exceptions (caught + re-raised) : %d', [GTotalErrors]));
  WriteLn(Format('Responses >=500 set in-pipeline, no raise: %d', [GHighStatus]));

  GLogLock.Enter;
  try
    SetLength(LKeys, GErrorCounts.Count);
    I := 0;
    for LPair in GErrorCounts do
    begin
      LKeys[I] := LPair.Key;
      Inc(I);
    end;
  finally
    GLogLock.Leave;
  end;

  if Length(LKeys) > 1 then
    SortStrArray(LKeys, 0, High(LKeys));

  for LKey in LKeys do
  begin
    LogLine(Format('  %-40s %d', [LKey, GErrorCounts[LKey]]));
    WriteLn(Format('  %-40s %d', [LKey, GErrorCounts[LKey]]));
  end;

  LogLine('===================================================');
  WriteLn('===================================================');
  WriteLn(Format('Full log: %s', [GLogFile]));
end;

var
  LF: TextFile;
begin
  GModeBoth    := HasSwitch('middleware');
  GModeGuard   := HasSwitch('guard-only');
  GModeHeaders := HasSwitch('headers-only');
  GMaxConn     := GetSwitchInt('maxconn', 0);
  GListenQueue := GetSwitchInt('listenqueue', 0);
  GAnyMiddleware := GModeBoth or GModeGuard or GModeHeaders;
  GPort          := BASE_PORT + (BENCH_PORT_MW_OFFSET * Ord(GAnyMiddleware));

  if GModeBoth then GModeLabel := '+middleware'
  else if GModeGuard then GModeLabel := '+guard-only'
  else if GModeHeaders then GModeLabel := '+headers-only'
  else GModeLabel := 'bare';

  GLogFile         := CombinePath(ExtractFilePath(ParamStr(0)),
                                  'horse_500_diag_crosssocket.log');
  GTotalErrors     := 0;
  GRequestsEntered := 0;
  GHighStatus      := 0;

  GLogLock     := TCriticalSection.Create;
  GErrorCounts := TDictionary<string, Integer>.Create;
  try
    {$IFDEF UNIX}
    fpSignal(SIGTERM, @HandleStopSignal);
    fpSignal(SIGINT,  @HandleStopSignal);
    {$ENDIF}

    // Create / truncate the log file.
    AssignFile(LF, GLogFile);
    try Rewrite(LF); CloseFile(LF); except end;

    LogLine(Format('Diagnostic run start %s | port %d | %s | provider=CrossSocket (Lazarus)',
      [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), GPort, GModeLabel]));

    // ── Diagnostic middleware — OUTERMOST ────────────────────────────────
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
              LogLine(Format('[FIRST 5xx-no-exception] %s | status=%d',
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

    WriteLn(Format('[HorseBench/CrossSocket·Laz DIAG] Listening on http://127.0.0.1:%d  [%s]',
      [GPort, GModeLabel]));
    WriteLn(Format('[HorseBench/CrossSocket·Laz DIAG] Capturing 500 exceptions to: %s',
      [GLogFile]));
    WriteLn('Press Ctrl-C / SIGTERM to stop and print summary.');

    if GMaxConn > 0 then
    begin
      THorse.MaxConnections := GMaxConn;
      WriteLn(Format('MaxConnections override: %d (no transport effect on CrossSocket)',
        [GMaxConn]));
    end;

    if GListenQueue > 0 then
      WriteLn(Format('ListenQueue %d ignored (Indy-only)', [GListenQueue]));

    THorse.Listen(GPort);

    WriteSummary;
    WriteLn('[HorseBench/CrossSocket·Laz DIAG] Stopped cleanly.');
  finally
    GErrorCounts.Free;
    GLogLock.Free;
  end;
end.
