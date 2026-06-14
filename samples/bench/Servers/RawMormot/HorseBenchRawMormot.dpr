program HorseBenchRawMormot;

{
  Horse Performance Benchmark — Raw mORMot2 server (no Horse framework)
  ======================================================================

  Uses THttpServer directly: no THorse, no THorseRequest/Response,
  no middleware pipeline, no context pool.  Route dispatch is a simple
  if/else on Ctxt.Url — no trie, no route tree.

  This binary establishes the mORMot2 transport baseline.  Comparing its
  throughput against HorseBenchMormot.exe shows the per-request overhead
  that the Horse routing, middleware pipeline, and shadow fields add on
  top of the mORMot2 IOCP/thread-pool stack.

  Project type: Console Application.  Target: Win64 Release.
  Conditional defines (Project → Options → Conditional Defines):
    HORSE_PROVIDER_MORMOT   (activates mORMot2 paths in Horse.pas if present;
                              not strictly required here since we do not use Horse)

  Port: 9005 (single mode — no middleware variant for raw servers).

  Optional flags:
    --headers   Stamp the 5 SecurityHeaders natively (no Horse).
    --async     Host THttpAsyncServer (non-blocking event loop) instead of the
                default THttpServer thread pool. Pure transport-level A/B — this
                is the no-Horse baseline for the Horse+mORMot --async comparison.
    --httpapi   Host the Windows http.sys server (THttpApiServer). WINDOWS ONLY
                (raises elsewhere). No-Horse baseline for Horse+mORMot --httpapi.
                Needs admin rights or: netsh http add urlacl url=http://+:9005/ user=<acct>.
                If both --httpapi and --async are given, --httpapi wins.

  Required search path entries (Project → Options → Library path):
    <mormot2-repo>\src\net\mormot.net.async.pas  (THttpAsyncServer, for --async)
    <mormot2-repo>\src\...          (full mORMot2 source tree)
    ... (same paths used by HorseBenchMormot.dproj)
}

{$APPTYPE CONSOLE}

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  System.SysUtils,
  System.Classes,         // TThread.Sleep (cross-platform)
  System.StrUtils,        // IfThen (server-kind label)
  mormot.core.base,       // RawUtf8, RawByteString
  mormot.core.unicode,    // StringToUtf8, Utf8ToString
  mormot.net.http,        // THttpServerRequestAbstract, HTTP status codes
  mormot.net.server,      // THttpServer + THttpServerSocketGeneric (shared base)
  mormot.net.async;       // THttpAsyncServer (--async)

const
  BENCH_PORT_RAW_MORMOT = 9005;
  ALLOC_BODY_SIZE       = 1024;

var
  // --headers: stamp the 5 SecurityHeaders natively (no Horse). Declared here so
  // TRawMormotHandler.Process (below) can read it. Decisive test: if this sheds
  // ~60% under bombardier keep-alive c=100, the defect is in the mORMot transport.
  GAddHeaders: Boolean = False;
  GAsync:      Boolean = False;   // --async:   THttpAsyncServer instead of THttpServer
  GHttpApi:    Boolean = False;   // --httpapi: Windows http.sys THttpApiServer (Win only)
  GModeLabel:  string  = 'bare';

// ── Request handler ───────────────────────────────────────────────────────────
//
// mORMot OnRequest is a method-of-object; we bridge to this thin class.
// Process() runs on one of THttpServer's IOCP thread-pool threads.

type
  TRawMormotHandler = class
  public
    function Process(Ctxt: THttpServerRequestAbstract): cardinal;
  end;

function TRawMormotHandler.Process(Ctxt: THttpServerRequestAbstract): cardinal;
var
  LUrl: string;
begin
  LUrl := Utf8ToString(Ctxt.Url);

  // ── GET /ping ─────────────────────────────────────────────────────────
  if SameText(Utf8ToString(Ctxt.Method), 'GET') and (LUrl = '/ping') then
  begin
    Ctxt.OutContent     := 'pong';
    Ctxt.OutContentType := StringToUtf8('text/plain; charset=utf-8');
    if GAddHeaders then
      Ctxt.OutCustomHeaders := StringToUtf8(
        'X-Content-Type-Options: nosniff'#13#10 +
        'X-Frame-Options: DENY'#13#10 +
        'Referrer-Policy: strict-origin-when-cross-origin'#13#10 +
        'Cache-Control: no-store'#13#10 +
        'Server: unknown');
    Result := 200;
  end

  // ── POST /echo ────────────────────────────────────────────────────────
  // Ctxt.InContent is RawByteString — the fully buffered request body.
  // Echo it back directly without decoding to string.
  else if SameText(Utf8ToString(Ctxt.Method), 'POST') and (LUrl = '/echo') then
  begin
    Ctxt.OutContent     := Ctxt.InContent;
    Ctxt.OutContentType := StringToUtf8('text/plain; charset=utf-8');
    Result := 200;
  end

  // ── GET /alloc ────────────────────────────────────────────────────────
  else if SameText(Utf8ToString(Ctxt.Method), 'GET') and (LUrl = '/alloc') then
  begin
    Ctxt.OutContent     := StringToUtf8(StringOfChar('X', ALLOC_BODY_SIZE));
    Ctxt.OutContentType := StringToUtf8('text/plain; charset=utf-8');
    Result := 200;
  end

  // ── 404 ───────────────────────────────────────────────────────────────
  else
  begin
    Ctxt.OutContent     := 'Not Found';
    Ctxt.OutContentType := StringToUtf8('text/plain; charset=utf-8');
    Result := 404;
  end;
end;

// ── Entry point ───────────────────────────────────────────────────────────────

var
  GServer:   THttpServerGeneric;   // THttpServer / THttpAsyncServer (--async) / THttpApiServer (--httpapi)
  GHandler:  TRawMormotHandler;
  GShutdown: Boolean = False;

{$IFDEF MSWINDOWS}
function CtrlHandler(dwCtrlType: DWORD): BOOL; stdcall;
begin
  case dwCtrlType of
    CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT,
    CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT:
      begin
        GShutdown := True;
        if Assigned(GServer) then
          GServer.Shutdown;   // stops accepting; drains thread pool
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

begin
  GAddHeaders := HasSwitch('headers');
  GAsync      := HasSwitch('async');
  GHttpApi    := HasSwitch('httpapi');
  if GAddHeaders then
    GModeLabel := '+headers (native)';
  {$IFDEF MSWINDOWS}
  SetConsoleCtrlHandler(@CtrlHandler, True);
  {$ENDIF}

  GHandler := TRawMormotHandler.Create;
  // Raw transport-level A/B (no Horse in the path). THttpServer / THttpAsyncServer
  // share the THttpServerSocketGeneric.Create signature; THttpApiServer (http.sys)
  // descends from THttpServerGeneric, has a different constructor + AddUrl, and is
  // Windows-only — so it sits in its own {$IFDEF MSWINDOWS} branch. GServer is the
  // common THttpServerGeneric base; WaitStarted is called per-family below.
  if GHttpApi then
  begin
    {$IFDEF MSWINDOWS}
    var LApi := THttpApiServer.Create(
      '', nil, nil, '', [], nil, 32);
    if LApi.AddUrl('', StringToUtf8(IntToStr(BENCH_PORT_RAW_MORMOT)), False, '+', True) <> 0 then
    begin
      LApi.Free;
      raise Exception.CreateFmt(
        'http.sys AddUrl failed for http://+:%d/ — run as Administrator, or ' +
        'pre-authorize: netsh http add urlacl url=http://+:%d/ user=<account>',
        [BENCH_PORT_RAW_MORMOT, BENCH_PORT_RAW_MORMOT]);
    end;
    GServer := LApi;
    {$ELSE}
    raise Exception.Create('--httpapi (http.sys) is Windows-only');
    {$ENDIF}
  end
  else if GAsync then
    GServer := THttpAsyncServer.Create(
      StringToUtf8(IntToStr(BENCH_PORT_RAW_MORMOT)), nil, nil, '', 32)
  else
    GServer := THttpServer.Create(
      StringToUtf8(IntToStr(BENCH_PORT_RAW_MORMOT)), nil, nil, '', 32);
  try
    GServer.OnRequest := GHandler.Process;

    // WaitStarted is not on THttpServerGeneric and its signature differs per
    // family — call it on the concrete type.
    {$IFDEF MSWINDOWS}
    if GHttpApi then
      THttpApiServer(GServer).WaitStarted(10)
    else
    {$ENDIF}
      THttpServerSocketGeneric(GServer).WaitStarted(10);

    WriteLn(Format('[HorseBench/RawMormot] Listening on http://127.0.0.1:%d  [%s]  server=%s',
      [BENCH_PORT_RAW_MORMOT, GModeLabel,
       IfThen(GHttpApi, 'THttpApiServer (http.sys)',
         IfThen(GAsync, 'THttpAsyncServer', 'THttpServer'))]));
    WriteLn('Press Ctrl-C to stop.');

    while not GShutdown do
      TThread.Sleep(100);

  finally
    GServer.Free;
    GHandler.Free;
  end;

  WriteLn('[HorseBench/RawMormot] Stopped cleanly.');
end.
