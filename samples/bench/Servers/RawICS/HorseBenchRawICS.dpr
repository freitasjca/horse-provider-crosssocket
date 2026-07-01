program HorseBenchRawICS;

{
  Horse Performance Benchmark — Raw OverbyteICS server (no Horse framework)
  =========================================================================

  Uses ICS THttpServer directly: no THorse, no THorseRequest/Response, no
  middleware pipeline, no worker pool, no marshal-back. Routes are matched with
  a plain if/else on THttpConnection.Path, and answered inline on the ICS
  message-loop thread with AnswerString.

  This binary establishes the ICS transport baseline. Comparing its throughput
  against HorseBenchICS.exe shows the per-request overhead the Horse routing,
  middleware pipeline, shadow fields, context pool, and worker-pool marshal-back
  add on top of raw ICS.

  Project type: Console Application. Delphi only (ICS is Delphi-only; Windows +
  POSIX/Linux64). No Horse units referenced.

  Port: 9010 (single mode — no middleware variant for raw servers).

  Required search path: the ICS Source/ folder (same paths used by
  HorseBenchICS.dproj).

  POST note: unlike mORMot (Ctxt.InContent) and Indy (PostStream), ICS does NOT
  auto-buffer the request body — OnPostDocument requests the data (hgAcceptData)
  and OnPostedData drains it off the socket with Conn.Receive into a per-
  connection buffer, then answers once Content-Length bytes have arrived.
}

{$APPTYPE CONSOLE}

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  OverbyteIcsHttpSrv,
  OverbyteIcsWSocket;

const
  BENCH_PORT_RAW_ICS = 9010;
  ALLOC_BODY_SIZE    = 1024;

  EXTRA_HEADERS =
    'X-Content-Type-Options: nosniff'#13#10 +
    'X-Frame-Options: DENY'#13#10 +
    'Referrer-Policy: strict-origin-when-cross-origin'#13#10 +
    'Cache-Control: no-store'#13#10 +
    'Server: unknown'#13#10;

type
  { Per-connection POST body accumulator (ICS does not buffer the body for us). }
  TRawPost = class
    Buffer:   TBytes;
    Received: Int64;
    Capacity: Int64;
  end;

  { Event sink — ICS events are methods-of-object. }
  TRawICSHandler = class
    procedure OnGetDocument(Sender: TObject; Client: TObject; var Flags: THttpGetFlag);
    procedure OnPostDocument(Sender: TObject; Client: TObject; var Flags: THttpGetFlag);
    procedure OnPostedData(Sender: TObject; Client: TObject; ErrCode: Word);
  end;

var
  GServer:     THttpServer;
  GHandler:    TRawICSHandler;
  GPosts:      TDictionary<THttpConnection, TRawPost>;
  GAddHeaders: Boolean = False;   // --headers : stamp the 5 SecurityHeaders natively
  GModeLabel:  string  = 'bare';

function Hdr: string;
begin
  if GAddHeaders then Result := EXTRA_HEADERS else Result := '';
end;

procedure Answer(Conn: THttpConnection; var Flags: THttpGetFlag;
  const ABody: string);
begin
  // ICS message-loop thread; AnswerString sets Flags := hgWillSendMySelf.
  Conn.AnswerString(Flags, '200 OK', 'text/plain; charset=utf-8', Hdr, ABody);
end;

{ TRawICSHandler }

procedure TRawICSHandler.OnGetDocument(Sender: TObject; Client: TObject;
  var Flags: THttpGetFlag);
var
  Conn: THttpConnection;
begin
  Conn := THttpConnection(Client);
  if Conn.Path = '/ping' then
    Answer(Conn, Flags, 'pong')
  else if Conn.Path = '/alloc' then
    Answer(Conn, Flags, StringOfChar('X', ALLOC_BODY_SIZE))
  else
  begin
    Conn.AnswerString(Flags, '404 Not Found', 'text/plain; charset=utf-8', '', 'Not Found');
  end;
end;

procedure TRawICSHandler.OnPostDocument(Sender: TObject; Client: TObject;
  var Flags: THttpGetFlag);
var
  Conn:  THttpConnection;
  LPost: TRawPost;
begin
  Conn := THttpConnection(Client);
  if Conn.Path <> '/echo' then
  begin
    Conn.AnswerString(Flags, '404 Not Found', 'text/plain; charset=utf-8', '', 'Not Found');
    Exit;
  end;

  // Empty body (no/zero Content-Length): answer immediately — ICS would not fire
  // OnPostedData, so requesting hgAcceptData would hang the connection.
  if Conn.RequestContentLength <= 0 then
  begin
    Answer(Conn, Flags, '');
    Exit;
  end;

  LPost := TRawPost.Create;
  LPost.Capacity := Conn.RequestContentLength;
  LPost.Received := 0;
  SetLength(LPost.Buffer, LPost.Capacity);
  GPosts.AddOrSetValue(Conn, LPost);
  Flags := hgAcceptData;          // tell ICS to deliver the body to OnPostedData
end;

procedure TRawICSHandler.OnPostedData(Sender: TObject; Client: TObject;
  ErrCode: Word);
var
  Conn:   THttpConnection;
  LPost:  TRawPost;
  LBuf:   array[0..16383] of Byte;
  N:      Integer;
  LFlags: THttpGetFlag;
begin
  Conn := THttpConnection(Client);
  if not GPosts.TryGetValue(Conn, LPost) then
    Exit;

  // Drain whatever ICS has on the socket right now.
  while True do
  begin
    N := Conn.Receive(@LBuf[0], SizeOf(LBuf));
    if N <= 0 then Break;
    if LPost.Received + N > LPost.Capacity then
      N := Integer(LPost.Capacity - LPost.Received);
    if N > 0 then
      Move(LBuf[0], LPost.Buffer[LPost.Received], N);
    Inc(LPost.Received, N);
    if LPost.Received >= LPost.Capacity then Break;
  end;

  if LPost.Received >= LPost.Capacity then
  begin
    GPosts.Remove(Conn);
    try
      LFlags := hgWillSendMySelf;
      // Echo the body back. The bench POST payload is UTF-8 JSON text, so
      // decoding to a string for AnswerString is lossless here.
      Answer(Conn, LFlags, TEncoding.UTF8.GetString(LPost.Buffer));
    finally
      LPost.Free;
    end;
  end;
end;

{$IFDEF MSWINDOWS}
function CtrlHandler(dwCtrlType: DWORD): BOOL; stdcall;
begin
  case dwCtrlType of
    CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT,
    CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT:
      begin
        if Assigned(GServer) then
        begin
          GServer.Stop;
          GServer.Terminated := True;   // unblock MessageLoop
        end;
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

  GPosts   := TDictionary<THttpConnection, TRawPost>.Create;
  GHandler := TRawICSHandler.Create;
  GServer  := THttpServer.Create(nil);
  try
    GServer.Addr           := '0.0.0.0';
    GServer.Port           := IntToStr(BENCH_PORT_RAW_ICS);
    GServer.OnGetDocument  := GHandler.OnGetDocument;
    GServer.OnPostDocument := GHandler.OnPostDocument;
    GServer.OnPostedData   := GHandler.OnPostedData;

    GServer.Start;

    WriteLn(Format('[HorseBench/RawICS] Listening on http://127.0.0.1:%d  [%s]',
      [BENCH_PORT_RAW_ICS, GModeLabel]));
    WriteLn('Press Ctrl-C to stop.');

    GServer.MessageLoop;   // blocks until Terminated (set by Ctrl-C handler)
  finally
    GServer.Free;
    GHandler.Free;
    GPosts.Free;
  end;

  WriteLn('[HorseBench/RawICS] Stopped cleanly.');
end.
