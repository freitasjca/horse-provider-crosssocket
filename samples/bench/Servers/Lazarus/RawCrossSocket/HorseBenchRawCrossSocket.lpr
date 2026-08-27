program HorseBenchRawCrossSocket;

{
  Horse Performance Benchmark — Raw CrossSocket server (no Horse) — Lazarus
  ==========================================================================

  FPC adaptation of Servers/RawCrossSocket/HorseBenchRawCrossSocket.dpr.

  Uses TCrossHttpServer directly: no THorse, no middleware pipeline, no context
  pool. Route dispatch uses CrossSocket's built-in trie router. This binary
  establishes the transport baseline — comparing its throughput against
  HorseBenchCrossSocket (Lazarus) shows the per-request overhead that the Horse
  routing + shadow fields + context pool add.

  Project type: Lazarus console program.
  Target: Linux x86_64 Release (primary).

  Port: 9004  (single mode — no middleware variant for raw servers).

  Optional flag:
    --headers   Stamp the 5 SecurityHeaders natively (no Horse).

  Build:
    lazbuild HorseBenchRawCrossSocket.lpi   (or: fpc ...)
    No conditional defines needed.

  Required search path additions (-Fu):
    ../../../../../Delphi-Cross-Socket/Net
    ../../../../../Delphi-Cross-Socket/Utils
    ../../../../../Delphi-Cross-Socket/Lib/OpenSSL  (if TLS paths are needed)
}

{$MODE DELPHI}{$H+}
{$APPTYPE CONSOLE}

uses
  // cthreads MUST be first, before any unit that can start a thread. Without
  // it FPC links the single-threaded RTL and the server dies at startup with
  // "Runtime error 232" — a bare number whose text ("This binary has no thread
  // support compiled in") never reaches the console. The three bench servers
  // that already had it are exactly the three that ran on 2026-08-27.
  {$IFDEF UNIX} cthreads, BaseUnix, {$ENDIF}
  SysUtils,
  Classes,
  Net.SocketAPI,
  Net.CrossSocket.Base,
  Net.CrossHttpServer,
  Net.CrossHttpParams;

const
  BENCH_PORT_RAW_CROSSSOCKET = 9004;
  ALLOC_BODY_SIZE            = 1024;

var
  GServer:     TCrossHttpServer;
  // FIX-BENCH-REFCOUNT-1. TCrossHttpServer descends from TInterfacedObject
  // (Net.CrossSocket.Base: TCrossSocketBase = class abstract(TInterfacedObject,
  // ICrossSocket)), so a plain object reference leaves FRefCount at 0. The
  // first internal path that takes an ICrossHttpServer into a local destroys
  // the server when that local goes out of scope -- an EAccessViolation at
  // startup, before the listening banner prints.
  //
  // This is the same defect Horse.Provider.CrossSocket.Server.pas fixes as
  // FIX-REFCOUNT-1; the raw server never got it, which is exactly why the
  // Horse row ran and this one crashed. Hold a permanent interface reference
  // for the object's whole lifetime, and release THAT rather than calling
  // Free -- _Release invokes Destroy.
  GServerRef:  ICrossHttpServer;
  GShutdown:   Boolean = False;
  GAddHeaders: Boolean = False;
  GModeLabel:  string  = 'bare';

type
  TConnTuner = class
  public
    procedure OnConnected(const Sender: TObject; const AConnection: ICrossConnection);
  end;

var
  GTuner: TConnTuner;

{ Disable Nagle (TCP_NODELAY) per connection. Without this, on Linux loopback
  the small keep-alive responses collide with the ~40 ms delayed ACK, causing a
  flat ~44 ms/request floor (~2 270 RPS) that masks the real numbers. }
procedure TConnTuner.OnConnected(const Sender: TObject;
  const AConnection: ICrossConnection);
begin
  TSocketAPI.SetTcpNoDelay(AConnection.Socket, True);
end;

{$IFDEF UNIX}
procedure HandleStopSignal(ASignal: cint); cdecl;
begin
  GShutdown := True;
  if Assigned(GServer) then
    GServer.Stop;
end;
{$ENDIF}

function HasSwitch(const ASwitch: string): Boolean;
var
  I: Integer;
  // FIX-BENCH-INLINEVAR-1. Was `var P := ParamStr(I);` inside the loop -- a
  // Delphi 10.3+ inline variable declaration, which FPC does not support at
  // any version. It reports it as
  //   Error: Illegal expression
  //   Fatal: Syntax error, ";" expected but "identifier P" found
  // i.e. as a malformed statement rather than as an unsupported feature.
  // CLAUDE.md's dual-compilation rule forbids Delphi-only syntax in files
  // shared with FPC unless guarded; hoisting the declaration needs no guard
  // and compiles identically on both.
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
  if GAddHeaders then
    GModeLabel := '+headers (native)';

  {$IFDEF UNIX}
  fpSignal(SIGTERM, @HandleStopSignal);
  fpSignal(SIGINT,  @HandleStopSignal);
  {$ENDIF}

  GTuner  := TConnTuner.Create;
  GServer := TCrossHttpServer.Create(0 {IoThreads: 0 = CPU count}, False {Ssl});
  GServerRef := GServer;   // FIX-BENCH-REFCOUNT-1 — keep FRefCount >= 1
  GServer.OnConnected := GTuner.OnConnected;
  try
    // ── GET /ping ───────────────────────────────────────────────────────
    GServer.Get('/ping',
      procedure(const ARequest: ICrossHttpRequest;
                const AResponse: ICrossHttpResponse;
                var AHandled: Boolean)
      begin
        AResponse.StatusCode  := 200;
        AResponse.ContentType := 'text/plain; charset=utf-8';
        if GAddHeaders then
        begin
          AResponse.Header['X-Content-Type-Options'] := 'nosniff';
          AResponse.Header['X-Frame-Options']        := 'DENY';
          AResponse.Header['Referrer-Policy']        := 'strict-origin-when-cross-origin';
          AResponse.Header['Cache-Control']          := 'no-store';
          AResponse.Header['Server']                 := 'unknown';
        end;
        AResponse.Send('pong');
        AHandled := True;
      end);

    // ── POST /echo ──────────────────────────────────────────────────────
    GServer.Post('/echo',
      procedure(const ARequest: ICrossHttpRequest;
                const AResponse: ICrossHttpResponse;
                var AHandled: Boolean)
      var
        LStream: TStream;
        LBytes:  TBytes;
      begin
        AResponse.StatusCode  := 200;
        AResponse.ContentType := 'text/plain; charset=utf-8';
        if ARequest.BodyType = btBinary then
        begin
          LStream := ARequest.Body as TStream;
          LStream.Position := 0;
          SetLength(LBytes, LStream.Size);
          if LStream.Size > 0 then
            LStream.ReadBuffer(LBytes[0], LStream.Size);
          AResponse.Send(LBytes);
        end
        else
          AResponse.Send(TBytes(nil));
        AHandled := True;
      end);

    // ── GET /alloc ──────────────────────────────────────────────────────
    GServer.Get('/alloc',
      procedure(const ARequest: ICrossHttpRequest;
                const AResponse: ICrossHttpResponse;
                var AHandled: Boolean)
      begin
        AResponse.StatusCode  := 200;
        AResponse.ContentType := 'text/plain; charset=utf-8';
        AResponse.Send(StringOfChar('X', ALLOC_BODY_SIZE));
        AHandled := True;
      end);

    GServer.Port := BENCH_PORT_RAW_CROSSSOCKET;
    GServer.Addr := '';
    GServer.Start;

    WriteLn(Format('[HorseBench/RawCrossSocket·Laz] Listening on http://127.0.0.1:%d  [%s]',
      [BENCH_PORT_RAW_CROSSSOCKET, GModeLabel]));
    WriteLn('Press Ctrl-C / SIGTERM to stop.');

    while not GShutdown do
      TThread.Sleep(100);

  finally
    // FIX-BENCH-REFCOUNT-1: release the interface, never Free the object.
    GServerRef := nil;
    GServer    := nil;
    GTuner.Free;
  end;

  WriteLn('[HorseBench/RawCrossSocket·Laz] Stopped cleanly.');
end.
