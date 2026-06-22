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
  private
{$IF DEFINED(FPC)}
    procedure PopulateMultipartFiles(const ACrossReq: ICrossHttpRequest);
{$ENDIF}
  public
    constructor Create(const ACrossReq: ICrossHttpRequest); reintroduce;
    destructor Destroy; override;
  end;

implementation

constructor TCrossSocketWebRequest.Create(const ACrossReq: ICrossHttpRequest);
begin
  inherited Create(TCrossSocketRawRequest.Create(ACrossReq));
{$IF DEFINED(FPC)}
  PopulateMultipartFiles(ACrossReq);
{$ENDIF}
end;

destructor TCrossSocketWebRequest.Destroy;
begin
{$IF DEFINED(FPC)}
  DeleteTempUploadedFiles;
{$ENDIF}
  inherited Destroy;
end;

{$IF DEFINED(FPC)}
{-----------------------------------------------------------------------------
 Popula RawWebRequest.Files quando o provider CrossSocket recebe
 multipart/form-data.  Espelho de TMormotWebRequest.PopulateMultipartFiles,
 porém iterando a estrutura já parseada pelo CrossSocket
 (THttpMultiPartFormData) em vez de decodificar o corpo manualmente.
 Os arquivos enviados são gravados em arquivos temporários gerenciados pela
 base TRequest (FPC) e removidos por DeleteTempUploadedFiles no Destroy.
 -----------------------------------------------------------------------------}
procedure TCrossSocketWebRequest.PopulateMultipartFiles(
  const ACrossReq: ICrossHttpRequest);
var
  LMultiPart: THttpMultiPartFormData;
  LField: TFormField;
  LName: String = '';
  LFileName: String = '';
  LTempFileName: String = '';
  LFile: TUploadedFile = nil;
  LStream: TFileStream = nil;
begin
  if ACrossReq.BodyType <> btMultiPart then
    Exit;

  LMultiPart := ACrossReq.Body as THttpMultiPartFormData;
  if LMultiPart = nil then
    Exit;

  for LField in LMultiPart do
  begin
    LName := LField.Name;
    if LName = EmptyStr then
      Continue;

    if LField.FileName <> '' then
    begin
      LFileName := ExtractFileName(LField.FileName);

      LFile := Files.Add as TUploadedFile;
      LFile.FieldName := LName;
      LFile.FileName := LFileName;
      LFile.ContentType := LField.ContentType;
      LFile.Disposition := 'form-data';
      if LField.Value <> nil then
        LFile.Size := LField.Value.Size
      else
        LFile.Size := 0;
      LFile.LocalFileName := GetTempUploadFileName(LName, LFileName, LFile.Size);

      LTempFileName := LFile.LocalFileName;
      LStream := TFileStream.Create(LTempFileName, fmCreate);
      try
        if (LField.Value <> nil) and (LField.Value.Size > 0) then
        begin
          LField.Value.Position := 0;
          LStream.CopyFrom(LField.Value, LField.Value.Size);
        end;
      finally
        FreeAndNil(LStream);
      end;
    end
    else
    begin
      ContentFields.Values[LName] := LField.AsString;
    end;
  end;
end;
{$ENDIF}

end.
