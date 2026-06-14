program HorseBenchRawMormot;

{
  Horse Performance Benchmark — Raw mORMot2 server (no Horse) — Lazarus
  ======================================================================

  FPC adaptation of Servers/RawMormot/HorseBenchRawMormot.dpr.

  Uses THttpServer directly: no THorse, no middleware pipeline, no context
  pool. Route dispatch is a simple if/else on Ctxt.Url.

  Establishes the mORMot2 transport baseline for FPC. Comparing its throughput
  against HorseBenchMormot (Lazarus) shows the per-request overhead that the
  Horse routing, shadow fields, and context pool add on the FPC/mORMot stack.
  Comparing against HorseBenchRawMormot (Delphi) isolates compiler differences.

  Project type: Lazarus console program.
  Target: Linux x86_64 Release (primary).

  Port: 9005  (single mode — no middleware variant for raw servers).

  Optional flag:
    --headers   Stamp the 5 SecurityHeaders natively (no Horse).

  Build:
    lazbuild HorseBenchRawMormot.lpi

  Required search path additions (-Fu):
    ../../../../../mORMot2/src/core   ← mormot.core.*
    ../../../../../mORMot2/src/net    ← mormot.net.*
}

{$MODE DELPHI}{$H+}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  SysUtils,
  StrUtils,
  Classes,
  mormot.core.base,
  mormot.core.unicode,
  mormot.net.http,
  mormot.net.server,      // THttpServer + THttpServerSocketGeneric (shared base)
  mormot.net.async;       // THttpAsyncServer (--async)

const
  BENCH_PORT_RAW_MORMOT = 9005;
  ALLOC_BODY_SIZE       = 1024;

var
  GAddHeaders: Boolean = False;
  GAsync:      Boolean = False;   // --async:   THttpAsyncServer instead of THttpServer
  GHttpApi:    Boolean = False;   // --httpapi: Windows http.sys THttpApiServer (Win only)
  GModeLabel:  string  = 'bare';

type
  TRawMormotHandler = class
  public
    function Process(Ctxt: THttpServerRequestAbstract): cardinal;
  end;

function TRawMormotHandler.Process(Ctxt: THttpServerRequestAbstract): cardinal;
var
  LUrl:    string;
  LMethod: string;
begin
  LUrl    := Utf8ToString(Ctxt.Url);
  LMethod := Utf8ToString(Ctxt.Method);

  // ── GET /ping ─────────────────────────────────────────────────────────
  if SameText(LMethod, 'GET') and (LUrl = '/ping') then
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
  else if SameText(LMethod, 'POST') and (LUrl = '/echo') then
  begin
    Ctxt.OutContent     := Ctxt.InContent;
    Ctxt.OutContentType := StringToUtf8('text/plain; charset=utf-8');
    Result := 200;
  end

  // ── GET /alloc ────────────────────────────────────────────────────────
  else if SameText(LMethod, 'GET') and (LUrl = '/alloc') then
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

var
  GServer:   THttpServerGeneric;   // THttpServer / THttpAsyncServer (--async) / THttpApiServer (--httpapi)
  GHandler:  TRawMormotHandler;
  GShutdown: Boolean = False;
  {$IFDEF MSWINDOWS}
  GApiServer: THttpApiServer;      // concrete handle for --httpapi (AddUrl/WaitStarted)
  {$ENDIF}

{$IFDEF UNIX}
procedure HandleStopSignal(ASignal: cint); cdecl;
begin
  GShutdown := True;
  if Assigned(GServer) then
    GServer.Shutdown;
end;
{$ENDIF}

function HasSwitch(const ASwitch: string): Boolean;
var
  I: Integer;
  P: string;
begin
  Result := False;
  for I := 1 to ParamCount do
  begin
    P := ParamStr(I);
    while (Length(P) > 0) and (P[1] in ['-', '/']) do Delete(P, 1, 1);
    if SameText(P, ASwitch) then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

begin
  GAddHeaders := HasSwitch('headers');
  GAsync      := HasSwitch('async');
  GHttpApi    := HasSwitch('httpapi');
  if GAddHeaders then
    GModeLabel := '+headers (native)';

  {$IFDEF UNIX}
  fpSignal(SIGTERM, @HandleStopSignal);
  fpSignal(SIGINT,  @HandleStopSignal);
  fpSignal(SIGPIPE, signalhandler(SIG_IGN));
  {$ENDIF}

  GHandler := TRawMormotHandler.Create;
  // Raw transport-level A/B (no Horse). THttpServer / THttpAsyncServer share the
  // THttpServerSocketGeneric.Create signature; THttpApiServer (http.sys) descends
  // from THttpServerGeneric, needs AddUrl, and is FPC/Windows-only — its own
  // {$IFDEF MSWINDOWS} branch. GServer is the common THttpServerGeneric base.
  if GHttpApi then
  begin
    {$IFDEF MSWINDOWS}
    GApiServer := THttpApiServer.Create('', nil, nil, '', [], nil, 32);
    if GApiServer.AddUrl('', StringToUtf8(IntToStr(BENCH_PORT_RAW_MORMOT)), False, '+', True) <> 0 then
    begin
      GApiServer.Free;
      raise Exception.CreateFmt(
        'http.sys AddUrl failed for http://+:%d/ — run as Administrator, or ' +
        'pre-authorize: netsh http add urlacl url=http://+:%d/ user=<account>',
        [BENCH_PORT_RAW_MORMOT, BENCH_PORT_RAW_MORMOT]);
    end;
    GServer := GApiServer;
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

    // WaitStarted is per-family (not on THttpServerGeneric) — call on concrete type.
    {$IFDEF MSWINDOWS}
    if GHttpApi then
      THttpApiServer(GServer).WaitStarted(10)
    else
    {$ENDIF}
      THttpServerSocketGeneric(GServer).WaitStarted(10);

    WriteLn(Format('[HorseBench/RawMormot·Laz] Listening on http://127.0.0.1:%d  [%s]  server=%s',
      [BENCH_PORT_RAW_MORMOT, GModeLabel,
       IfThen(GHttpApi, 'THttpApiServer (http.sys)',
         IfThen(GAsync, 'THttpAsyncServer', 'THttpServer'))]));
    WriteLn('Press Ctrl-C / SIGTERM to stop.');

    while not GShutdown do
      TThread.Sleep(100);

  finally
    GServer.Free;
    GHandler.Free;
  end;

  WriteLn('[HorseBench/RawMormot·Laz] Stopped cleanly.');
end.
