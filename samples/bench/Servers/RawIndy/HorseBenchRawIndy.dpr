program HorseBenchRawIndy;

{
  Horse Performance Benchmark — Raw Indy server (no Horse, NO WebBroker)
  ======================================================================

  Uses TIdHTTPServer directly: no THorse, no TIdHTTPWebBrokerBridge, no
  WebBroker TWebRequestHandler, no THorseRequest/Response, no middleware
  pipeline, no context pool. Route dispatch is a simple if/else on
  ARequestInfo.Document.

  WHY THIS PROJECT EXISTS — the missing baseline.
  RawCrossSocket and RawMormot give the no-Horse transport baseline for those
  two stacks; this is the equivalent for Indy. It lets us DECOMPOSE Indy's
  behaviour into its two independent layers:

    Raw Indy (this)      = the Indy TRANSPORT only (thread-per-connection).
    Horse + Indy         = Raw Indy + WebBroker (TWebRequestHandler) + Horse provider.

  Expected contrast (confirm on the box):
    * Raw Indy has NO WebBroker, so NO MaxConnections=32 cap and NO
      EWebBrokerException -> it should show ~0 HTTP 500 even with header
      middleware at c=100 (unlike Horse+Indy, which sheds ~60% until --maxconn).
    * Raw Indy is STILL thread-per-connection, so it should STILL show the
      tail-latency blow-up under oversubscription (threads ~= connections).
    * If Raw Indy + headers does NOT collapse the way Horse+Indy + headers does
      (-55% throughput), that proves the collapse is the WebBroker FCriticalSection
      serialization, NOT the Indy thread model.

  Flags:
    --headers            stamp the 5 SecurityHeaders natively (no Horse)
    --maxconn N          TIdHTTPServer.MaxConnections (default 0 = unlimited;
                         NOTE: this is the Indy connection cap, NOT a WebBroker
                         cap — raw Indy has no WebBroker, so no 32-cap / no 500s.
                         Leave it 0 to measure the true thread-per-connection
                         baseline: all c connections accepted = c threads.)
    --listenqueue N      TIdHTTPServer.ListenQueue (default 15) — raise it to >= c
                         to avoid "others"/connectex refusals at the connection ramp.

  Project type: Console Application. Target: Win64 Release.
  Port: 9006 (single port — no middleware-port split for raw servers).
  No conditional defines needed — does NOT reference any Horse units.

  Required search path entries (Project -> Options -> Library path):
    the Indy source/library paths already used by HorseBenchIndy.dproj.
}

{$APPTYPE CONSOLE}

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  System.SysUtils,
  System.Classes,
  IdHTTPServer,
  IdCustomHTTPServer,   // TIdHTTPRequestInfo / TIdHTTPResponseInfo / THTTPCommandType
  IdContext;

const
  BENCH_PORT_RAW_INDY = 9006;
  ALLOC_BODY_SIZE     = 1024;

var
  GAddHeaders:  Boolean = False;  // --headers
  GMaxConn:     Integer = 0;      // --maxconn N      (0 = unlimited = true baseline)
  GListenQueue: Integer = 0;      // --listenqueue N  (0 = Indy default 15)
  GModeLabel:   string  = 'bare';

  GServer:   TIdHTTPServer;
  GShutdown: Boolean = False;

// ── Request handler (runs on the connection's own Indy thread) ────────────────
type
  TRawIndyHandler = class
  public
    procedure HandleCommandGet(AContext: TIdContext;
      ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
  end;

procedure TRawIndyHandler.HandleCommandGet(AContext: TIdContext;
  ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
var
  LDoc: string;
  LStream: TMemoryStream;
begin
  LDoc := ARequestInfo.Document;
  AResponseInfo.ContentType := 'text/plain; charset=utf-8';

  // ── GET /ping ─────────────────────────────────────────────────────────
  if (ARequestInfo.CommandType = hcGET) and (LDoc = '/ping') then
  begin
    // --headers: same 5 headers SecurityHeaders adds, set natively (no Horse).
    if GAddHeaders then
    begin
      AResponseInfo.CustomHeaders.AddValue('X-Content-Type-Options', 'nosniff');
      AResponseInfo.CustomHeaders.AddValue('X-Frame-Options', 'DENY');
      AResponseInfo.CustomHeaders.AddValue('Referrer-Policy', 'strict-origin-when-cross-origin');
      AResponseInfo.CustomHeaders.AddValue('Cache-Control', 'no-store');
      AResponseInfo.CustomHeaders.AddValue('Server', 'unknown');
    end;
    AResponseInfo.ContentText := 'pong';
    AResponseInfo.ResponseNo := 200;
  end

  // ── POST /echo — echo the request body bytes ──────────────────────────
  else if (ARequestInfo.CommandType = hcPOST) and (LDoc = '/echo') then
  begin
    if ARequestInfo.PostStream <> nil then
    begin
      LStream := TMemoryStream.Create;       // Indy frees it (FreeContentStream)
      ARequestInfo.PostStream.Position := 0;
      LStream.CopyFrom(ARequestInfo.PostStream, ARequestInfo.PostStream.Size);
      LStream.Position := 0;
      AResponseInfo.ContentStream := LStream;
    end
    else
      AResponseInfo.ContentText := '';
    AResponseInfo.ResponseNo := 200;
  end

  // ── GET /alloc — 1 KB response ────────────────────────────────────────
  else if (ARequestInfo.CommandType = hcGET) and (LDoc = '/alloc') then
  begin
    AResponseInfo.ContentText := StringOfChar('X', ALLOC_BODY_SIZE);
    AResponseInfo.ResponseNo := 200;
  end

  // ── 404 ───────────────────────────────────────────────────────────────
  else
  begin
    AResponseInfo.ContentText := 'Not Found';
    AResponseInfo.ResponseNo := 404;
  end;
end;

// ── Entry point ───────────────────────────────────────────────────────────────
var
  GHandler: TRawIndyHandler;

{$IFDEF MSWINDOWS}
function CtrlHandler(dwCtrlType: DWORD): BOOL; stdcall;
begin
  case dwCtrlType of
    CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT,
    CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT:
      begin
        GShutdown := True;
        if Assigned(GServer) then
          GServer.Active := False;
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

begin
  GAddHeaders  := HasSwitch('headers');
  GMaxConn     := GetSwitchInt('maxconn', 0);
  GListenQueue := GetSwitchInt('listenqueue', 0);
  if GAddHeaders then
    GModeLabel := '+headers (native)';
  {$IFDEF MSWINDOWS}
  SetConsoleCtrlHandler(@CtrlHandler, True);
  {$ENDIF}

  GHandler := TRawIndyHandler.Create;
  GServer  := TIdHTTPServer.Create(nil);
  try
    GServer.DefaultPort  := BENCH_PORT_RAW_INDY;
    GServer.KeepAlive    := True;                 // HTTP/1.1 keep-alive (match the others)
    GServer.OnCommandGet := GHandler.HandleCommandGet;
    if GMaxConn > 0 then
      GServer.MaxConnections := GMaxConn;         // Indy connection cap (NOT a WebBroker cap)
    if GListenQueue > 0 then
      GServer.ListenQueue := GListenQueue;        // TCP accept backlog (default 15)
    GServer.Active := True;

    WriteLn(Format('[HorseBench/RawIndy] Listening on http://127.0.0.1:%d  [%s]  (pure TIdHTTPServer, no WebBroker)',
      [BENCH_PORT_RAW_INDY, GModeLabel]));
    if GMaxConn > 0 then
      WriteLn(Format('  MaxConnections=%d', [GMaxConn]));
    if GListenQueue > 0 then
      WriteLn(Format('  ListenQueue=%d', [GListenQueue]));
    WriteLn('Press Ctrl-C to stop.');

    while not GShutdown do
      TThread.Sleep(100);

  finally
    GServer.Active := False;
    GServer.Free;
    GHandler.Free;
  end;

  WriteLn('[HorseBench/RawIndy] Stopped cleanly.');
end.
