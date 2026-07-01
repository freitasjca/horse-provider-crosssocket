program HorseBenchICS;

{
  Horse Performance Benchmark Server — OverbyteICS transport
  ===========================================================

  Conditional defines (Project → Options → Conditional Defines):
    HORSE_PROVIDER_ICS

  Project type: Console Application. Delphi only (ICS is Delphi-only; Windows +
  POSIX/Linux64). Needs the ICS Source/ path + horse-provider-ics/src, and the
  OpenSSL libraries that ship with ICS for --tls.

  Ports:
    9009  bare routes (no middleware)
    9019  routes wrapped in RequestGuard + SecurityHeaders (--middleware)
    9039  HTTPS (--tls) / mutual TLS (--mtls)

  Run sequence:
    HorseBenchICS.exe                ← bare mode (port 9009)
    HorseBenchICS.exe --middleware   ← middleware mode (port 9019)
    HorseBenchICS.exe --tls          ← one-way HTTPS (port 9039)
    HorseBenchICS.exe --mtls         ← mutual TLS (port 9039)

  Threading model:
    ICS sockets are single-thread-affine (message loop). The provider offloads
    the Horse pipeline to a worker pool and marshals the response back to the
    loop thread — so this benchmark measures that marshal path, not a per-
    connection thread model.
}

{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_ICS}

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  System.SysUtils,
  System.StrUtils,
  Horse,
  Horse.Provider.ICS.Config,       // THorseICSConfig (--tls)
  Horse.Provider.ICS,
  Horse.Middleware.RequestGuard,
  Horse.Middleware.SecurityHeaders,
  Horse.CORS,
  Horse.BenchRoutes in '..\..\Common\Horse.BenchRoutes.pas';

const
  BASE_PORT = BENCH_PORT_ICS_BARE;

var
  GModeBoth:      Boolean;   // --middleware     : RequestGuard + SecurityHeaders
  GModeGuard:     Boolean;   // --guard-only     : RequestGuard only
  GModeHeaders:   Boolean;   // --headers-only   : SecurityHeaders only
  GModeCors:      Boolean;   // --cors           : Horse.CORS
  GAnyMiddleware: Boolean;
  GModeLabel:     string;
  GPort:          Integer;
  GTls:           Boolean;   // --tls   : listen HTTPS on BASE_PORT + BENCH_PORT_TLS_OFFSET
  GMtls:          Boolean;   // --mtls  : require + verify a client cert (implies --tls)

{$IFDEF MSWINDOWS}
function CtrlHandler(dwCtrlType: DWORD): BOOL; stdcall;
begin
  case dwCtrlType of
    CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT,
    CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT:
      begin
        THorse.StopListen;
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

{ Locate the TLS fixture certs (samples/bench/certs/, or a parent) for --tls. }
function CertPath(const AName: string): string;
const
  CANDIDATES: array[0..3] of string = (
    'certs', '..\certs', '..\..\certs', '..\..\..\certs');
var
  LBase, LCand: string;
  I: Integer;
begin
  LBase := ExtractFilePath(ParamStr(0));
  for I := Low(CANDIDATES) to High(CANDIDATES) do
  begin
    LCand := LBase + CANDIDATES[I] + PathDelim;
    if FileExists(LCand + 'server.crt') then
      Exit(LCand + AName);
  end;
  Result := 'certs' + PathDelim + AName;
end;

begin
  GModeBoth      := HasSwitch('middleware');
  GModeGuard     := HasSwitch('guard-only');
  GModeHeaders   := HasSwitch('headers-only');
  GModeCors      := HasSwitch('cors');
  GMtls          := HasSwitch('mtls');
  GTls           := GMtls or HasSwitch('tls');
  GAnyMiddleware := GModeBoth or GModeGuard or GModeHeaders or GModeCors;
  if GTls then
    GPort := BASE_PORT + BENCH_PORT_TLS_OFFSET
  else
    GPort := BASE_PORT + (BENCH_PORT_MW_OFFSET * Ord(GAnyMiddleware));

  {$IFDEF MSWINDOWS}
  SetConsoleCtrlHandler(@CtrlHandler, True);
  {$ENDIF}

  if GModeBoth or GModeGuard then
    THorse.Use(THorseRequestGuard.New);
  if GModeBoth or GModeHeaders then
    THorse.Use(THorseSecurityHeaders.New);
  if GModeCors then
  begin
    HorseCORS
      .AllowedOrigin('*')
      .AllowedMethods('GET,POST,PUT,DELETE,PATCH')
      .AllowedHeaders('*');
    THorse.Use(CORS);
  end;

  if GModeBoth then
    GModeLabel := '+middleware (guard+headers)'
  else if GModeGuard then
    GModeLabel := '+guard-only'
  else if GModeHeaders then
    GModeLabel := '+headers-only'
  else if GModeCors then
    GModeLabel := '+cors'
  else
    GModeLabel := 'bare';
  if GTls then
    GModeLabel := GModeLabel + IfThen(GMtls, '+mtls', '+tls');

  RegisterBenchRoutes;

  WriteLn(Format('[HorseBench/ICS] Listening on %s://127.0.0.1:%d  [%s]',
    [IfThen(GTls, 'https', 'http'), GPort, GModeLabel]));
  WriteLn('Active provider class: ' + THorse.ClassName);
  WriteLn('Press Ctrl-C to stop.');

  if GTls then
  begin
    var LCfg := THorseICSConfig.Default;
    LCfg.SSLEnabled     := True;
    LCfg.SSLCertFile    := CertPath('server.crt');
    LCfg.SSLPrivKeyFile := CertPath('server.key');
    if GMtls then
    begin
      LCfg.SSLCAFile     := CertPath('ca.crt');
      LCfg.SSLVerifyPeer := True;
    end;
    THorseProviderICS.ListenWithConfig(GPort, LCfg);
  end
  else
    THorse.Listen(GPort);

  WriteLn('[HorseBench/ICS] Stopped cleanly.');
end.
