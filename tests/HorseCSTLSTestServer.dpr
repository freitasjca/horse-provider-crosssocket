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
  System.SysUtils,
  System.StrUtils,              // IfThen (string)
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

    RegisterRoutes;

    Writeln(Format('[CSTLSTest] certs: %s', [CertDir]));
    Writeln(Format('[CSTLSTest] mode : %s',
      [IfThen(MTLS, 'mutual TLS (client cert required)', 'one-way TLS')]));
    Writeln(Format('[CSTLSTest] Listening on https://127.0.0.1:%d', [TLS_PORT]));
    Writeln('[CSTLSTest] Run HorseCSTLSTestClient'
      + IfThen(MTLS, ' mtls', '') + ' in a second terminal. Ctrl+C to stop.');

    THorseProviderCrossSocket.ListenWithConfig(TLS_PORT, Config);
    Writeln('[CSTLSTest] Server stopped.');
  except
    on E: Exception do
    begin
      Writeln('[CSTLSTest] Fatal: ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
