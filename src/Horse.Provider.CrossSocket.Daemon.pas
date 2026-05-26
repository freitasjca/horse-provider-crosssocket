unit Horse.Provider.CrossSocket.Daemon;

(*
  Horse CrossSocket Provider — Delphi cross-platform Daemon composition
  =====================================================================

  Selects the CrossSocket transport for a Delphi binary running as a long-
  running OS-supervised process. The THorseProviderCrossSocketDaemon class
  is the THorseProvider alias resolved by Horse.pas when
  HORSE_PROVIDER_CROSSSOCKET + HORSE_APPTYPE_DAEMON are both defined on the
  Delphi compiler — REGARDLESS of target platform.

  Two OS-specific paths are provided in the same unit:

    {$IFDEF MSWINDOWS}   THorseCrossSocketService
                         A TService base class (Vcl.SvcMgr) that auto-wires
                         ServiceStart -> THorse.Listen on a worker thread,
                         ServiceStop  -> THorse.StopListen + drain.
                         Use:  type T... = class(THorseCrossSocketService);

    {$ELSE}              THorseCrossSocketLinuxDaemonApp
                         A static helper class. Run() installs POSIX
                         signal handlers (SIGTERM/SIGINT/SIGPIPE) and
                         then calls THorse.Listen which blocks until
                         StopListen is invoked from the signal handler.
                         Use:  THorseCrossSocketLinuxDaemonApp.Run(Setup, Port);

  This mirrors the cross-platform behaviour of the existing Indy-based
  Horse.Provider.Daemon.pas (which also has both Windows-Service and
  Linux-daemon paths in a single unit).

  Mental model: HORSE_APPTYPE_DAEMON means "OS-supervised long-running
  process". Whether that process is a Windows Service or a Linux daemon
  is a function of the build target, not the define.
*)

interface

uses
{$IFDEF MSWINDOWS}
  Vcl.SvcMgr,
{$ENDIF}
{$IFDEF LINUX}
  Posix.Signal,
{$ENDIF}
{$IFDEF POSIX}
  Posix.Stdlib,
{$ENDIF}
  System.SysUtils,
  System.Classes,
  Horse.Provider.CrossSocket;

type
  { Marker subclass — Horse.pas's THorseProvider alias resolves here when
    HORSE_PROVIDER_CROSSSOCKET + HORSE_APPTYPE_DAEMON are defined on
    Delphi (any target). Inherits all transport behaviour from the existing
    THorseProviderCrossSocket — only the lifecycle wrappers below differ
    by platform. }
  THorseProviderCrossSocketDaemon = class(THorseProviderCrossSocket);

{$IFDEF MSWINDOWS}
  { Optional convenience TService base class. Users may inherit:

      type TMyHorseService = class(THorseCrossSocketService)
        procedure ServiceCreate(Sender: TObject);   // register routes here
      end;

    or ignore this class entirely and write the ServiceStart / ServiceStop
    pair by hand. The class spawns a worker thread for THorse.Listen so
    the SCM ack is not blocked by transport-setup latency. }
  THorseCrossSocketService = class(TService)
  private
    FPort: Integer;
    FListenerThread: TThread;
  protected
    procedure DoServiceStart(Sender: TService; var Started: Boolean);
    procedure DoServiceStop(Sender: TService; var Stopped: Boolean);
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;
    { Set this BEFORE the service starts (in ServiceCreate, typically) so
      the worker thread binds the intended port. }
    property Port: Integer read FPort write FPort default 9000;
  end;
{$ENDIF MSWINDOWS}

{$IFNDEF MSWINDOWS}
  { User-provided setup procedure: register routes, middleware, config. }
  THorseDelphiDaemonSetupProc = procedure;

  { Optional convenience runner for Delphi binaries cross-compiled to
    Linux (or other POSIX targets). Mirrors the Lazarus/FPC counterpart
    THorseCrossSocketDaemonApp in spirit:

      uses Horse, Horse.Provider.CrossSocket.Daemon;
      procedure SetupRoutes;
      begin
        THorse.Get('/ping', GetPing);
      end;
      begin
        THorseCrossSocketLinuxDaemonApp.Run(SetupRoutes, 9000);
      end.

    Run installs SIGTERM + SIGINT handlers that call THorse.StopListen,
    ignores SIGPIPE (so peer drops don't crash the daemon), invokes
    ASetup to register routes, then calls THorse.Listen(APort) which
    blocks until a signal arrives. }
  THorseCrossSocketLinuxDaemonApp = class
  public
    class procedure Run(ASetup: THorseDelphiDaemonSetupProc; APort: Integer); static;
  end;
{$ENDIF MSWINDOWS}

implementation

uses
  Horse;

{$IFDEF MSWINDOWS}

{ THorseCrossSocketService }

constructor THorseCrossSocketService.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPort := 9000;
  OnStart := DoServiceStart;
  OnStop  := DoServiceStop;
end;

destructor THorseCrossSocketService.Destroy;
begin
  if Assigned(FListenerThread) then
  begin
    THorse.StopListen;
    FListenerThread.WaitFor;
    FreeAndNil(FListenerThread);
  end;
  inherited;
end;

procedure THorseCrossSocketService.DoServiceStart(Sender: TService;
  var Started: Boolean);
var
  LPort: Integer;
begin
  LPort := FPort;
  { Run Listen on a dedicated worker thread so ServiceStart returns
    promptly to the SCM. CrossSocket's Listen is non-blocking in a
    service app (IsConsole = False), so this thread mostly idles after
    the IO threads start — its main job is to keep the call site stable
    for the matching WaitFor in DoServiceStop. }
  FListenerThread := TThread.CreateAnonymousThread(
    procedure begin THorse.Listen(LPort); end);
  FListenerThread.FreeOnTerminate := False;
  FListenerThread.Start;
  Started := True;
end;

procedure THorseCrossSocketService.DoServiceStop(Sender: TService;
  var Stopped: Boolean);
begin
  THorse.StopListen;                   // graceful drain via SEC-30
  if Assigned(FListenerThread) then
  begin
    FListenerThread.WaitFor;           // wait for Listen to actually return
    FreeAndNil(FListenerThread);
  end;
  Stopped := True;
end;

{$ENDIF MSWINDOWS}

{$IFNDEF MSWINDOWS}

procedure HandleStopSignal(ASignal: Integer); cdecl;
begin
  { POSIX signal handler — minimal reentrant-safe work only.
    THorse.StopListen sets a manual-reset event and calls FServer.Stop;
    both are safe to invoke from a signal context on glibc + Delphi RTL. }
  THorse.StopListen;
end;

{ THorseCrossSocketLinuxDaemonApp }

class procedure THorseCrossSocketLinuxDaemonApp.Run(
  ASetup: THorseDelphiDaemonSetupProc; APort: Integer);
begin
  {$IFDEF LINUX}
  signal(SIGTERM, @HandleStopSignal);
  signal(SIGINT,  @HandleStopSignal);
  { SIGPIPE: ignore — CrossSocket handles client-side resets internally;
    the default action (terminate) would crash the daemon on a peer drop. }
  signal(SIGPIPE, TSignalHandler(SIG_IGN));
  {$ENDIF}

  if Assigned(ASetup) then
    ASetup();

  THorse.Listen(APort);                { blocks until StopListen unblocks it }
end;

{$ENDIF MSWINDOWS}

end.
