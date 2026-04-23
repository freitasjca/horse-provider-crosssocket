unit Horse.Provider.CrossSocket.WebResponseAdapter;

{
  Horse CrossSocket Provider  -  TWebResponse / TResponse adapter
  ---------------------------------------------------------------

  Purpose
  -------
  Provide a concrete TWebResponse subclass (Delphi) / TResponse subclass (FPC)
  backed by ICrossHttpResponse so that existing Horse middleware that calls
  Res.RawWebResponse.SetCustomHeader(...) (e.g. Horse.CORS) works unchanged
  on the CrossSocket path.

  Design (PATCH-RES-6 in Horse.Response.pas)
  -------------------------------------------
  Every request, after THorseContextPool.Acquire, the provider constructs one
  of these adapters and hands it to THorseResponse.SetCSRawWebResponse.
  THorseResponse owns the adapter: Clear and Destroy free it. A fresh adapter
  is created per request — they are small (one interface ref + the inherited
  CustomHeaders TStrings), and reuse would require clearing inherited state.

  Scope — intentionally minimal
  -----------------------------
  The ONLY method middleware actually calls on RawWebResponse is:
      SetCustomHeader(Name, Value)  — Horse.CORS uses this exclusively
  SetCustomHeader is a concrete method inherited from TWebResponse that
  writes to the inherited CustomHeaders: TStrings. No override needed.

  All abstract Get/Set variable methods are stubbed to satisfy the compiler.
  SendResponse / SendRedirect are no-ops — response sending MUST go through
  TResponseBridge.Flush.

  Lifetime
  --------
  Adapter holds ICrossHttpResponse by interface reference. The interface
  keeps the underlying object alive for one HTTP request cycle. Headers
  written via SetCustomHeader are captured in the inherited CustomHeaders
  TStrings. TResponseBridge.Flush reads BOTH THorseResponse.CustomHeaders
  (the PATCH-RES-1 dictionary/list) AND — if the adapter exists —
  the adapter's inherited CustomHeaders to forward all headers set by
  middleware that bypassed Res.AddHeader and went straight to
  Res.RawWebResponse.SetCustomHeader.

  Dual-compilation
  ----------------
  Delphi branch subclasses TWebResponse (abstract, Web.HTTPApp), stubs the
  abstract Get/Set variable methods and the send methods.

  FPC branch subclasses TResponse (HTTPDefs) — field-based. Constructor
  sets inherited fields; SetCustomHeader writes to inherited CustomHeaders.
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
  Net.CrossHttpServer;

type
{$IF DEFINED(FPC)}
  { TCrossSocketWebResponse — FPC TResponse subclass }
  TCrossSocketWebResponse = class(TResponse)
  private
    FCrossRes: ICrossHttpResponse;
  public
    constructor Create(const ACrossRes: ICrossHttpResponse); reintroduce;
  end;

{$ELSE}
  { TCrossSocketWebResponse — Delphi TWebResponse subclass
    Stubs every abstract method. SetCustomHeader is inherited and works
    out of the box — it writes to the inherited CustomHeaders TStrings
    created by TWebResponse.Create. }
  TCrossSocketWebResponse = class(TWebResponse)
  private
    FCrossRes: ICrossHttpResponse;
  protected
    function  GetStringVariable(Index: Integer): string; override;
    procedure SetStringVariable(Index: Integer; const Value: string); override;
    function  GetDateVariable(Index: Integer): TDateTime; override;
    procedure SetDateVariable(Index: Integer; const Value: TDateTime); override;
    function  GetIntegerVariable(Index: Integer): Int64; override;
    procedure SetIntegerVariable(Index: Integer; Value: Int64); override;
    function  GetContent: string; override;
    procedure SetContent(const Value: string); override;
    procedure SetContentStream(Value: TStream); override;
    function  GetStatusCode: Integer; override;
    procedure SetStatusCode(Value: Integer); override;
    function  GetLogMessage: string; override;
  public
    constructor Create(const ACrossRes: ICrossHttpResponse); reintroduce;
    destructor  Destroy; override;
    procedure SendResponse; override;
    procedure SendRedirect(const URI: string); override;
  end;
{$ENDIF}

implementation

{$IF NOT DEFINED(FPC)}

{ --------------------------------------------------------------------------- }
{ TCrossSocketWebResponse — Delphi                                            }
{ --------------------------------------------------------------------------- }

constructor TCrossSocketWebResponse.Create(const ACrossRes: ICrossHttpResponse);
begin
  { Assign FCrossRes BEFORE inherited Create — TWebResponse.Create may call
    virtual getters (GetStatusCode, GetStringVariable) during initialisation.
    Same lesson as TCrossSocketWebRequest. }
  FCrossRes := ACrossRes;
  inherited Create(nil);  { TWebResponse.Create(HTTPRequest) — nil is safe,
                             HTTPRequest is stored but not dereferenced in Create }
end;

destructor TCrossSocketWebResponse.Destroy;
begin
  FCrossRes := nil;
  inherited;
end;

function TCrossSocketWebResponse.GetStringVariable(Index: Integer): string;
begin
  Result := '';
end;

procedure TCrossSocketWebResponse.SetStringVariable(Index: Integer; const Value: string);
begin
  { Stub — response writing goes through THorseResponse / TResponseBridge }
end;

function TCrossSocketWebResponse.GetDateVariable(Index: Integer): TDateTime;
begin
  Result := 0;
end;

procedure TCrossSocketWebResponse.SetDateVariable(Index: Integer; const Value: TDateTime);
begin
  { Stub }
end;

function TCrossSocketWebResponse.GetIntegerVariable(Index: Integer): Int64;
begin
  Result := 0;
end;

procedure TCrossSocketWebResponse.SetIntegerVariable(Index: Integer; Value: Int64);
begin
  { Stub }
end;

function TCrossSocketWebResponse.GetContent: string;
begin
  Result := '';
end;

procedure TCrossSocketWebResponse.SetContent(const Value: string);
begin
  { Stub — use THorseResponse.Send instead }
end;

procedure TCrossSocketWebResponse.SetContentStream(Value: TStream);
begin
  { Stub — use THorseResponse.SendFile instead }
end;

function TCrossSocketWebResponse.GetStatusCode: Integer;
begin
  Result := 200;
end;

procedure TCrossSocketWebResponse.SetStatusCode(Value: Integer);
begin
  { Stub — use THorseResponse.Status instead }
end;

function TCrossSocketWebResponse.GetLogMessage: string;
begin
  Result := '';
end;

procedure TCrossSocketWebResponse.SendResponse;
begin
  { No-op — response sending goes through TResponseBridge.Flush exclusively.
    Calling this directly would bypass security headers and CRLF sanitisation. }
end;

procedure TCrossSocketWebResponse.SendRedirect(const URI: string);
begin
  { No-op — use THorseResponse.RedirectTo instead }
end;

{$ELSE}  // FPC

{ --------------------------------------------------------------------------- }
{ TCrossSocketWebResponse — FPC                                               }
{ --------------------------------------------------------------------------- }

constructor TCrossSocketWebResponse.Create(const ACrossRes: ICrossHttpResponse);
begin
  FCrossRes := ACrossRes;
  inherited Create(nil);  { TResponse.Create(ARequest) — nil is safe here,
                             the request ref is only used by GetCookie
                             which middleware does not call on the response }
  Code := 200;
  ContentType := '';
end;

{$ENDIF}

end.
