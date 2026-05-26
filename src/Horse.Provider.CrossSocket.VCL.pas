unit Horse.Provider.CrossSocket.VCL;

{
  Horse CrossSocket Provider — Delphi VCL composition
  ===================================================

  Selects the CrossSocket transport for a VCL Forms application. The
  THorseProviderCrossSocketVCL class is the THorseProvider alias resolved by
  Horse.pas when HORSE_PROVIDER_CROSSSOCKET + HORSE_APPTYPE_VCL are both
  defined.

  CrossSocket's Listen is non-blocking when IsConsole = False (which is true
  in a VCL Forms application), so calling THorse.Listen from FormCreate
  starts the IO threads and returns immediately, leaving the VCL message
  loop free.

  TfrmHorseVCLHost is an optional convenience base class that pre-wires
  FormCreate / FormClose to THorse.Listen / THorse.StopListen with a
  configurable Port property. Users can inherit from it instead of writing
  the wiring by hand (see doc/providers.md §8.2 for the longhand recipe).
}

interface

uses
  System.SysUtils,
  System.Classes,
  Vcl.Forms,
  Horse.Provider.CrossSocket;

type
  { Marker subclass — Horse.pas's THorseProvider alias resolves here when
    HORSE_PROVIDER_CROSSSOCKET + HORSE_APPTYPE_VCL are defined. Inherits all
    transport behaviour from THorseProviderCrossSocket; the VCL aspect is
    expressed in the lifecycle helper class below, not in this class. }
  THorseProviderCrossSocketVCL = class(THorseProviderCrossSocket);

  { Optional convenience form base class for VCL apps. Users may inherit:

      type TfrmMain = class(TfrmHorseVCLHost)
        // declare routes in OnHorseListen, OnFormCreate, etc.
      end;

    or ignore this class entirely and call THorse.Listen / .StopListen from
    their own FormCreate / FormClose. The class adds no new state beyond
    Port + the auto-wired event. }
  TfrmHorseVCLHost = class(TForm)
  private
    FPort: Integer;
    FAutoStart: Boolean;
    FOnHorseListen: TNotifyEvent;
    FListening: Boolean;
    procedure DoFormCreate(Sender: TObject);
    procedure DoFormClose(Sender: TObject; var Action: TCloseAction);
  protected
    procedure Loaded; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;
    { Set this BEFORE Loaded fires (typically in the .dfm or in an override
      of Create) so the auto-start uses the right port. }
    property Port: Integer read FPort write FPort default 9000;
    { Set False to suppress the auto Listen in FormCreate — useful if the
      app needs to register routes asynchronously before binding. }
    property AutoStart: Boolean read FAutoStart write FAutoStart default True;
    { Fires AFTER routes are auto-registered (if AutoStart) and BEFORE
      THorse.Listen returns. Use this to register additional routes or to
      log the bind. }
    property OnHorseListen: TNotifyEvent read FOnHorseListen write FOnHorseListen;
  end;

implementation

uses
  Horse;

{ TfrmHorseVCLHost }

constructor TfrmHorseVCLHost.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPort := 9000;
  FAutoStart := True;
  OnCreate := DoFormCreate;
  OnClose  := DoFormClose;
end;

destructor TfrmHorseVCLHost.Destroy;
begin
  if FListening then
    THorse.StopListen;
  inherited;
end;

procedure TfrmHorseVCLHost.Loaded;
begin
  inherited;
  // Loaded runs after the .dfm has streamed in, so Port carries the
  // .dfm-set value by now. Nothing to do here — DoFormCreate handles the
  // actual Listen call.
end;

procedure TfrmHorseVCLHost.DoFormCreate(Sender: TObject);
begin
  if not FAutoStart then Exit;
  if Assigned(FOnHorseListen) then
    FOnHorseListen(Self);
  THorse.Listen(FPort);   // non-blocking in a VCL app (IsConsole = False)
  FListening := True;
end;

procedure TfrmHorseVCLHost.DoFormClose(Sender: TObject; var Action: TCloseAction);
begin
  if FListening then
  begin
    THorse.StopListen;    // graceful drain via SEC-30 active-request counter
    FListening := False;
  end;
end;

end.
