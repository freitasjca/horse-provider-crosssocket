unit Main.Form;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants,
  System.Classes, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.StdCtrls,
  Horse,
  Horse.Provider.CrossSocket.VCL,
  Horse.CrossSocket.TestRoutes;

type
  { Inherits from TfrmHorseVCLHost (the PATCH-HORSE-2 convenience base
    class). The base form auto-wires FormCreate / FormClose to
    THorse.Listen / THorse.StopListen. We override OnHorseListen to
    register the test routes BEFORE Listen binds. }
  TfrmHorseTestVCL = class(TfrmHorseVCLHost)
    lblStatus: TLabel;
    procedure OnRegisterRoutes(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
  end;

var
  frmHorseTestVCL: TfrmHorseTestVCL;

implementation

{$R *.dfm}

constructor TfrmHorseTestVCL.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Port := TEST_PORT;             // 9010 — matches HorseCSTestClient.dpr
  OnHorseListen := OnRegisterRoutes;
  Caption := Format('Horse CrossSocket VCL Test Server — port %d', [TEST_PORT]);
end;

procedure TfrmHorseTestVCL.OnRegisterRoutes(Sender: TObject);
begin
  RegisterTestRoutes;
  if Assigned(lblStatus) then
    lblStatus.Caption := Format('Listening on http://127.0.0.1:%d  ·  '
      + 'run HorseCSTestClient to exercise. Close this form to stop.',
      [Port]);
end;

end.
