unit Horse.Provider.CrossSocket.FPC.LCL;

{
  Horse CrossSocket Provider — FPC / Lazarus LCL composition
  ==========================================================

  Selects the CrossSocket transport for a Lazarus LCL GUI application. The
  THorseProviderCrossSocketFPCLCL class is the THorseProvider alias resolved
  by Horse.pas when HORSE_PROVIDER_CROSSSOCKET + HORSE_APPTYPE_LCL are both
  defined.

  CrossSocket's Listen is non-blocking when IsConsole = False (which is true
  in an LCL Forms application), so calling THorse.Listen from FormCreate
  starts the IO threads and returns immediately, leaving the LCL message
  loop free.

  TfrmHorseLCLHost is an optional convenience base class — the Lazarus
  counterpart of TfrmHorseVCLHost. Users can inherit from it instead of
  writing the wiring by hand (see doc/providers.md §8.6 for the longhand
  recipe).
}

{$MODE DELPHI}{$H+}

interface

uses
  SysUtils,
  Classes,
  Forms,
  Horse.Provider.CrossSocket;

type
  { Marker subclass — Horse.pas's THorseProvider alias resolves here when
    HORSE_PROVIDER_CROSSSOCKET + HORSE_APPTYPE_LCL are defined. }
  THorseProviderCrossSocketFPCLCL = class(THorseProviderCrossSocket);

  { Optional convenience LCL form base class. Mirror of the Delphi VCL
    counterpart (TfrmHorseVCLHost). Users may inherit:

      type TfrmMain = class(TfrmHorseLCLHost)
        // declare routes in OnHorseListen, OnFormCreate, etc.
      end;

    or ignore this class entirely and call THorse.Listen / .StopListen from
    their own FormCreate / FormClose. }
  TfrmHorseLCLHost = class(TForm)
  private
    FPort: Integer;
    FAutoStart: Boolean;
    FOnHorseListen: TNotifyEvent;
    FListening: Boolean;
    procedure DoFormCreate(Sender: TObject);
    procedure DoFormClose(Sender: TObject; var CloseAction: TCloseAction);
  public
    constructor Create(TheOwner: TComponent); override;
    destructor  Destroy; override;
    { Set this BEFORE Loaded fires (typically in the .lfm) so the
      auto-start uses the right port. }
    property Port: Integer read FPort write FPort default 9000;
    { Set False to suppress the auto Listen in FormCreate — useful if the
      app needs to register routes asynchronously before binding. }
    property AutoStart: Boolean read FAutoStart write FAutoStart default True;
    { Fires AFTER routes are auto-registered (if AutoStart) and BEFORE
      THorse.Listen returns. }
    property OnHorseListen: TNotifyEvent read FOnHorseListen write FOnHorseListen;
  end;

implementation

uses
  Horse;

{ TfrmHorseLCLHost }

constructor TfrmHorseLCLHost.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  FPort := 9000;
  FAutoStart := True;
  OnCreate := @DoFormCreate;
  OnClose  := @DoFormClose;
end;

destructor TfrmHorseLCLHost.Destroy;
begin
  if FListening then
    THorse.StopListen;
  inherited;
end;

procedure TfrmHorseLCLHost.DoFormCreate(Sender: TObject);
begin
  if not FAutoStart then Exit;
  if Assigned(FOnHorseListen) then
    FOnHorseListen(Self);
  THorse.Listen(FPort);   // non-blocking in an LCL app (IsConsole = False)
  FListening := True;
end;

procedure TfrmHorseLCLHost.DoFormClose(Sender: TObject;
  var CloseAction: TCloseAction);
begin
  if FListening then
  begin
    THorse.StopListen;    // graceful drain via SEC-30 active-request counter
    FListening := False;
  end;
end;

end.
