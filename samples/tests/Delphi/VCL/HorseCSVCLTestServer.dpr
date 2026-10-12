program HorseCSVCLTestServer;

(*
  Horse + CrossSocket — Integration Test Server (Delphi · VCL shape)
  ==================================================================

  Conditional defines (Project → Options → Conditional Defines):
    HORSE_PROVIDER_CROSSSOCKET  +  HORSE_APPTYPE_VCL

  Project type: VCL Forms Application.  Do NOT add {$APPTYPE CONSOLE} to
  this .dpr — that would force IsConsole = True and freeze the UI when
  Listen blocks.

  TfrmHorseTestVCL inherits from TfrmHorseVCLHost (PATCH-HORSE-2 cross-
  product unit). The base form auto-wires FormCreate -> THorse.Listen(Port)
  and FormClose -> THorse.StopListen. Routes are registered in the
  OnHorseListen event handler.

  Run sequence:
    1. Start this VCL app — the form shows; CrossSocket runs on background
       IO threads while the VCL message loop keeps the form responsive.
    2. Run HorseCSTestClient.exe (from the parent folder).
    3. Expect "139 passed, 0 failed" (same suite as the console server),
       and curl /diag/provider must name a CrossSocket provider.
    4. Close the form to drain + stop the server.
*)

uses
  Vcl.Forms,
  Horse,
  Horse.Provider.CrossSocket,
  Horse.Provider.CrossSocket.VCL,
  Horse.CrossSocket.TestRoutes in '..\..\Common\Horse.CrossSocket.TestRoutes.pas',
  Main.Form in 'Main.Form.pas' {frmHorseTestVCL};

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfrmHorseTestVCL, frmHorseTestVCL);
  Application.Run;
end.
