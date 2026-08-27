program HorseBenchRawNghttp2;

{
  Raw transport baseline — TNghttp2Server directly, NO Horse framework
  ====================================================================

  Port: 9042.  No middleware variant (there is no middleware without Horse).

  This is the nghttp2 half of scenario S8, the framework-floor measurement,
  and it is the single most important server in phase P1.

  ── Why the floor decides how to read every other result ──

  THorse.Execute plus the context pool plus the request/response bridges are
  shared by every provider. Whatever that costs per request, no transport can
  go below it, and all transport differences compress toward zero as the
  handler gets cheaper.

  So: run this against HorseBenchNghttp2 (port 9041) on the same route with
  the same load, and the delta is Horse's per-request cost on this transport.

    * If the floor is a small fraction of total cost, provider choice matters
      and the rest of the benchmark is worth running.
    * If the floor dominates, then the entire provider comparison is a fight
      over what is left, every ranking in it is nearly noise, and the effort
      belongs in THorse.Execute rather than in transports.

  That is a result which can redirect the whole project, and it is the
  cheapest measurement in the plan. Run it first, read it before building
  anything else.

  ── Routes ──

  Deliberately hand-written rather than reusing Horse.BenchRoutes, because
  reusing it would drag Horse in and there would be no floor to measure.
  They must stay byte-identical in output to the Horse versions or the delta
  measures a different response, not a different framework:

    GET  /ping   -> "pong"            text/plain
    POST /echo   -> request body      application/octet-stream
    GET  /alloc  -> 1024 'x' bytes    text/plain

  Build:
    fpc -MDelphi -O2 -Fu<Delphi-nghttp2/src> -Fu<bench/Common> HorseBenchRawNghttp2.lpr

  Runtime dependency: libnghttp2.so.14 (apt install libnghttp2-14).
}

{$MODE DELPHI}{$H+}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX} cthreads, BaseUnix, {$ENDIF}
  SysUtils, Classes,
  Nghttp2.Types,
  Nghttp2.Server,
  Nghttp2.Engine.Epoll,          { linking this is what makes --eventloop work }
  Horse.BenchRoutes in '../../../Common/Horse.BenchRoutes.pas';

const
  BASE_PORT = BENCH_PORT_RAW_NGHTTP2;

var
  GServer:  TNghttp2Server;
  GStop:    Boolean = False;
  GAllocBody: TBytes;

{$IFDEF UNIX}
procedure HandleStopSignal(ASignal: cint); cdecl;
begin
  GStop := True;
end;
{$ENDIF}

{ Plain unit-scope procedure, NOT an anonymous method and NOT a method of a
  class. TNghttp2OnRequestProc is a plain procedure type, and FPC without
  FUNCTIONREFERENCES compiles neither anonymous procs nor bound class methods
  into it — the same constraint that shapes Horse.CORS and every middleware
  in this workspace. }
procedure RawBenchHandler(const AStream: INghttp2Stream);
var
  LPath:   string;
  LMethod: string;
  LBody:   TBytes;
  LLen:    Integer;
begin
  LPath   := AStream.Header[':path'];
  LMethod := AStream.Header[':method'];

  if (LMethod = 'GET') and (LPath = '/ping') then
  begin
    AStream.StatusCode := 200;
    AStream.Header['content-type'] := 'text/plain';
    AStream.Send(TEncoding.UTF8.GetBytes('pong'));
    Exit;
  end;

  if (LMethod = 'POST') and (LPath = '/echo') then
  begin
    AStream.StatusCode := 200;
    AStream.Header['content-type'] := 'application/octet-stream';
    LBody := nil;
    if AStream.Body <> nil then
    begin
      LLen := AStream.Body.Size;
      SetLength(LBody, LLen);
      if LLen > 0 then
      begin
        AStream.Body.Position := 0;
        AStream.Body.ReadBuffer(LBody[0], LLen);
      end;
    end;
    AStream.Send(LBody);
    Exit;
  end;

  if (LMethod = 'GET') and (LPath = '/alloc') then
  begin
    AStream.StatusCode := 200;
    AStream.Header['content-type'] := 'text/plain';
    // Prebuilt once at startup. Building it per request would measure
    // allocation here and a pooled path in the Horse version — the delta has
    // to be the framework, not a different amount of work.
    AStream.Send(GAllocBody);
    Exit;
  end;

  AStream.StatusCode := 404;
  AStream.Header['content-type'] := 'text/plain';
  AStream.Send(TEncoding.UTF8.GetBytes('not found'));
end;

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

var
  LConfig:  THorseNghttp2Config;
  LWorkers: Integer;

begin
  SetLength(GAllocBody, ALLOC_BODY_SIZE);
  FillChar(GAllocBody[0], ALLOC_BODY_SIZE, Ord('x'));

  {$IFDEF UNIX}
  fpSignal(SIGTERM, @HandleStopSignal);
  fpSignal(SIGINT,  @HandleStopSignal);
  {$ENDIF}

  LWorkers := GetSwitchInt('workers', 0);

  LConfig      := THorseNghttp2Config.Default;
  LConfig.Port := BASE_PORT;

  { Match whatever the Horse-wrapped server is running, or the floor
    measurement compares two different dispatch models and attributes the
    difference to the framework. }
  LConfig.WorkerThreads  := LWorkers;
  LConfig.AsyncDispatch  := LWorkers > 0;
  LConfig.UseEventLoop   := HasSwitch('eventloop');

  GServer := TNghttp2Server.Create;
  try
    GServer.OnRequest := RawBenchHandler;
    GServer.Start(LConfig);

    WriteLn('HorseBenchRawNghttp2  port=', BASE_PORT,
            '  protocol=HTTP/2 (h2c)  framework=NONE');
    if LWorkers > 0 then
      WriteLn('  dispatch=pool workers=', LWorkers, ' (pinned)')
    else
      WriteLn('  dispatch=INLINE on the connection thread');
    WriteLn('  driver requested=', LConfig.UseEventLoop,
            '  resolved eventloop=', GServer.UsingEventLoop);
    WriteLn('Pair with: HorseBenchNghttp2 on ', BENCH_PORT_NGHTTP2_BARE,
            ' — the delta is Horse''s per-request cost.');
    Flush(Output);

    while not GStop do
      Sleep(100);
  finally
    GServer.Free;
  end;
end.
