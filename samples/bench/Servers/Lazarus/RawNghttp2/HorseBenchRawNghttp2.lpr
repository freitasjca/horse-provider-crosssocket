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
  Nghttp2.Engine.Epoll;          { linking this is what makes --eventloop work }

{ Horse.BenchRoutes is deliberately NOT used here, even though it owns these
  constants. It `uses Horse` — so importing it would link the entire framework
  into the server whose whole purpose is to measure what the framework costs,
  and under -dHORSE_PROVIDER_NGHTTP2 it also drags in Horse.Provider.Nghttp2
  with its own initialization and class state, alongside the TNghttp2Server
  this file creates directly.

  Three integers are not worth any of that. They are duplicated here, and the
  duplication is the point: this binary must link nothing Horse. Keep them in
  step with Common/Horse.BenchRoutes.pas by hand. }
const
  BASE_PORT              = 9042;   // = BENCH_PORT_RAW_NGHTTP2
  PAIRED_HORSE_PORT      = 9041;   // = BENCH_PORT_NGHTTP2_BARE
  ALLOC_BODY_SIZE        = 1024;   // must equal BenchRoutes' value exactly, or
                                   // /alloc compares two different payloads

var
  GServer:  TNghttp2Server;
  GStop:    Boolean = False;
  GAllocBody: TBytes;
  { Diagnostic. The first version of this server accepted connections,
    negotiated h2c, and then never answered — with no exception and nothing in
    the log. Reading the source could not distinguish "the handler never ran"
    from "it ran and the response never reached the wire", and those have
    completely different causes. One counter settles it. }
  GHandlerCalls: Integer = 0;

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
  { Trace BEFORE touching the stream. The previous probe sat after two
    Header[] reads, so "handler never ran" and "handler raised on its first
    statement" produced identical output — no line either way. }
  Inc(GHandlerCalls);
  if GHandlerCalls = 1 then
  begin
    WriteLn('  [handler] ENTERED');
    Flush(Output);
  end;

  { try/except is not just diagnostics — it belongs here.

    This runs inside a libnghttp2 C callback. An exception unwinding through
    C is undefined behaviour at best; in practice it abandons the callback
    chain, so the response is never submitted and the stream stays open
    forever — a hung connection with no error anywhere, which is exactly the
    symptom this server had. The Horse provider wraps its handler for the
    same reason; a raw server has to do it itself. }
  try
  LPath   := AStream.Header[':path'];
  LMethod := AStream.Header[':method'];
  if GHandlerCalls = 1 then
  begin
    WriteLn('  [handler] method="', LMethod, '" path="', LPath, '"');
    Flush(Output);
  end;

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
  except
    on E: Exception do
    begin
      WriteLn('  [handler] EXCEPTION ', E.ClassName, ': ', E.Message);
      Flush(Output);
      // Answer anyway. A stream left unanswered hangs the client with no
      // diagnosis; a 500 at least terminates it and names the failure.
      try
        AStream.StatusCode := 500;
        AStream.Send(TEncoding.UTF8.GetBytes('handler error'));
      except
        // Nothing more can be done for this stream.
      end;
    end;
  end;
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

  { INLINE, always. AsyncDispatch tells the session to defer responses to a
    queue for a worker pool to feed — but a pool is something the Horse
    provider builds, not something TNghttp2Server owns, so there is no pool
    here to feed it. Requesting async dispatch in a server that cannot
    dispatch is asking for a stall.

    It also makes the floor measurement honest: pair this with the wrapped
    server's --inline mode and the ONLY difference between the two is Horse.
    --workers is still accepted so the invocation matches, and ignored. }
  LConfig.WorkerThreads  := 0;
  LConfig.AsyncDispatch  := False;
  LConfig.UseEventLoop   := HasSwitch('eventloop');

  GServer := TNghttp2Server.Create;
  try
    GServer.OnRequest := RawBenchHandler;
    GServer.Start(LConfig);

    WriteLn('HorseBenchRawNghttp2  port=', BASE_PORT,
            '  protocol=HTTP/2 (h2c)  framework=NONE');
    WriteLn('  dispatch=INLINE on the connection thread (no pool exists here)');
    if LWorkers > 0 then
      WriteLn('  note: --workers=', LWorkers, ' accepted and IGNORED — see source');
    WriteLn('  driver requested=', LConfig.UseEventLoop,
            '  resolved eventloop=', GServer.UsingEventLoop);
    WriteLn('  OnRequest assigned=', Assigned(GServer.OnRequest));
    WriteLn('Pair with: HorseBenchNghttp2 on ', PAIRED_HORSE_PORT,
            ' — the delta is Horse''s per-request cost.');
    Flush(Output);

    while not GStop do
      Sleep(100);
  finally
    GServer.Free;
  end;
end.
