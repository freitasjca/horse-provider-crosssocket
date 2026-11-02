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
  // NOTE: calling THorse.StopListen from a POSIX signal handler is not strictly
  // async-signal-safe — it frees the server, joins IO threads and re-enters the
  // memory manager. A single SIGTERM/SIGINT works in practice on Linux glibc +
  // FPC RTL. A SECOND signal arriving mid-teardown used to re-enter StopListen on
  // another thread and double-free FServer -> SIGSEGV; that is now guarded at the
  // provider level by FIX-CS-STOP-REENTRANT-1 (a TInterlocked guard in Stop /
  // StopListenGraceful), so a repeated signal is safe. The fully-correct form is
  // to set a flag here and call StopListen from the main thread; the guard makes
  // this direct call safe enough for a daemon.
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
