program HorseCSHTTPAppTestServer;

{
  Horse + CrossSocket — Integration Test Server (Lazarus · HTTPApplication shape)
  ===============================================================================

  Conditional defines (Project → Project Options → Custom Options):
    -dHORSE_PROVIDER_CROSSSOCKET

  Project type: Lazarus console program (Application class: HTTPApplication
  or plain Console — both work; CrossSocket owns the loop either way).

  THorseCrossSocketHTTPApp.Run (PATCH-HORSE-2 convenience runner) delegates
  to the same daemon-style helper as HorseCSDaemonTestServer (§Lazarus/Daemon)
  — installs fpSignal(SIGTERM/SIGINT) handlers and calls blocking Listen.

  The HTTPApplication unit exists as a separate symbol for projects organised
  around fphttpapp vocabulary; functionally it's identical to the Daemon
  runner. Do NOT call fphttpapp.Application.Run — CrossSocket owns the loop.

  Run sequence:
    1. lazbuild HorseCSHTTPAppTestServer.lpi
    2. ./HorseCSHTTPAppTestServer
    3. Run HorseCSTestClient (Delphi or Lazarus build); expect 88/89.
    4. Ctrl-C / SIGTERM for clean shutdown.
}

{$MODE DELPHI}{$H+}
{$APPTYPE CONSOLE}

uses
  SysUtils,
  Horse,
  Horse.Provider.CrossSocket,
  Horse.Provider.CrossSocket.FPC.HTTPApplication,
  Horse.CrossSocket.TestRoutes;

procedure SetupRoutes;
begin
  RegisterTestRoutes;
  WriteLn(Format('[HorseCSTest · Lazarus/HTTPApp] Listening on http://0.0.0.0:%d',
    [TEST_PORT]));
  WriteLn('Press Ctrl-C or send SIGTERM for a clean shutdown.');
end;

begin
  THorseCrossSocketHTTPApp.Run(@SetupRoutes, TEST_PORT);
  WriteLn('[HorseCSTest · Lazarus/HTTPApp] Stopped cleanly.');
end.
