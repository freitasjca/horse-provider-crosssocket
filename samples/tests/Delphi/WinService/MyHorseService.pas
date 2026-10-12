unit MyHorseService;

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.SysUtils,
  System.Classes,
  Vcl.SvcMgr,
  Horse.Provider.CrossSocket.Daemon,    { brings in THorseCrossSocketService }
  Horse.CrossSocket.TestRoutes;

type
  { Inherits from THorseCrossSocketService (the PATCH-HORSE-2 convenience
    base class). The base service auto-wires ServiceStart / ServiceStop —
    we only need to set Port and register routes. ServiceCreate fires
    before ServiceStart, which is where the routes get installed.

    The Port property defaults to 9000 in the base class; we override to
    9010 here so the shared HorseCSTestClient targets the right port. }
  THorseCSTestService = class(THorseCrossSocketService)
    procedure ServiceCreate(Sender: TObject);
  private
    { Private declarations }
  public
    { Public declarations }
    // No GetServiceController here: THorseCrossSocketService implements it
    // (SVC-CTRL-2), and this sample is the gate for that.
  end;

var
  HorseCSTestService: THorseCSTestService;

implementation

{%CLASSGROUP 'System.Classes.TPersistent'}

{$R *.dfm}

procedure THorseCSTestService.ServiceCreate(Sender: TObject);
begin
  Port := TEST_PORT;             // 9010 — matches HorseCSTestClient.dpr
  Name        := 'HorseCSTestService';
  DisplayName := 'Horse CrossSocket Integration Test Service';
  RegisterTestRoutes;
end;

end.
