program HorseCSLCLTestServer;

{
  Horse + CrossSocket — Integration Test Server (Lazarus · LCL shape)
  ===================================================================

  Conditional defines (Project → Project Options → Custom Options):
    -dHORSE_PROVIDER_CROSSSOCKET  -dHORSE_APPTYPE_LCL

  Project type: Lazarus Application (a normal GUI project).

  TfrmHorseTestLCL inherits from TfrmHorseLCLHost (PATCH-HORSE-2 cross-
  product unit — the Lazarus counterpart of Delphi's TfrmHorseVCLHost).
  The base form auto-wires FormCreate → THorse.Listen(Port) and
  FormClose → THorse.StopListen. Routes are registered in OnHorseListen.

  Run sequence:
    1. lazbuild HorseCSLCLTestServer.lpi  (or compile in the IDE)
    2. Run the binary — a window appears; CrossSocket runs on background
       IO threads while the LCL message loop keeps the form responsive.
    3. Run HorseCSTestClient (Delphi or Lazarus build); expect 88/89.
    4. Close the window to drain + stop the server.
}

{$MODE DELPHI}{$H+}

uses
  Interfaces,
  Forms,
  Horse,
  Horse.Provider.CrossSocket,
  Horse.Provider.CrossSocket.FPC.LCL,
  Horse.CrossSocket.TestRoutes,
  Main.Form;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TfrmHorseTestLCL, frmHorseTestLCL);
  Application.Run;
end.
