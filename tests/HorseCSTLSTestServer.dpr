program HorseCSTLSTestServer;

{$APPTYPE CONSOLE}

{
  Horse + CrossSocket  —  TLS / mutual-TLS test server
  =====================================================
  Destination: horse-provider-crosssocket/samples/tests/HorseCSTLSTestServer.dpr

  Requires HORSE_PROVIDER_CROSSSOCKET (or legacy HORSE_CROSSSOCKET) in
  Project Options → Conditional defines.

  Listens on HTTPS port 9101 using the shared fixture certs (tests/certs/).
  Two modes, selected by the first command-line argument:

    (no arg)   one-way TLS  — server presents server.crt; any client may connect.
    mtls       mutual TLS   — server ALSO requires a client certificate signed by
                              ca.crt (SSLVerifyPeer=True). Clients without a cert
                              are rejected at the TLS handshake.

  Routes:
    GET  /ping   → 200 "pong"
    POST /echo   → 200, echoes the request body

  Cert files are located relative to the executable (see FindCertDir): copy the
  tests/certs/ folder next to the built binary, or run from the tests/ folder.

  Pair with HorseCSTLSTestClient (same mode argument).
}

{$IFNDEF HORSE_PROVIDER_CROSSSOCKET}
  {$IFNDEF HORSE_CROSSSOCKET}
    {$MESSAGE FATAL 'Set HORSE_PROVIDER_CROSSSOCKET (or HORSE_CROSSSOCKET) in Project Options → Conditional defines'}
  {$ENDIF}
{$ENDIF}

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,               // GetModuleHandle / GetModuleFileName
  {$ENDIF}
  System.SysUtils,
  System.StrUtils,              // IfThen (string)
  {$IFNDEF __MBED_TLS__}
  Net.OpenSSL,                  // TSSLTools - OpenSSL runtime report
  {$ENDIF}
  Horse,
  Horse.Commons,
  Horse.Provider.Config,        // THorseCrossSocketConfig
  Horse.Provider.CrossSocket;

const
  TLS_PORT = 9101;

{ Locate the certs/ fixture folder next to the binary (or a few parents up, so
  the test runs whether launched from the output dir or the tests/ source dir). }
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
    if FileExists(LCand + 'server.crt') then
      Exit(LCand);
  end;
  for I := Low(CANDIDATES) to High(CANDIDATES) do
  begin
    LCand := CANDIDATES[I] + PathDelim;
    if FileExists(LCand + 'server.crt') then
      Exit(LCand);
  end;
  raise Exception.Create(
    'Could not locate certs\server.crt — copy tests\certs next to the binary.');
end;

// [TLS-OSSLVER-1] Name the OpenSSL runtime this process actually loaded.
// "OpenSSL 3.x" is not one version: the same exe picks up whichever
// libcrypto comes first (exe folder, then PATH), and the TLS results depend
// on it. Loading here is reference-counted by DCS, so the server's own
// LoadSSL in Listen reuses this handle; the caller pairs it with UnloadSSL.
// run-tls-tests.bat echoes the line, so a passing run records it too.
{$IFNDEF __MBED_TLS__}
function OpenSslRuntime: string;
var
  LVer:  Cardinal;
  LName: string;
{$IFDEF MSWINDOWS}
  LMod:  HMODULE;
  LBuf:  array[0..MAX_PATH] of Char;
{$ENDIF}
begin
  LVer  := TSSLTools.SSLVersion;
  LName := TSSLTools.LibCRYPTO;
{$IFDEF MSWINDOWS}
  LMod := GetModuleHandle(PChar(LName));
  if (LMod <> 0) and (GetModuleFileName(LMod, LBuf, Length(LBuf)) > 0) then
    LName := LBuf;
{$ENDIF}
  // OpenSSL 3+: 0xMNN00PP0. Older numbers use another layout, so only the
  // raw hex is printed for them.
  if (LVer shr 28) >= 3 then
    Result := Format('%d.%d.%d (0x%.8x) from %s',
      [LVer shr 28, (LVer shr 20) and $FF, (LVer shr 4) and $FF, LVer, LName])
  else
    Result := Format('0x%.8x from %s', [LVer, LName]);
end;
{$ENDIF}

procedure RegisterRoutes;
begin
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('pong').Status(THTTPStatus.OK);
    end);

  THorse.Post('/echo',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send(Req.Body).Status(THTTPStatus.OK);
    end);
end;

var
  Config:   THorseCrossSocketConfig;
  CertDir:  string;
  MTLS:     Boolean;
begin
  try
    MTLS    := SameText(ParamStr(1), 'mtls');
    CertDir := FindCertDir;

    Config             := THorseCrossSocketConfig.Default;
    Config.SSLEnabled  := True;
    Config.SSLCertFile := CertDir + 'server.crt';
    Config.SSLKeyFile  := CertDir + 'server.key';

    if MTLS then
    begin
      Config.SSLCACertFile := CertDir + 'ca.crt';
      Config.SSLVerifyPeer := True;
    end;

    // [TLSOPT-3] run-tls-tests.bat pass 3 (openssl s_client peer).
    //   suites13     -> TLS 1.3 restricted to CHACHA20
    //   suites13typo -> a misspelled suite beside a valid one: must not start
    //   minver13     -> TLS 1.3 only: TLS 1.2 peers refused (TLSOPT-4, DCS >=1.0.16)
    //   minver12     -> TLS 1.2 floor: starts (DCS already enforces it)
    if SameText(ParamStr(1), 'suites13') then
      Config.SSLCipherSuitesTLS13 := 'TLS_CHACHA20_POLY1305_SHA256'
    else if SameText(ParamStr(1), 'suites13typo') then
      Config.SSLCipherSuitesTLS13 :=
        'TLS_AES_256_GCM_SHA348:TLS_CHACHA20_POLY1305_SHA256'
    else if SameText(ParamStr(1), 'minver13') then
      Config.SSLMinVersion := htvTLS13
    else if SameText(ParamStr(1), 'minver12') then
      Config.SSLMinVersion := htvTLS12;

    RegisterRoutes;

{$IFNDEF __MBED_TLS__}
    TSSLTools.LoadSSL;
{$ENDIF}
    Writeln(Format('[CSTLSTest] certs: %s', [CertDir]));
{$IFDEF __MBED_TLS__}
    Writeln('[CSTLSTest] OpenSSL: n/a (built with __MBED_TLS__)');
{$ELSE}
    Writeln(Format('[CSTLSTest] OpenSSL: %s', [OpenSslRuntime]));
{$ENDIF}
    Writeln(Format('[CSTLSTest] mode : %s',
      [IfThen(MTLS, 'mutual TLS (client cert required)', 'one-way TLS')]));
    Writeln(Format('[CSTLSTest] Listening on https://127.0.0.1:%d', [TLS_PORT]));
    Writeln('[CSTLSTest] Run HorseCSTLSTestClient'
      + IfThen(MTLS, ' mtls', '') + ' in a second terminal. Ctrl+C to stop.');

{$IFNDEF __MBED_TLS__}
    try
{$ENDIF}
      THorseProviderCrossSocket.ListenWithConfig(TLS_PORT, Config);
{$IFNDEF __MBED_TLS__}
    finally
      TSSLTools.UnloadSSL;
    end;
{$ENDIF}
    Writeln('[CSTLSTest] Server stopped.');
  except
    on E: Exception do
    begin
      Writeln('[CSTLSTest] Fatal: ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
