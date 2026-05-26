unit Main.Form;

{$MODE DELPHI}{$H+}

interface

uses
  Classes, SysUtils, Forms, StdCtrls,
  Horse,
  Horse.Provider.CrossSocket.FPC.LCL,
  Horse.CrossSocket.TestRoutes;

type
  { Inherits from TfrmHorseLCLHost (PATCH-HORSE-2 convenience base class —
    the Lazarus mirror of Delphi's TfrmHorseVCLHost). Auto-wires
    FormCreate → THorse.Listen, FormClose → THorse.StopListen. We hook
    OnHorseListen to register the routes BEFORE Listen binds. }
  TfrmHorseTestLCL = class(TfrmHorseLCLHost)
    lblStatus: TLabel;
    procedure OnRegisterRoutes(Sender: TObject);
  public
    constructor Create(TheOwner: TComponent); override;
  end;

var
  frmHorseTestLCL: TfrmHorseTestLCL;

implementation

{$R *.lfm}

constructor TfrmHorseTestLCL.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  Port := TEST_PORT;            // 9010 — matches HorseCSTestClient
  OnHorseListen := @OnRegisterRoutes;
  Caption := Format('Horse CrossSocket LCL Test Server — port %d', [TEST_PORT]);
end;

procedure TfrmHorseTestLCL.OnRegisterRoutes(Sender: TObject);
begin
  RegisterTestRoutes;
  if Assigned(lblStatus) then
    lblStatus.Caption := Format('Listening on http://127.0.0.1:%d  ·  '
      + 'run HorseCSTestClient to exercise. Close this window to stop.',
      [Port]);
end;

end.
