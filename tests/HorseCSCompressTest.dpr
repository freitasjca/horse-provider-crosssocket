program HorseCSCompressTest;

{$APPTYPE CONSOLE}

{
  Horse + CrossSocket  —  double-compression regression test
  ==========================================================
  Destination: horse-provider-crosssocket/tests/HorseCSCompressTest.dpr
  Requires HORSE_PROVIDER_CROSSSOCKET. Plain HTTP on port 9242.

  GUARDS [FIX-DCS-DOUBLECOMPRESS-1] in the Delphi-Cross-Socket fork.

  THE BUG, reported 2026-09 against a live service. The app registered a Horse
  compression middleware AND enabled the provider's own compression:

      THorse.Use(Compression(1024));   // gzips, sets Content-Encoding: gzip
      Cfg.Compressible    := True;     // provider gzips it AGAIN
      Cfg.MinCompressSize := 512;

  TCrossHttpResponse._CheckCompress tested the server setting, the body size, the
  Content-Type and the request's Accept-Encoding — but never whether the response
  already had a Content-Encoding. SendZCompress then OVERWROTE that header instead
  of appending, so the wire carried gzip(gzip(json)) announcing ONE gzip. The
  client decompressed once, got binary, and ContentAsString(TEncoding.UTF8) raised
  "No mapping for the Unicode character exists in the target multi-byte code page".

  It presented as method-specific (GET and POST fine, PUT broken) and was
  size-specific: only a body over BOTH thresholds got compressed twice.

  WHY THIS TEST HAS TWO CASES. A guard that simply disabled compression would
  make T1 pass and be a regression. T2 is the control: it proves the provider
  still compresses a response that is NOT pre-encoded. One without the other
  proves nothing.

      T1  pre-encoded body  -> arrives BYTE-IDENTICAL to what the route sent,
                               Content-Encoding still exactly one gzip
      T2  plain body        -> arrives gzip-compressed (magic 1F 8B)

  The client disables automatic decompression so both assertions are made on raw
  bytes. Byte-identity in T1 is the point: a second compression cannot produce
  the same bytes, so this cannot pass by accident the way a string comparison
  could when the text happens to survive.
}

{$IFNDEF HORSE_PROVIDER_CROSSSOCKET}
  {$MESSAGE FATAL 'Set HORSE_PROVIDER_CROSSSOCKET in Project Options -> Conditional defines'}
{$ENDIF}

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.ZLib,
  System.Net.HttpClient,
  System.Net.URLClient,
  System.Net.HttpClientComponent,
  Horse,
  Horse.Commons,
  Horse.Provider.CrossSocket.Server,
  Horse.Provider.CrossSocket;

const
  PORT            = 9242;
  MIN_COMPRESS    = 64;
  PAYLOAD         = '{"success":"true","data":"' +
                    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' +
                    'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' +
                    'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"}';

var
  GFail:      Integer = 0;
  GChecks:    Integer = 0;
  GPreGzip:   TBytes;             // the exact bytes /pre-encoded hands to Horse
  GListenErr: string  = '';
  GListenRet: Boolean = False;

procedure Check(const AName: string; const APassed: Boolean; const ADetail: string);
begin
  Inc(GChecks);
  if APassed then
    Writeln(Format('  PASS  %s', [AName]))
  else
  begin
    Writeln(Format('  FAIL  %s', [AName]));
    Writeln(Format('        %s', [ADetail]));
    Inc(GFail);
  end;
end;

// Real gzip, produced the way a compression middleware would: window bits 15+16
// selects a gzip wrapper rather than raw deflate or zlib.
function GzipBytes(const AText: string): TBytes;
var
  LSrc, LDst: TBytesStream;
  LZip:       TZCompressionStream;
  LRaw:       TBytes;
begin
  LRaw := TEncoding.UTF8.GetBytes(AText);
  LSrc := TBytesStream.Create(LRaw);
  try
    LDst := TBytesStream.Create;
    try
      LZip := TZCompressionStream.Create(LDst, zcDefault, 15 + 16);
      try
        LZip.CopyFrom(LSrc, 0);
      finally
        LZip.Free;          // flushes the gzip trailer
      end;
      Result := Copy(LDst.Bytes, 0, LDst.Size);
    finally
      LDst.Free;
    end;
  finally
    LSrc.Free;
  end;
end;

function IsGzip(const ABytes: TBytes): Boolean;
begin
  Result := (Length(ABytes) >= 2) and (ABytes[0] = $1F) and (ABytes[1] = $8B);
end;

function Hex(const ABytes: TBytes; ACount: Integer): string;
var
  I: Integer;
begin
  Result := '';
  if ACount > Length(ABytes) then
    ACount := Length(ABytes);
  for I := 0 to ACount - 1 do
    Result := Result + IntToHex(ABytes[I], 2) + ' ';
end;

procedure RegisterRoutes;
begin
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('pong').Status(THTTPStatus.OK);
    end);

  // Stands in for a compression middleware: an already-gzipped body plus the
  // header that declares it. The provider must leave both alone.
  THorse.Get('/pre-encoded',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.AddHeader('Content-Encoding', 'gzip');
      Res.ContentType('application/json; charset=utf-8')
         .Send(GPreGzip)
         .Status(THTTPStatus.OK);
    end);

  // The control: plain, over MIN_COMPRESS, a compressible content type. The
  // provider SHOULD compress this one.
  THorse.Get('/plain',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(PAYLOAD)
         .Status(THTTPStatus.OK);
    end);
end;

// Raw GET: Accept-Encoding offered so the provider may compress, automatic
// decompression OFF so every assertion below is about the bytes on the wire.
function RawGet(const APath: string; out AStatus: Integer;
  out ABody: TBytes; out AContentEncoding: string): Boolean;
var
  LClient: THTTPClient;
  LResp:   IHTTPResponse;
  LOut:    TBytesStream;
begin
  Result           := False;
  AStatus          := 0;
  AContentEncoding := '';
  SetLength(ABody, 0);
  LClient := THTTPClient.Create;
  try
    LClient.AutomaticDecompression := [];
    LClient.CustomHeaders['Accept-Encoding'] := 'gzip';
    LClient.CustomHeaders['Connection'] := 'close';
    LClient.ConnectionTimeout := 4000;
    LClient.ResponseTimeout   := 8000;
    LOut := TBytesStream.Create;
    try
      try
        LResp   := LClient.Get(Format('http://127.0.0.1:%d%s', [PORT, APath]), LOut);
        AStatus := LResp.StatusCode;
        ABody   := Copy(LOut.Bytes, 0, LOut.Size);
        AContentEncoding := LResp.HeaderValue['Content-Encoding'];
        Result  := True;
      except
        on E: Exception do
          AContentEncoding := E.ClassName + ': ' + E.Message;
      end;
    finally
      LOut.Free;
    end;
  finally
    LClient.Free;
  end;
end;

type
  TDriver = class(TThread)
  private
    FDone: TEvent;
    procedure Run;
  protected
    procedure Execute; override;
  public
    constructor Create;
    function WaitForSignal(ATimeoutMs: Cardinal): Boolean;
  end;

constructor TDriver.Create;
begin
  FDone := TEvent.Create(nil, True, False, '');
  inherited Create(False);
end;

function TDriver.WaitForSignal(ATimeoutMs: Cardinal): Boolean;
begin
  Result := FDone.WaitFor(ATimeoutMs) = wrSignaled;
end;

procedure TDriver.Run;
var
  LStatus: Integer;
  LBody:   TBytes;
  LEnc:    string;
  I:       Integer;
  LReady:  Boolean;
begin
  LReady := False;
  for I := 1 to 25 do
  begin
    if RawGet('/ping', LStatus, LBody, LEnc) and (LStatus = 200) then
    begin
      LReady := True;
      Break;
    end;
    if (GListenErr <> '') or GListenRet then
      Break;
    Sleep(200);
  end;

  if not LReady then
  begin
    Writeln('  VOID  server never answered /ping — nothing was tested.');
    if GListenErr <> '' then
      Writeln(Format('        ListenWithConfig raised: %s', [GListenErr]));
    Writeln(Format('        Is port %d free?  netstat -ano | findstr :%d', [PORT, PORT]));
    ExitCode := 2;
    Exit;
  end;

  // ── T1: a pre-encoded body must pass through untouched ────────────────────
  if not RawGet('/pre-encoded', LStatus, LBody, LEnc) then
  begin
    Writeln(Format('  VOID  /pre-encoded did not answer: %s', [LEnc]));
    ExitCode := 2;
    Exit;
  end;
  Writeln(Format('  /pre-encoded: status=%d enc="%s" bytes=%d sent=%d',
    [LStatus, LEnc, Length(LBody), Length(GPreGzip)]));
  Writeln(Format('    first bytes got : %s', [Hex(LBody, 8)]));
  Writeln(Format('    first bytes sent: %s', [Hex(GPreGzip, 8)]));

  Check('T1  a pre-encoded body is NOT compressed again (byte-identical)',
        (LStatus = 200) and (Length(LBody) = Length(GPreGzip)) and
        CompareMem(@LBody[0], @GPreGzip[0], Length(GPreGzip)),
        Format('got %d bytes, sent %d. A second gzip cannot reproduce the '
             + 'original bytes, so a mismatch here is the double-compression '
             + 'bug: the client would decompress once and be handed binary.',
             [Length(LBody), Length(GPreGzip)]));

  Check('T1b the Content-Encoding still declares exactly one gzip',
        SameText(Trim(LEnc), 'gzip'),
        Format('enc="%s" — SendZCompress overwrites this header rather than '
             + 'appending, so a stale or doubled value hides the second layer.',
             [LEnc]));

  Writeln;

  // ── T2: the control — plain bodies must STILL be compressed ───────────────
  if not RawGet('/plain', LStatus, LBody, LEnc) then
  begin
    Writeln(Format('  VOID  /plain did not answer: %s', [LEnc]));
    ExitCode := 2;
    Exit;
  end;
  Writeln(Format('  /plain: status=%d enc="%s" bytes=%d payload=%d',
    [LStatus, LEnc, Length(LBody), Length(PAYLOAD)]));
  Writeln(Format('    first bytes: %s', [Hex(LBody, 8)]));

  Check('T2  a plain body IS still compressed (the guard did not disable it)',
        (LStatus = 200) and IsGzip(LBody) and SameText(Trim(LEnc), 'gzip'),
        Format('enc="%s" first bytes %s — without this check, a guard that '
             + 'simply switched compression off would make T1 pass and be a '
             + 'regression.', [LEnc, Hex(LBody, 4)]));
end;

procedure TDriver.Execute;
begin
  try
    try
      Run;
    except
      on E: Exception do
      begin
        Writeln(Format('  Driver fatal: %s: %s', [E.ClassName, E.Message]));
        ExitCode := 2;
      end;
    end;
  finally
    if not GListenRet then
      try
        THorseProviderCrossSocket.StopListen;
      except
      end;
    FDone.SetEvent;
  end;
end;

var
  LDriver: TDriver;
  LConfig: THorseCrossSocketConfig;
begin
  try
    Writeln('Horse + CrossSocket  -  double-compression regression test');
    Writeln(Format('  port %d | Compressible=True | MinCompressSize=%d',
      [PORT, MIN_COMPRESS]));
    Writeln;

    GPreGzip := GzipBytes(PAYLOAD);
    Writeln(Format('  pre-encoded fixture: %d bytes of gzip from %d of JSON',
      [Length(GPreGzip), Length(PAYLOAD)]));
    Writeln;

    RegisterRoutes;

    LConfig                 := THorseCrossSocketConfig.Default;
    LConfig.Compressible    := True;
    LConfig.MinCompressSize := MIN_COMPRESS;

    LDriver := TDriver.Create;

    try
      THorseProviderCrossSocket.ListenWithConfig(PORT, LConfig);
    except
      on E: Exception do
        GListenErr := E.ClassName + ': ' + E.Message;
    end;
    GListenRet := True;

    if not LDriver.WaitForSignal(30000) then
      Writeln('   NOTE: driver still running; not joined so this result prints');

    if GListenErr <> '' then
    begin
      Writeln(Format('  VOID  ListenWithConfig failed: %s', [GListenErr]));
      ExitCode := 2;
    end;

    Writeln;
    if GChecks = 0 then
      Writeln('Results: nothing was scored — see the VOID lines above')
    else
      Writeln(Format('Results: %d passed, %d failed', [GChecks - GFail, GFail]));
    if GFail > ExitCode then
      ExitCode := GFail;
    Flush(Output);
    Halt(ExitCode);
  except
    on E: Exception do
    begin
      Writeln('Fatal: ' + E.ClassName + ': ' + E.Message);
      ExitCode := 2;
    end;
  end;
end.
