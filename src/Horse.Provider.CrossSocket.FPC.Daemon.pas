unit Horse.Provider.CrossSocket.FPC.Daemon;

{
  Horse CrossSocket Provider — FPC Linux daemon composition
  =========================================================

  Selects the CrossSocket transport for an FPC console-shape binary that is
  supervised by systemd (or any other process supervisor that delivers
  SIGTERM on stop). The THorseProviderCrossSocketFPCDaemon class is the
  THorseProvider alias resolved by Horse.pas when HORSE_PROVIDER_CROSSSOCKET
  + HORSE_APPTYPE_DAEMON are both defined on the FPC compiler.

  CrossSocket's Listen blocks the calling thread on a console FPC binary
  (IsConsole = True). The supervisor sends SIGTERM to request shutdown;
  the binary catches it via the POSIX signal handler installed here, calls
  THorse.StopListen which returns Listen to the caller, and the process
  exits cleanly with code 0.

  THorseCrossSocketDaemonApp is an optional convenience helper class that
  pre-wires fpSignal(SIGTERM) and fpSignal(SIGINT) to THorse.StopListen.
  Users can call THorseCrossSocketDaemonApp.Run(@SetupRoutes, APort)
  instead of writing the signal-handling wiring by hand (see
  doc/providers.md §8.5 for the longhand recipe).
}

{$MODE DELPHI}{$H+}

interface

uses
  SysUtils,
  Classes,
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  Horse.Provider.CrossSocket;

type
  { Marker subclass — Horse.pas's THorseProvider alias resolves here when
    HORSE_PROVIDER_CROSSSOCKET + HORSE_APPTYPE_DAEMON are defined on FPC. }
  THorseProviderCrossSocketFPCDaemon = class(THorseProviderCrossSocket);

  { User-provided setup procedure: register routes, middleware, config. }
  THorseDaemonSetupProc = procedure;

  { Optional convenience runner. Use:

      uses Horse, Horse.Provider.CrossSocket.FPC.Daemon;
      procedure SetupRoutes;
      begin
        THorse.Get('/ping', @GetPing);
      end;
      begin
        THorseCrossSocketDaemonApp.Run(@SetupRoutes, 9000);
      end.

    Run installs SIGTERM + SIGINT handlers that call THorse.StopListen,
    invokes ASetup to register routes, then calls THorse.Listen(APort)
    which blocks until a signal arrives. }
  THorseCrossSocketDaemonApp = class
  public
    class procedure Run(ASetup: THorseDaemonSetupProc; APort: Integer);
  end;

implementation

uses
  Horse;

{$IFDEF UNIX}
procedure HandleStopSignal(ASignal: cint); cdecl;
begin
  // POSIX signal handlers must be reentrant-safe. THorse.StopListen sets
  // a manual-reset event and calls FServer.Stop — both safe to invoke
  // from a signal context on Linux glibc + FPC RTL.
  THorse.StopListen;
end;
{$ENDIF}

class procedure THorseCrossSocketDaemonApp.Run(ASetup: THorseDaemonSetupProc;
  APort: Integer);
begin
  {$IFDEF UNIX}
  fpSignal(SIGTERM, @HandleStopSignal);
  fpSignal(SIGINT,  @HandleStopSignal);
  // SIGPIPE: ignore — CrossSocket handles client-side resets internally;
  // the default action (terminate) would crash the daemon on a peer drop.
  fpSignal(SIGPIPE, signalhandler(SIG_IGN));
  {$ENDIF}

  if Assigned(ASetup) then
    ASetup();

  THorse.Listen(APort);   // blocks until StopListen unblocks it
end;

end.
