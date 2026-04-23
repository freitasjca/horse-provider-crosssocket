unit Horse.Provider.CrossSocket.WebRequestAdapter;

{
  Horse CrossSocket Provider  -  TWebRequest / TRequest adapter
  ------------------------------------------------------------

  Refactored to use the hybrid interface architecture:

    ICrossHttpRequest
          |
    TCrossSocketRawRequest (implements IHorseRawRequest)
          |
    TInterfacedWebRequest (generic TWebRequest/TRequest subclass)
          = TCrossSocketWebRequest (type alias)

  The old version duplicated 30+ abstract method stubs directly against
  ICrossHttpRequest. The new version delegates all TWebRequest boilerplate
  to TInterfacedWebRequest (Horse.Provider.RawAdapters), which in turn
  calls IHorseRawRequest methods implemented by TCrossSocketRawRequest.

  New providers only implement IHorseRawRequest (~15 methods) and get
  full TWebRequest compatibility for free via TInterfacedWebRequest.

  Backward compatibility: TCrossSocketWebRequest is a type alias for
  TInterfacedWebRequest. All existing code that creates or references
  TCrossSocketWebRequest compiles unchanged.

  Dual-compilation: Delphi and FPC branches both delegate the same way.
}

{$IF DEFINED(FPC)}
{$MODE DELPHI}{$H+}
{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes,
  fpHTTP,
  HTTPDefs,
{$ELSE}
  System.SysUtils,
  System.Classes,
  Web.HTTPApp,
{$ENDIF}
  Net.CrossHttpServer,
  Net.CrossHttpParams,
  Horse.Provider.RawInterfaces,
  Horse.Provider.RawAdapters,
  Horse.Provider.CrossSocket.RawRequest;

type
  { TCrossSocketWebRequest — backward-compatible type alias.
    Existing code continues to work:
      TCrossSocketWebRequest.Create(ACrossReq)
    The factory function below hides the two-step construction
    (IHorseRawRequest implementation + generic adapter). }

  TCrossSocketWebRequest = class(TInterfacedWebRequest)
  public
    constructor Create(const ACrossReq: ICrossHttpRequest); reintroduce;
  end;

implementation

constructor TCrossSocketWebRequest.Create(const ACrossReq: ICrossHttpRequest);
begin
  inherited Create(TCrossSocketRawRequest.Create(ACrossReq));
end;

end.
