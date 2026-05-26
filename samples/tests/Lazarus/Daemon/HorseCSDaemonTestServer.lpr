program HorseCSDaemonTestServer;

{
  Horse + CrossSocket — Integration Test Server (Lazarus · Daemon shape)
  ======================================================================

  Conditional defines (Project → Project Options → Custom Options):
    -dHORSE_PROVIDER_CROSSSOCKET  -dHORSE_APPTYPE_DAEMON

  Project type: Lazarus console program targeting Linux/macOS/BSD.

  THorseCrossSocketDaemonApp.Run (PATCH-HORSE-2 convenience runner) wires
  fpSignal(SIGTERM/SIGINT) handlers + ignores SIGPIPE, then calls the
  blocking THorse.Listen. The entire `program` body collapses to a single
  Run() call after registering the routes.

  Routes: see Common\Horse.CrossSocket.TestRoutes.pas.

  Run sequence:
    1. lazbuild HorseCSDaemonTestServer.lpi
    2. Install via systemd (see ../../README.md §Linux daemon).
    3. sudo systemctl start horsecs-lazarus-daemon-test
    4. Run HorseCSTestClient; expect "88 passed, 1 failed".
    5. sudo systemctl stop horsecs-lazarus-daemon-test  (SIGTERM clean drain)
}

{$MODE DELPHI}{$H+}
{$APPTYPE CONSOLE}

uses
  SysUtils,
  Horse,
  Horse.Provider.CrossSocket,
  Horse.Provider.CrossSocket.FPC.Daemon,
  Horse.CrossSocket.TestRoutes;

procedure SetupRoutes;
begin
  RegisterTestRoutes;
  WriteLn(Format('[HorseCSTest · Lazarus/Daemon] Listening on http://0.0.0.0:%d',
    [TEST_PORT]));
  WriteLn('Send SIGTERM (systemctl stop) for a clean shutdown.');
end;

begin
  THorseCrossSocketDaemonApp.Run(@SetupRoutes, TEST_PORT);
  WriteLn('[HorseCSTest · Lazarus/Daemon] Stopped cleanly.');
end.
