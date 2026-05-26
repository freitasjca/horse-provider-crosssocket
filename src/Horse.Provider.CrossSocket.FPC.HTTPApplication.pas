unit Horse.Provider.CrossSocket.FPC.HTTPApplication;

{
  Horse CrossSocket Provider — FPC HTTPApplication composition
  ============================================================

  Provides a convenience alias and runner for users who structure their
  FPC project as an HTTPApplication but want CrossSocket as the transport.

  Functionally, this is the same shape as Horse.Provider.CrossSocket.FPC.Daemon:
  both are console-shape FPC binaries where CrossSocket owns the main loop
  (Listen blocks; signal handlers unblock). The HTTPApplication name is
  retained for users whose projects are organised around the fphttpapp
  vocabulary — but Application.Run from fphttpapp is NOT called, because
  CrossSocket owns the loop, not fphttpapp.

  Two competing event loops in one process is the failure mode that
  PATCH-HORSE-1 explicitly prevents at compile time. Do not call
  Application.Run when this unit is in scope.

  THorseCrossSocketHTTPApp.Run delegates to the same Daemon-style helper
  as Horse.Provider.CrossSocket.FPC.Daemon.
}

{$MODE DELPHI}{$H+}

interface

uses
  SysUtils,
  Classes,
  Horse.Provider.CrossSocket,
  Horse.Provider.CrossSocket.FPC.Daemon;

type
  { Marker subclass — present so users explicitly referencing this unit
    get a class name that matches their project's vocabulary. Functionally
    identical to THorseProviderCrossSocketFPCDaemon. }
  THorseProviderCrossSocketFPCHTTPApplication = class(THorseProviderCrossSocket);

  { Convenience alias of the Daemon-style setup procedure. }
  THorseHTTPAppSetupProc = THorseDaemonSetupProc;

  { Optional convenience runner — delegates to THorseCrossSocketDaemonApp
    because the FPC HTTPApplication shape uses the same signal-handler
    + blocking-Listen pattern. Provided as a separate symbol so users
    whose project is organised around HTTPApplication vocabulary can use
    the matching name. }
  THorseCrossSocketHTTPApp = class
  public
    class procedure Run(ASetup: THorseHTTPAppSetupProc; APort: Integer);
  end;

implementation

class procedure THorseCrossSocketHTTPApp.Run(ASetup: THorseHTTPAppSetupProc;
  APort: Integer);
begin
  // Same lifecycle as the FPC Daemon helper — signal handlers + blocking
  // Listen. Don't call fphttpapp.Application.Run; CrossSocket owns the loop.
  THorseCrossSocketDaemonApp.Run(ASetup, APort);
end;

end.
