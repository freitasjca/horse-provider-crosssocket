program HorseBenchHttpSys;

{
  Horse Performance Benchmark Server - http.sys transport (Delphi, Windows only)
  =============================================================================

  Horse's built-in kernel-mode provider (HTTP Server API / http.sys). HTTP/1.1.

  Conditional defines (Project -> Options -> Conditional Defines):
    HORSE_PROVIDER_HTTPSYS

  Project type: Console Application. Target: Win64 Release. Windows only.

  Ports:
    9045  bare routes (no middleware)
    9055  routes wrapped in RequestGuard + SecurityHeaders (pass --middleware)

  -- URL ACL (this is the http.sys gotcha) --
  http.sys registration by a non-admin needs a one-time URL ACL, and it only
  answers requests whose Host header matches the registered prefix. This server
  binds the EXPLICIT loopback prefix http://127.0.0.1:<port>/ so it matches the
  bench client/bombardier/h2load (which hit 127.0.0.1) without a strong-wildcard
  ('+') registration. Grant the ACL once per port, e.g.:

      netsh http add urlacl url=http://127.0.0.1:9045/ user=Everyone
      netsh http add urlacl url=http://127.0.0.1:9055/ user=Everyone

  ...or run this exe elevated. Without it, Listen raises and the server prints the
  exact command below and exits. Diagnose a running instance with:
      netsh http show servicestate view=requestq

  Switches (match the other bench servers):
    --middleware     RequestGuard + SecurityHeaders   (-> 9055)
    --headers-only   SecurityHeaders only             (-> 9055)
    --cors           Horse.CORS                       (-> 9055)
    --maxconn / --listenqueue  accepted for parity; ignored (no analog here)
}

{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_HTTPSYS}

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  System.SysUtils,
  System.StrUtils,
  Horse,
  Horse.Provider.HttpSys,
  Horse.Middleware.RequestGuard,
  Horse.Middleware.SecurityHeaders,
  Horse.CORS,
  Horse.BenchRoutes in '..\..\Common\Horse.BenchRoutes.pas';

const
  BASE_PORT = BENCH_PORT_HTTPSYS_BARE;
  BIND_HOST = '127.0.0.1';

var
  GModeBoth:      Boolean;   // --middleware   : RequestGuard + SecurityHeaders
  GModeHeaders:   Boolean;   // --headers-only : SecurityHeaders only
  GModeCors:      Boolean;   // --cors         : Horse.CORS
  GAnyMiddleware: Boolean;
  GModeLabel:     string;
  GPort:          Integer;

function TrimSwitches(const S: string): string;
var
  I: Integer;
begin
  I := 1;
  while (I <= Length(S)) and (S[I] in ['-', '/']) do
    Inc(I);
  Result := Copy(S, I, MaxInt);
end;

function HasSwitch(const ASwitch: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if SameText(TrimSwitches(ParamStr(I)), ASwitch) then
      Exit(True);
end;

begin
  GModeBoth      := HasSwitch('middleware');
  GModeHeaders   := HasSwitch('headers-only');
  GModeCors      := HasSwitch('cors');
  GAnyMiddleware := GModeBoth or GModeHeaders or GModeCors;
  GPort          := BASE_PORT + (BENCH_PORT_MW_OFFSET * Ord(GAnyMiddleware));

  if GModeBoth then
    THorse.Use(THorseRequestGuard.New);
  if GModeBoth or GModeHeaders then
    THorse.Use(THorseSecurityHeaders.New);
  if GModeCors then
  begin
    HorseCORS;
    THorse.Use(CORS);
  end;

  if GModeBoth then
    GModeLabel := '+middleware (guard+headers)'
  else if GModeHeaders then
    GModeLabel := '+headers-only'
  else if GModeCors then
    GModeLabel := '+cors'
  else
    GModeLabel := 'bare';

  RegisterBenchRoutes;

  WriteLn(Format('[HorseBench/http.sys] Listening on http://%s:%d/  [%s]',
    [BIND_HOST, GPort, GModeLabel]));
  WriteLn('Active provider class: ' + THorse.ClassName);
  WriteLn('If this fails with a 5 (access denied), grant the URL ACL once:');
  WriteLn(Format('  netsh http add urlacl url=http://%s:%d/ user=Everyone', [BIND_HOST, GPort]));
  WriteLn('  (or run this exe elevated). Press Ctrl-C to stop.');
  Flush(Output);

  try
    THorseProviderHttpSys.Listen(GPort, BIND_HOST);
  except
    on E: Exception do
    begin
      WriteLn('[HorseBench/http.sys] Listen FAILED: ' + E.ClassName + ': ' + E.Message);
      WriteLn(Format('  Fix: netsh http add urlacl url=http://%s:%d/ user=Everyone  (or run elevated)',
        [BIND_HOST, GPort]));
      Flush(Output);
      Halt(1);
    end;
  end;

  WriteLn('[HorseBench/http.sys] Stopped cleanly.');
end.
