program HorseBenchRawFPCHttp;

{
  Horse Performance Benchmark — Raw fphttpserver server (no Horse) — Lazarus
  ===========================================================================

  Uses FreePascal's own `fphttpserver` (TFPHTTPServer) directly: no THorse, no
  middleware pipeline, no context pool. Route dispatch is a simple if/else on
  the request method + path.

  WHY THIS PROJECT EXISTS — the FPC raw baseline.
  This is the Lazarus/FPC analog of HorseBenchRawIndy (Delphi): the raw
  *default self-hosted transport* with no Horse on top. On FPC the default Horse
  transport is `fphttpserver` (not Indy), so the meaningful raw baseline here is
  raw fphttpserver. Comparing it against HorseBenchFPCHttp (Horse + fphttpserver)
  isolates the Horse framework overhead on the FPC default transport — exactly as
  raw-indy vs Horse+Indy does on Delphi.

  Threading model:
    TFPHTTPServer.Threaded = True → one worker thread per accepted connection
    (same thread-per-connection model as Indy). At concurrency = 500 this means
    ~500 OS threads. This is expected — it is what the benchmark measures.

  Project type: Lazarus console program.  Target: Linux x86_64 Release (primary);
  also compiles on Windows FPC.

  Port: 9008 (single mode — no middleware variant for raw servers).

  Optional flag:
    --headers   Stamp the 5 SecurityHeaders natively (no Horse).

  Build:
    lazbuild HorseBenchRawFPCHttp.lpi   (or: fpc ...)
    No conditional defines needed — does NOT reference any Horse units.

  Required search path additions (-Fu): none beyond the FPC RTL/fcl-web
    (fphttpserver + httpdefs ship with FreePascal).
}

{$MODE DELPHI}{$H+}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  SysUtils,
  Classes,
  httpdefs,        // TRequest / TResponse members (Method, PathInfo, Content, Code)
  fphttpserver,    // TFPHTTPServer + TFPHTTPConnectionRequest/Response
  Horse.BenchRoutes in '../../../Common/Horse.BenchRoutes.pas';

const
  ALLOC_BODY_SIZE = 1024;

var
  GAddHeaders: Boolean = False;
  GModeLabel:  string  = 'bare';

// ── Request handler (runs on the connection's own worker thread) ──────────────
type
  TRawFPCHttpHandler = class
  public
    procedure HandleRequest(Sender: TObject;
      var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
  end;

procedure TRawFPCHttpHandler.HandleRequest(Sender: TObject;
  var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
begin
  AResponse.ContentType := 'text/plain; charset=utf-8';

  // ── GET /ping ───────────────────────────────────────────────────────────
  if SameText(ARequest.Method, 'GET') and (ARequest.PathInfo = '/ping') then
  begin
    if GAddHeaders then
    begin
      AResponse.SetCustomHeader('X-Content-Type-Options', 'nosniff');
      AResponse.SetCustomHeader('X-Frame-Options', 'DENY');
      AResponse.SetCustomHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
      AResponse.SetCustomHeader('Cache-Control', 'no-store');
      AResponse.SetCustomHeader('Server', 'unknown');
    end;
    AResponse.Content := 'pong';
    AResponse.Code    := 200;
  end

  // ── POST /echo — echo the request body ────────────────────────────────────
  else if SameText(ARequest.Method, 'POST') and (ARequest.PathInfo = '/echo') then
  begin
    AResponse.Content := ARequest.Content;
    AResponse.Code    := 200;
  end

  // ── GET /alloc — 1 KB response ────────────────────────────────────────────
  else if SameText(ARequest.Method, 'GET') and (ARequest.PathInfo = '/alloc') then
  begin
    AResponse.Content := StringOfChar('X', ALLOC_BODY_SIZE);
    AResponse.Code    := 200;
  end

  // ── 404 ───────────────────────────────────────────────────────────────────
  else
  begin
    AResponse.Content := 'Not Found';
    AResponse.Code    := 404;
  end;
end;

// ── Entry point ───────────────────────────────────────────────────────────────
var
  GServer:  TFPHTTPServer;
  GHandler: TRawFPCHttpHandler;

{$IFDEF UNIX}
procedure HandleStopSignal(ASignal: cint); cdecl;
begin
  // Active := False breaks TFPHTTPServer's blocking accept loop and returns
  // control to the main thread after `GServer.Active := True` below.
  if Assigned(GServer) then
    GServer.Active := False;
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
  if GAddHeaders then
    GModeLabel := '+headers (native)';

  GHandler := TRawFPCHttpHandler.Create;
  GServer  := TFPHTTPServer.Create(nil);
  try
    GServer.Threaded  := True;                       // one thread per connection
    GServer.Port      := BENCH_PORT_RAW_FPC_HTTP;
    GServer.OnRequest := GHandler.HandleRequest;

    {$IFDEF UNIX}
    fpSignal(SIGTERM, @HandleStopSignal);
    fpSignal(SIGINT,  @HandleStopSignal);
    fpSignal(SIGPIPE, signalhandler(SIG_IGN));
    {$ENDIF}

    WriteLn(Format('[HorseBench/RawFPCHttp·Laz] Listening on http://127.0.0.1:%d  [%s]  (pure fphttpserver, no Horse)',
      [BENCH_PORT_RAW_FPC_HTTP, GModeLabel]));
    WriteLn('Press Ctrl-C / SIGTERM to stop.');

    GServer.Active := True;   // blocks in the accept loop until Active := False

  finally
    GServer.Free;
    GHandler.Free;
  end;

  WriteLn('[HorseBench/RawFPCHttp·Laz] Stopped cleanly.');
end.
