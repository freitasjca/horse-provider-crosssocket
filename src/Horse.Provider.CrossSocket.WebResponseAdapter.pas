unit Horse.Provider.CrossSocket.WebResponseAdapter;

{
  Horse CrossSocket Provider  -  TWebResponse / TResponse adapter
  ---------------------------------------------------------------

  Refactored to use the hybrid interface architecture:

    ICrossHttpResponse
          |
    TCrossSocketRawResponse (implements IHorseRawResponse)
          |
    TInterfacedWebResponse (generic TWebResponse/TResponse subclass)
          = TCrossSocketWebResponse (subclass with factory constructor)

  The old version duplicated all abstract method stubs directly.
  The new version delegates all TWebResponse boilerplate to
  TInterfacedWebResponse (Horse.Provider.RawAdapters).

  New providers only implement IHorseRawResponse (~1 method) and get
  full TWebResponse compatibility for free via TInterfacedWebResponse.

  Backward compatibility: TCrossSocketWebResponse.Create(ACrossRes)
  works exactly as before. SetCustomHeader is inherited from TWebResponse
  via TInterfacedWebResponse and writes to the inherited CustomHeaders
  TStrings — no override needed.

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
  Horse.Provider.RawInterfaces,
  Horse.Provider.RawAdapters,
  Horse.Provider.CrossSocket.RawResponse;

type
  { TCrossSocketWebResponse — backward-compatible subclass.
    Existing code continues to work:
      TCrossSocketWebResponse.Create(ACrossRes)
    The constructor hides the two-step construction. }

  TCrossSocketWebResponse = class(TInterfacedWebResponse)
  public
    constructor Create(const ACrossRes: ICrossHttpResponse); reintroduce;
  end;

implementation

constructor TCrossSocketWebResponse.Create(const ACrossRes: ICrossHttpResponse);
begin
  inherited Create(TCrossSocketRawResponse.Create(ACrossRes));
end;

end.
