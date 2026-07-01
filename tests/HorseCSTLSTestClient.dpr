program HorseCSTLSTestClient;

{$APPTYPE CONSOLE}

{
  Horse + CrossSocket  —  TLS / mutual-TLS test client
  =====================================================
  Destination: horse-provider-crosssocket/samples/tests/HorseCSTLSTestClient.dpr

  Drives HorseCSTLSTestServer over HTTPS (https://127.0.0.1:9101) with
  TCrossHttpClient. Two modes, matching the server's argument:

    (no arg)   one-way TLS
                 T1  GET  /ping  over https → 200 "pong"  (server cert accepted)
                 T2  POST /echo  over https → body echoed

    mtls       mutual TLS
                 T3  GET /ping WITH client cert    → 200  (handshake + mTLS pass)
                 T4  GET /ping WITHOUT client cert  → fails (server rejects peer)

  The client certificate is injected by subclassing TCrossHttpClient and
  overriding the virtual CreateHttpCli to call SetCertificateFile/
  SetPrivateKeyFile on the HTTPS socket before it connects.

  Exit code = number of failed assertions (0 = all passed).
}

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  Net.CrossSslSocket.Base,      // ICrossSslSocket.SetCertificateFile
  Net.CrossHttpClient;

const
  BASE_URL   = 'https://127.0.0.1:9101';
  TIMEOUT_MS = 8000;

var
  GPassCount: Integer = 0;
  GFailCount: Integer = 0;
  GClientCert: string = '';     // set non-empty to present a client cert (mTLS)
  GClientKey:  string = '';

type
  { TCrossHttpClient subclass that presents a client certificate for HTTPS.
    CreateHttpCli is the virtual hook that builds the per-protocol socket; we
    set the client cert on the freshly-created (not-yet-connected) HTTPS socket. }
  TMTLSHttpClient = class(TCrossHttpClient)
  protected
    function CreateHttpCli(const AProtocol: string): ICrossHttpClientSocket; override;
  end;

  TReqResult = record
    StatusCode: Integer;
    Body:       string;
    TimedOut:   Boolean;
    Failed:     Boolean;   // connect/handshake error (callback got nil response)
  end;

function TMTLSHttpClient.CreateHttpCli(const AProtocol: string): ICrossHttpClientSocket;
begin
  Result := inherited CreateHttpCli(AProtocol);
  if SameText(AProtocol, 'https') and (GClientCert <> '') then
  begin
    Result.SetCertificateFile(GClientCert);
    Result.SetPrivateKeyFile(GClientKey);
  end;
end;

function StreamToStr(AStream: TStream): string;
var
  LBytes: TBytes;
begin
  Result := '';
  if not Assigned(AStream) or (AStream.Size = 0) then
    Exit;
  AStream.Position := 0;
  SetLength(LBytes, AStream.Size);
  AStream.ReadBuffer(LBytes[0], AStream.Size);
  Result := TEncoding.UTF8.GetString(LBytes);
end;

{ Find the certs/ fixture folder relative to the binary or a parent. }
function FindCertDir: string;
const
  CANDIDATES: array[0..3] of string = (
    'certs', '..\certs', 'tests\certs', '..\tests\certs');
var
  LBase, LCand: string;
  I: Integer;
begin
  LBase := ExtractFilePath(ParamStr(0));
  for I := Low(CANDIDATES) to High(CANDIDATES) do
  begin
    LCand := LBase + CANDIDATES[I] + PathDelim;
    if FileExists(LCand + 'client.crt') then
      Exit(LCand);
  end;
  for I := Low(CANDIDATES) to High(CANDIDATES) do
  begin
    LCand := CANDIDATES[I] + PathDelim;
    if FileExists(LCand + 'client.crt') then
      Exit(LCand);
  end;
  raise Exception.Create(
    'Could not locate certs\client.crt — copy tests\certs next to the binary.');
end;

{ Synchronous HTTPS request. Returns the status/body; Failed=True if the TLS
  handshake or connection failed (callback fired with nil response). }
function DoSync(const AClient: TCrossHttpClient; const AMethod, AUrl, ABody: string): TReqResult;
var
  LEvent: TEvent;
  LLocal: TReqResult;
  LBytes: TBytes;
begin
  LLocal := Default(TReqResult);
  LEvent := TEvent.Create(nil, True, False, '');
  try
    if ABody <> '' then
      LBytes := TEncoding.UTF8.GetBytes(ABody)
    else
      LBytes := nil;

    AClient.DoRequest(AMethod, AUrl, nil, LBytes, nil, nil,
      procedure(const AResp: ICrossHttpClientResponse)
      begin
        if AResp <> nil then
        begin
          LLocal.StatusCode := AResp.StatusCode;
          LLocal.Body       := StreamToStr(AResp.Content);
        end
        else
          LLocal.Failed := True;   // connection / TLS handshake error
        LEvent.SetEvent;
      end);

    LLocal.TimedOut := (LEvent.WaitFor(TIMEOUT_MS) <> wrSignaled);
  finally
    LEvent.Free;
  end;
  Result := LLocal;
end;

procedure Check(const AName: string; const APassed: Boolean; const ADetail: string = '');
begin
  if APassed then
  begin
    Writeln(Format('  PASS  %s', [AName]));
    Inc(GPassCount);
  end
  else
  begin
    if ADetail <> '' then
      Writeln(Format('  FAIL  %s  [%s]', [AName, ADetail]))
    else
      Writeln(Format('  FAIL  %s', [AName]));
    Inc(GFailCount);
  end;
end;

procedure RunOneWay;
var
  LClient: TCrossHttpClient;
  R:       TReqResult;
begin
  Writeln('[one-way TLS]');
  LClient := TCrossHttpClient.Create(2);
  try
    R := DoSync(LClient, 'GET', BASE_URL + '/ping', '');
    Check('T1  GET /ping over https → 200',
      (not R.TimedOut) and (R.StatusCode = 200) and (R.Body = 'pong'),
      Format('status=%d failed=%s body=%s', [R.StatusCode, BoolToStr(R.Failed, True), R.Body]));

    R := DoSync(LClient, 'POST', BASE_URL + '/echo', 'hello-tls');
    Check('T2  POST /echo over https → body echoed',
      (not R.TimedOut) and (R.StatusCode = 200) and (R.Body = 'hello-tls'),
      Format('status=%d body=%s', [R.StatusCode, R.Body]));
  finally
    LClient.Free;
  end;
end;

procedure RunMutual;
var
  LClient: TCrossHttpClient;
  LCertDir: string;
  R:       TReqResult;
begin
  Writeln('[mutual TLS]');
  LCertDir := FindCertDir;

  // T3 — WITH a client certificate: handshake + mTLS should succeed.
  GClientCert := LCertDir + 'client.crt';
  GClientKey  := LCertDir + 'client.key';
  LClient := TMTLSHttpClient.Create(2);
  try
    R := DoSync(LClient, 'GET', BASE_URL + '/ping', '');
    Check('T3  GET /ping WITH client cert → 200',
      (not R.TimedOut) and (R.StatusCode = 200) and (R.Body = 'pong'),
      Format('status=%d failed=%s', [R.StatusCode, BoolToStr(R.Failed, True)]));
  finally
    LClient.Free;
  end;

  // T4 — WITHOUT a client certificate: the server must reject the peer, so the
  // request must NOT succeed (handshake failure / no 200).
  GClientCert := '';
  GClientKey  := '';
  LClient := TCrossHttpClient.Create(2);
  try
    R := DoSync(LClient, 'GET', BASE_URL + '/ping', '');
    Check('T4  GET /ping WITHOUT client cert → rejected',
      R.TimedOut or R.Failed or (R.StatusCode <> 200),
      Format('status=%d failed=%s timedout=%s',
        [R.StatusCode, BoolToStr(R.Failed, True), BoolToStr(R.TimedOut, True)]));
  finally
    LClient.Free;
  end;
end;

begin
  Writeln('Horse + CrossSocket  —  TLS / mutual-TLS test');
  Writeln(Format('  Target: %s', [BASE_URL]));
  Writeln('');
  try
    if SameText(ParamStr(1), 'mtls') then
      RunMutual
    else
      RunOneWay;
  except
    on E: Exception do
    begin
      Writeln('Fatal: ' + E.Message);
      Inc(GFailCount);
    end;
  end;

  Writeln('');
  Writeln(Format('Results: %d passed, %d failed', [GPassCount, GFailCount]));
  ExitCode := GFailCount;
end.
