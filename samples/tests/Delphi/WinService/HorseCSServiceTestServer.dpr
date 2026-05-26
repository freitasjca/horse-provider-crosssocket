program HorseCSServiceTestServer;

{
  Horse + CrossSocket — Integration Test Server (Delphi · Windows Service)
  ========================================================================

  Conditional defines (Project - Options - Conditional Defines):
    HORSE_PROVIDER_CROSSSOCKET  +  HORSE_APPTYPE_DAEMON

  Project type: Service Application (File - New - Other - Service Application).

  THorseCSTestService inherits from THorseCrossSocketService (PATCH-HORSE-2
  cross-product unit). The base class auto-wires:
    - ServiceStart  -> spawn worker thread for THorse.Listen(Port)
    - ServiceStop   -> THorse.StopListen + WaitFor + clean shutdown

  Worker-thread pattern is required so ServiceStart returns promptly to the
  SCM (it has a startup timeout, usually 30 s). Listen itself is non-blocking
  in a service app (IsConsole = False), but the SCM controller call has to
  return even faster than the IO threads finish bootstrapping.

  Run sequence:
    1. Install:    HorseCSServiceTestServer.exe /install
    2. Start:      sc start HorseCSTestService
    3. Test:       run HorseCSTestClient.exe (from the parent folder).
                   Expect "88 passed, 1 failed".
    4. Stop:       sc stop HorseCSTestService    (drains via SEC-30)
    5. Uninstall:  HorseCSServiceTestServer.exe /uninstall
}

uses
  Vcl.SvcMgr,
  Horse.CrossSocket.TestRoutes in '..\..\Common\Horse.CrossSocket.TestRoutes.pas',
  Horse.Provider.CrossSocket.Daemon in '..\..\..\..\src\Horse.Provider.CrossSocket.Daemon.pas',
  Horse.Provider.CrossSocket in '..\..\..\..\src\Horse.Provider.CrossSocket.pas',
  Horse.Provider.CrossSocket.Pool in '..\..\..\..\src\Horse.Provider.CrossSocket.Pool.pas',
  Horse.Provider.CrossSocket.RawRequest in '..\..\..\..\src\Horse.Provider.CrossSocket.RawRequest.pas',
  Horse.Provider.CrossSocket.RawResponse in '..\..\..\..\src\Horse.Provider.CrossSocket.RawResponse.pas',
  Horse.Provider.CrossSocket.Request in '..\..\..\..\src\Horse.Provider.CrossSocket.Request.pas',
  Horse.Provider.CrossSocket.Response in '..\..\..\..\src\Horse.Provider.CrossSocket.Response.pas',
  Horse.Provider.CrossSocket.Server in '..\..\..\..\src\Horse.Provider.CrossSocket.Server.pas',
  Horse.Provider.CrossSocket.VCL in '..\..\..\..\src\Horse.Provider.CrossSocket.VCL.pas',
  Horse.Provider.CrossSocket.WebRequestAdapter in '..\..\..\..\src\Horse.Provider.CrossSocket.WebRequestAdapter.pas',
  Horse.Provider.CrossSocket.WebResponseAdapter in '..\..\..\..\src\Horse.Provider.CrossSocket.WebResponseAdapter.pas',
  Horse.Provider.CrossSocket.WorkerPool in '..\..\..\..\src\Horse.Provider.CrossSocket.WorkerPool.pas',
  MyHorseService in 'MyHorseService.pas' {HorseCSTestService: TService};

{$R *.RES}

begin
  // The standard Delphi Service Application boilerplate. The service class
  // (declared in MyHorseService.pas) inherits from THorseCrossSocketService
  // which inherits from Vcl.SvcMgr.TService.
  // Windows 2003 Server requires StartServiceCtrlDispatcher to be

  if not Application.DelayInitialize or Application.Installing then
    Application.Initialize;
  Application.CreateForm(THorseCSTestService, HorseCSTestService);
  Application.Run;
end.
