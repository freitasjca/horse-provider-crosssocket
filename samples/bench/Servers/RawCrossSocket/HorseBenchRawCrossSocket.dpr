program HorseBenchRawCrossSocket;

{
  Horse Performance Benchmark — Raw CrossSocket server (no Horse framework)
  =========================================================================

  Uses TCrossHttpServer directly: no THorse, no THorseRequest/Response,
  no middleware pipeline, no context pool.  Route matching uses CrossSocket's
  own built-in trie router (Get / Post methods on ICrossHttpServer).

  This binary establishes the transport baseline.  Comparing its throughput
  against HorseBenchCrossSocket.exe shows the per-request overhead that the
  Horse routing, middleware pipeline, shadow fields, and context pool add.

  Project type: Console Application.  Target: Win64 Release.
  No conditional defines needed — does NOT reference any Horse units.

  Port: 9004 (single mode — no middleware variant for raw servers).

  Required search path entries (Project → Options → Library path):
    <Delphi-Cross-Socket-repo>\Net
    <Delphi-Cross-Socket-repo>\Utils
    ... (same paths used by HorseBenchCrossSocket.dproj)
}

{$APPTYPE CONSOLE}

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  System.SysUtils,
  System.Classes,
  Net.CrossHttpServer,
  Net.CrossHttpParams;

const
  BENCH_PORT_RAW_CROSSSOCKET = 9004;
  ALLOC_BODY_SIZE            = 1024;

var
  GServer:     TCrossHttpServer;
  GShutdown:   Boolean = False;
  GAddHeaders: Boolean = False;   // --headers: stamp the 5 SecurityHeaders natively
  GModeLabel:  string  = 'bare';

{$IFDEF MSWINDOWS}
function CtrlHandler(dwCtrlType: DWORD): BOOL; stdcall;
begin
  case dwCtrlType of
    CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT,
    CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT:
      begin
        GShutdown := True;
        if Assigned(GServer) then
          GServer.Stop;
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
  if GAddHeaders then
    GModeLabel := '+headers (native)';
  {$IFDEF MSWINDOWS}
  SetConsoleCtrlHandler(@CtrlHandler, True);
  {$ENDIF}

  GServer := TCrossHttpServer.Create(0 {IoThreads: 0 = CPU count}, False {Ssl});
  try
    // ── GET /ping — fixed response, no body ──────────────────────────────
    GServer.Get('/ping',
      procedure(const ARequest: ICrossHttpRequest;
                const AResponse: ICrossHttpResponse;
                var AHandled: Boolean)
      begin
        AResponse.StatusCode := 200;
        AResponse.ContentType := 'text/plain; charset=utf-8';
        // --headers: same 5 headers SecurityHeaders adds, set natively (no Horse).
        // Decisive test: if this sheds ~60% under bombardier keep-alive c=100, the
        // defect is in the CrossSocket transport, not Horse.
        if GAddHeaders then
        begin
          AResponse.Header['X-Content-Type-Options'] := 'nosniff';
          AResponse.Header['X-Frame-Options'] := 'DENY';
          AResponse.Header['Referrer-Policy'] := 'strict-origin-when-cross-origin';
          AResponse.Header['Cache-Control'] := 'no-store';
          AResponse.Header['Server'] := 'unknown';
        end;
        AResponse.Send('pong');
        AHandled := True;
      end);

    // ── POST /echo — echo request body bytes ─────────────────────────────
    // Body is TMemoryStream when BodyType = btBinary (no Content-Type header).
    // We echo the raw bytes — no string conversion — to stay as close to
    // transport speed as possible.
    GServer.Post('/echo',
      procedure(const ARequest: ICrossHttpRequest;
                const AResponse: ICrossHttpResponse;
                var AHandled: Boolean)
      var
        LStream: TStream;
        LBytes:  TBytes;
      begin
        AResponse.StatusCode := 200;
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

    // ── GET /alloc — 1 KB heap allocation ────────────────────────────────
    GServer.Get('/alloc',
      procedure(const ARequest: ICrossHttpRequest;
                const AResponse: ICrossHttpResponse;
                var AHandled: Boolean)
      begin
        AResponse.StatusCode := 200;
        AResponse.ContentType := 'text/plain; charset=utf-8';
        AResponse.Send(StringOfChar('X', ALLOC_BODY_SIZE));
        AHandled := True;
      end);

    GServer.Port := BENCH_PORT_RAW_CROSSSOCKET;
    GServer.Addr := '';   // all interfaces
    GServer.Start;

    WriteLn(Format('[HorseBench/RawCrossSocket] Listening on http://127.0.0.1:%d  [%s]',
      [BENCH_PORT_RAW_CROSSSOCKET, GModeLabel]));
    WriteLn('Press Ctrl-C to stop.');

    while not GShutdown do
      TThread.Sleep(100);

  finally
    GServer.Free;
  end;

  WriteLn('[HorseBench/RawCrossSocket] Stopped cleanly.');
end.
