unit Horse.Provider.CrossSocket.RawResponse;

{
  CrossSocket IHorseRawResponse implementation
  ============================================
  Wraps ICrossHttpResponse in a single-method interface implementation.
  The generic TInterfacedWebResponse adapter (Horse.Provider.RawAdapters)
  delegates here to build a full TWebResponse compatible with all middleware.

  Currently SetCustomHeader is a no-op passthrough — the actual header
  writing happens via the inherited CustomHeaders TStrings on
  TInterfacedWebResponse, which TResponseBridge.CopyHeaders reads at flush
  time.  This implementation exists for future providers that may want to
  intercept header writes in real time.

  Dual-compilation: Delphi and FPC share the same implementation.
}

{$IF DEFINED(FPC)}
{$MODE DELPHI}{$H+}
{$ENDIF}

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  Net.CrossHttpServer,
  Horse.Provider.RawInterfaces;

type
  TCrossSocketRawResponse = class(TInterfacedObject, IHorseRawResponse)
  private
    FCrossRes: ICrossHttpResponse;
  public
    constructor Create(const ACrossRes: ICrossHttpResponse);

    { IHorseRawResponse }
    procedure SetCustomHeader(const AName, AValue: string);
  end;

implementation

constructor TCrossSocketRawResponse.Create(const ACrossRes: ICrossHttpResponse);
begin
  inherited Create;
  FCrossRes := ACrossRes;
end;

procedure TCrossSocketRawResponse.SetCustomHeader(const AName, AValue: string);
begin
  { Header writes are captured by TInterfacedWebResponse's inherited
    CustomHeaders TStrings.  This method is available for providers that
    want to forward headers to the transport in real time. CrossSocket
    defers all header writing to TResponseBridge.Flush, so this is a
    no-op here. }
end;

end.
