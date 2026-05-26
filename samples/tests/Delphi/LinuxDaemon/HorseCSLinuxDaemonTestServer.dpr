program HorseCSLinuxDaemonTestServer;

(*
  Horse + CrossSocket — Integration Test Server (Delphi · Linux daemon shape)
  ===========================================================================

  Conditional defines (Project → Options → Conditional Defines):
    HORSE_PROVIDER_CROSSSOCKET  +  HORSE_APPTYPE_DAEMON

  Project target: Linux64. Console application (the daemon shape on Linux
  is a long-running console binary supervised by systemd).

  Same defines as the Windows-Service test (Delphi/WinService/...) — what
  differs is the build target, not the project configuration. The cross-
  platform Horse.Provider.CrossSocket.Daemon.pas selects the appropriate
  helper class at compile time:
    {$IFDEF MSWINDOWS} → THorseCrossSocketService     (TService base)
    {$ELSE}            → THorseCrossSocketLinuxDaemonApp  (POSIX runner)

  This mirrors the cross-platform behaviour of the Indy-based
  Horse.Provider.Daemon.pas — "daemon" means "OS-supervised long-running
  process", and the OS-specific incarnation is picked by the build target.

  Routes: see Common\Horse.CrossSocket.TestRoutes.pas — same 32 surfaces
  the shared HorseCSTestClient.dpr exercises.

  Run sequence (Linux):
    1. Build for Linux64, copy binary + linked libs to the target host.
    2. Install the systemd unit file (see ../../README.md §Linux daemon).
    3. sudo systemctl start horsecs-test-daemon
    4. Run HorseCSTestClient from any host that can reach port 9010;
       expect "88 passed, 1 failed".
    5. sudo systemctl stop horsecs-test-daemon  (SIGTERM → clean drain)
*)

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Horse,
  Horse.Provider.CrossSocket,
  Horse.Provider.CrossSocket.Daemon,
  Horse.CrossSocket.TestRoutes in '..\..\Common\Horse.CrossSocket.TestRoutes.pas';

procedure SetupRoutes;
begin
  RegisterTestRoutes;
  WriteLn(Format('[HorseCSTest · Delphi/LinuxDaemon] Listening on http://0.0.0.0:%d',
    [TEST_PORT]));
  WriteLn('Send SIGTERM (systemctl stop) for a clean shutdown.');
end;

begin
{$IFDEF LINUX}
  { Linux path — the cross-platform Horse.Provider.CrossSocket.Daemon unit
    exposes THorseCrossSocketLinuxDaemonApp on non-Windows targets. Run
    installs POSIX SIGTERM/SIGINT/SIGPIPE handlers and calls the blocking
    THorse.Listen for us. }
  THorseCrossSocketLinuxDaemonApp.Run(SetupRoutes, TEST_PORT);
{$ELSE}
  { Building for Windows? Use the Delphi/WinService test instead — that
    project sets the same defines but produces a TService-backed binary
    via Horse.Provider.CrossSocket.Daemon's THorseCrossSocketService.
    This .dpr is intentionally Linux-targeted. }
  WriteLn('[HorseCSTest · Delphi/LinuxDaemon] This project must be built '
        + 'for Linux64. For Windows-Service builds, open Delphi/WinService.');
  ExitCode := 1;
{$ENDIF}
  WriteLn('[HorseCSTest · Delphi/LinuxDaemon] Stopped cleanly.');
end.
