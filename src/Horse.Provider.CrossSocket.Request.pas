unit Horse.Provider.CrossSocket.Request;

{
  Horse CrossSocket Provider  -  Request Bridge  (hardened)
  ----------------------------------------------------------

  ── Prerequisite ────────────────────────────────────────────────────────────
  PATCH-REQ-3 must be applied to the Horse fork (Horse.Request.pas):
    procedure THorseRequest.Populate(AMethod, AMethodType, APath,
                                     AContentType, ARemoteAddr)
    function  THorseRequest.RemoteAddr: string

  These inject per-request values directly into the private shadow fields,
  bypassing the FWebRequest delegation that would crash with a nil TWebRequest.

  ── Security fixes ──────────────────────────────────────────────────────────
  [SEC-12] HTTP Request Smuggling prevention.
           RFC 7230 §3.3.3 rule 3: if both Content-Length and
           Transfer-Encoding are present, reject with 400.

  [SEC-13] Header count and name/value size limits.
           Hard limits: 100 headers max, 8 KB per value, 256 bytes per name.
           ALL client headers are forwarded (subject to size caps) via full
           iteration over THttpHeader — not a fixed allowlist.

  [SEC-14] URL length limit: 8 KB for the full raw URL.

  [SEC-15] HTTP method allowlist.
           CONNECT and TRACE excluded (XST / proxy-command risks).

  [SEC-16] Remote address uses ACrossReq.Connection.PeerAddr — the real
           socket address.  X-Forwarded-For is forwarded as a plain header
           only — never silently replacing RemoteAddr.

  [SEC-17] Host header validation — missing or non-printable-ASCII Host
           rejected with 400.

  [SEC-18] Query string key/value size limits: 2 KB each.

  ── API reference (all verified against uploaded source files) ───────────────
  ICrossHttpRequest (Net.CrossHttpServer.pas):
    property Method:           string        ('GET', 'POST', ...)
    property RawPathAndParams: string        (raw un-decoded path + '?' + query)
    property HostName:         string
    property ContentType:      string
    property Header:           THttpHeader   (see below)
    property Body:             TObject       (TMemoryStream when btBinary)
    property BodyType:         TBodyType     (btNone/btUrlEncoded/btMultiPart/btBinary)
    property Connection:       ICrossHttpConnection -> .PeerAddr: string

  THttpHeader = class(TBaseParams) (Net.CrossHttpParams.pas — NOW CONFIRMED):
    Inherits all TBaseParams members:
      property Count: Integer                        (total header entries)
      property Items[AIndex: Integer]: TNameValue    (integer-indexed access)
      property Params[const AName: string]: string   (string default indexer)
      function GetEnumerator: TEnumerator            (for..in yields TNameValue)
      procedure Clear
    TNameValue = record Name, Value: string end

  THorseRequest (patched Horse.Request.pas, PATCH-REQ-3):
    procedure Populate(AMethod, AMethodType, APath, AContentType, ARemoteAddr)
    function  Headers: THorseCoreParam -> .Dictionary.AddOrSetValue(K, V)
    function  Query:   THorseCoreParam -> .Dictionary.AddOrSetValue(K, V)
    function  Body(const ABody: TObject): THorseRequest   (setter overload)

  THorseCoreParam (Horse.Core.Param.pas):
    property Dictionary: TDictionary<string,string> -> .AddOrSetValue(K, V)
}

interface

uses
  System.SysUtils,
  System.Classes,
  System.NetEncoding,
  Net.CrossHttpServer,
  Net.CrossHttpParams,
  Horse.Request,
  Horse.Commons
  // TMethodType and its constants (mtAny, mtGet, mtPut, mtPost, mtHead,
  // mtDelete, mtPatch) live in Web.HTTPApp on Delphi, and are declared in
  // Horse.Commons under {$IF DEFINED(FPC)} on FPC.
  // NOTE: mtOptions does NOT exist in TMethodType on either platform.
  // OPTIONS requests map to mtAny in MapMethodType.
{$IF NOT DEFINED(FPC)}
  , Web.HTTPApp
{$ENDIF}
  ;

const
  // [SEC-13]
  MAX_HEADER_COUNT     = 100;
  MAX_HEADER_NAME_LEN  = 256;
  MAX_HEADER_VALUE_LEN = 8192;
  // [SEC-14]
  MAX_URL_LEN          = 8192;
  // [SEC-18]
  MAX_QUERY_KEY_LEN    = 2048;
  MAX_QUERY_VALUE_LEN  = 2048;

type
  // Returned by Populate — provider maps to HTTP status codes
  TRequestValidationResult = (
    rvOK,
    rvBadRequest,       // malformed headers, URL, Host, or too many headers
    rvMethodNotAllowed  // verb not in allowlist [SEC-15]
  );

  TRequestBridge = class
  public
    /// Validate + populate AHorseReq from the raw CrossSocket request.
    /// Returns rvOK on success; any other value means reject the request.
    /// Send the appropriate error response and do NOT call THorse.Execute.
    class function Populate(
      const ACrossReq:     ICrossHttpRequest;
            AHorseReq:     THorseRequest;
      out   ARejectReason: string
    ): TRequestValidationResult;

  private
    class function  ValidateMethod(const AMethod: string): Boolean;
    class function  ValidateHost(const AHost: string): Boolean;
    class function  CheckSmuggling(
                      const ACrossReq: ICrossHttpRequest;
                      out   AReason:   string): Boolean;  // True = safe
    // Iterates all headers in ACrossReq.Header, applies [SEC-13] guards,
    // and populates AHorseReq.Headers.Dictionary.
    // Returns False (and sets AReason) when the count limit is exceeded.
    class function  ParseHeaders(
                      const ACrossReq: ICrossHttpRequest;
                            AHorseReq: THorseRequest;
                      out   AReason:   string): Boolean;
    class procedure ParseQueryString(
                      const ARawQuery: string;
                            AHorseReq: THorseRequest);
    class procedure MapBody(
                      const ACrossReq: ICrossHttpRequest;
                            AHorseReq: THorseRequest);
    class function  MapMethodType(const AMethod: string): TMethodType;
    class procedure PopulateContentFields(
                      const ACrossReq: ICrossHttpRequest;
                            AHorseReq: THorseRequest);
  end;

implementation

// ── [SEC-15] Allowed HTTP methods ────────────────────────────────────────────
// CONNECT = proxy command, never valid on an origin server.
// TRACE   = enables Cross-Site Tracing (XST) attacks.
const
  ALLOWED_METHODS: array[0..6] of string = (
    'GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS'
  );

{ TRequestBridge }

class function TRequestBridge.Populate(
  const ACrossReq:     ICrossHttpRequest;
        AHorseReq:     THorseRequest;
  out   ARejectReason: string
): TRequestValidationResult;
var
  RawUrl, Path, Query: string;
  QPos:                Integer;
  PeerAddr:            string;
begin
  ARejectReason := '';

  // ── [SEC-15] Method allowlist ─────────────────────────────────────────────
  if not ValidateMethod(ACrossReq.Method) then
  begin
    ARejectReason := 'Method Not Allowed: ' + ACrossReq.Method;
    Exit(rvMethodNotAllowed);
  end;

  // ── [SEC-14] URL length guard ─────────────────────────────────────────────
  // RawPathAndParams: confirmed property on ICrossHttpRequest
  // (property RawPathAndParams: string read GetRawPathAndParams).
  // Contains the raw un-decoded path + optional '?' + query string.
  RawUrl := ACrossReq.RawPathAndParams;
  if Length(RawUrl) > MAX_URL_LEN then
  begin
    ARejectReason := 'URI Too Long';
    Exit(rvBadRequest);
  end;

  // ── [SEC-17] Host validation ──────────────────────────────────────────────
  // Use the HostName property (confirmed on ICrossHttpRequest) — avoids
  // dependence on exact header-name case in the string indexer.
  if not ValidateHost(ACrossReq.HostName) then
  begin
    ARejectReason := 'Invalid or missing Host header';
    Exit(rvBadRequest);
  end;

  // ── [SEC-12] Request smuggling check ─────────────────────────────────────
  if not CheckSmuggling(ACrossReq, ARejectReason) then
    Exit(rvBadRequest);

  // ── Split path and query string ───────────────────────────────────────────
  QPos := Pos('?', RawUrl);
  if QPos > 0 then
  begin
    Path  := Copy(RawUrl, 1, QPos - 1);
    Query := Copy(RawUrl, QPos + 1, MaxInt);
  end
  else
  begin
    Path  := RawUrl;
    Query := '';
  end;
  if (Path = '') or (Path[1] <> '/') then
    Path := '/' + Path;

  // ── [SEC-16] Peer address — always the real socket address ───────────────
  // PeerAddr lives on ICrossConnection, accessed via .Connection on the request.
  PeerAddr := ACrossReq.Connection.PeerAddr;

  // ── PATCH-REQ-3: inject per-request shadow fields ────────────────────────
  // Sets FCSMethod, FCSMethodType, FCSPathInfo, FCSContentType, FCSRemoteAddr
  // and pre-builds FHeaders as an empty THorseCoreParam ready to be populated.
  AHorseReq.Populate(
    ACrossReq.Method,
    MapMethodType(ACrossReq.Method),
    Path,
    ACrossReq.ContentType,
    PeerAddr
  );

  // ── [SEC-13] Full header iteration with count + size guards ──────────────
  if not ParseHeaders(ACrossReq, AHorseReq, ARejectReason) then
    Exit(rvBadRequest);

  // ── [PATCH-REQ-4] Cookie parsing from Cookie header ───────────────────────
  // Req.Cookie on the CrossSocket path is populated here from the Cookie
  // request header.  InitializeCookie nil-guards FWebRequest so it returns an
  // empty collection; PopulateCookiesFromHeader fills it from the raw header.
  AHorseReq.PopulateCookiesFromHeader(ACrossReq.Header['Cookie']);

  // ── [SEC-18] Query string with key/value size limits ─────────────────────
  if Query <> '' then
    ParseQueryString(Query, AHorseReq);

  // ── Body: non-owning reference [SEC-9] ───────────────────────────────────
  MapBody(ACrossReq, AHorseReq);

  // ── Populate ContentFields from parsed body ──────────────────────────────
  PopulateContentFields(ACrossReq, AHorseReq);

  Result := rvOK;
end;

// ── [SEC-15] ──────────────────────────────────────────────────────────────────
class function TRequestBridge.ValidateMethod(const AMethod: string): Boolean;
var
  M: string;
begin
  for M in ALLOWED_METHODS do
    if SameText(AMethod, M) then Exit(True);
  Result := False;
end;

// ── MapMethodType ─────────────────────────────────────────────────────────────
class function TRequestBridge.MapMethodType(const AMethod: string): TMethodType;
begin
  if      SameText(AMethod, 'GET')     then Result := mtGet
  else if SameText(AMethod, 'POST')    then Result := mtPost
  else if SameText(AMethod, 'PUT')     then Result := mtPut
  else if SameText(AMethod, 'DELETE')  then Result := mtDelete
  else if SameText(AMethod, 'PATCH')   then Result := mtPatch
  else if SameText(AMethod, 'HEAD')    then Result := mtHead
  // mtOptions does not exist in TMethodType on either Delphi (Web.HTTPApp)
  // or FPC (Horse.Commons). OPTIONS falls through to mtAny — Horse routes
  // it via wildcard matching, the same as any other unrecognised method.
  else                                      Result := mtAny;
end;

// ── [SEC-17] ──────────────────────────────────────────────────────────────────
class function TRequestBridge.ValidateHost(const AHost: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  if AHost = '' then Exit(False);
  for I := 1 to Length(AHost) do
  begin
    C := AHost[I];
    if (Ord(C) < 32) or (Ord(C) > 126) then Exit(False);
  end;
  Result := True;
end;

// ── [SEC-12] ──────────────────────────────────────────────────────────────────
class function TRequestBridge.CheckSmuggling(
  const ACrossReq: ICrossHttpRequest;
  out   AReason:   string
): Boolean;
var
  HasCL, HasTE: Boolean;
  TEValue:      string;
begin
  // THttpHeader default string indexer: Header['name'] -> value
  // Confirmed in Net.CrossHttpServer.pas (FHeader[HEADER_CONTENT_LENGTH] etc.)
  HasCL   := ACrossReq.Header['Content-Length'] <> '';
  TEValue := Trim(LowerCase(ACrossReq.Header['Transfer-Encoding']));
  HasTE   := TEValue <> '';

  // RFC 7230 §3.3.3 rule 3: reject if both framing headers present
  if HasCL and HasTE then
  begin
    AReason := 'Ambiguous framing: both Content-Length and Transfer-Encoding present';
    Exit(False);
  end;

  // Only 'chunked' and 'identity' are valid TE values for HTTP/1.1 requests
  if HasTE and (TEValue <> 'chunked') and (TEValue <> 'identity') then
  begin
    AReason := 'Unsupported Transfer-Encoding: ' + TEValue;
    Exit(False);
  end;

  Result := True;
end;

// ── [SEC-13] ──────────────────────────────────────────────────────────────────
// THttpHeader inherits TBaseParams (confirmed — Net.CrossHttpParams.pas).
// TBaseParams exposes:
//   Count: Integer           — number of entries (O(1) via TList<TNameValue>.Count)
//   GetEnumerator: TEnumerator — for..in yields TNameValue records
//   TNameValue = record Name, Value: string end
//
// All client-supplied headers are forwarded to Horse, subject to:
//   [SEC-13-a] Total count cap  (MAX_HEADER_COUNT)     — checked first, O(1)
//   [SEC-13-b] Name length cap  (MAX_HEADER_NAME_LEN)  — skip oversized names
//   [SEC-13-c] Value length cap (MAX_HEADER_VALUE_LEN) — skip oversized values
//   [SEC-13-d] CR/LF in name   — drop; prevents header-injection in forwarded
//              responses where the forged name would split the header block.
//   [SEC-13-e] Empty names     — drop; meaningless and confuse parsers.
class function TRequestBridge.ParseHeaders(
  const ACrossReq: ICrossHttpRequest;
        AHorseReq: THorseRequest;
  out   AReason:   string
): Boolean;
var
  H: TNameValue;
begin
  Result := True;

  // [SEC-13-a] O(1) count check before any allocation work
  if ACrossReq.Header.Count > MAX_HEADER_COUNT then
  begin
    AReason := Format('Too many headers: %d (max %d)',
                      [ACrossReq.Header.Count, MAX_HEADER_COUNT]);
    Exit(False);
  end;

  // AHorseReq.Headers is the pre-built empty THorseCoreParam from Populate.
  // Dictionary is a TDictionary<string,string> — AddOrSetValue handles both
  // insert and update, matching the last-write-wins HTTP semantics for
  // duplicate header names (RFC 7230 §3.2.2 allows combining as comma list;
  // we keep the last occurrence which is safe for all headers we pass through).
  for H in ACrossReq.Header do
  begin
    if H.Name = '' then Continue;                               // [SEC-13-e]
    if Length(H.Name) > MAX_HEADER_NAME_LEN then Continue;     // [SEC-13-b]
    if Length(H.Value) > MAX_HEADER_VALUE_LEN then Continue;   // [SEC-13-c]
    if (Pos(#13, H.Name) > 0) or (Pos(#10, H.Name) > 0) then // [SEC-13-d]
      Continue;

    AHorseReq.Headers.Dictionary.AddOrSetValue(H.Name, H.Value);
  end;
end;

// ── [SEC-18] ──────────────────────────────────────────────────────────────────
class procedure TRequestBridge.ParseQueryString(
  const ARawQuery: string;
        AHorseReq: THorseRequest
);
var
  Parts:    TArray<string>;
  Part:     string;
  EqPos:    Integer;
  Key, Val: string;
begin
  Parts := ARawQuery.Split(['&']);
  for Part in Parts do
  begin
    if Part = '' then Continue;

    EqPos := Pos('=', Part);
    if EqPos > 0 then
    begin
      Key := TNetEncoding.URL.Decode(Copy(Part, 1, EqPos - 1));
      Val := TNetEncoding.URL.Decode(Copy(Part, EqPos + 1, MaxInt));
    end
    else
    begin
      Key := TNetEncoding.URL.Decode(Part);
      Val := '';
    end;

    if Key = '' then Continue;
    // [SEC-18] Drop oversized keys/values silently
    if (Length(Key) > MAX_QUERY_KEY_LEN) or
       (Length(Val) > MAX_QUERY_VALUE_LEN) then Continue;

    // THorseCoreParam.Query is lazy-initialised on first call.
    // Dictionary.AddOrSetValue is the correct insertion method.
    AHorseReq.Query.Dictionary.AddOrSetValue(Key, Val);
  end;
end;

// ── Body ──────────────────────────────────────────────────────────────────────
class procedure TRequestBridge.MapBody(
  const ACrossReq: ICrossHttpRequest;
        AHorseReq: THorseRequest
);
var
  BodyObj: TObject;
  Stream:  TStream;
begin
  // ACrossReq.Body: TObject — confirmed property type on ICrossHttpRequest.
  // When BodyType = btBinary the concrete object is a TMemoryStream.
  //
  // [SEC-9] Non-owning reference: CrossSocket owns this stream for the
  // lifetime of the request.  Never free it.  Pool Reset calls Body(nil)
  // which clears FBody without freeing the referent.
  BodyObj := ACrossReq.Body;
  if BodyObj = nil then Exit;

  case ACrossReq.BodyType of
    btBinary:
      begin
        Stream := BodyObj as TStream;
        if Stream.Size > 0 then
        begin
          Stream.Position := 0;
          AHorseReq.Body(Stream);
        end;
      end;

    btUrlEncoded,
    btMultiPart:
      // For parsed bodies, just pass the object – middleware can inspect it
      AHorseReq.Body(BodyObj);

    else
      ; // do nothing
  end;
end;

// ── PopulateContentFields ─────────────────────────────────────────────────────
class procedure TRequestBridge.PopulateContentFields(
  const ACrossReq: ICrossHttpRequest;
        AHorseReq: THorseRequest);
var
  UrlParams: THttpUrlParams;
  MultiPart: THttpMultiPartFormData;
  Field:     TFormField;
  NameVal:   TNameValue;
begin
  case ACrossReq.BodyType of
    btUrlEncoded:
      begin
        UrlParams := ACrossReq.Body as THttpUrlParams;
        if UrlParams = nil then Exit;
        for NameVal in UrlParams do
          AHorseReq.ContentFields.Dictionary.AddOrSetValue(NameVal.Name, NameVal.Value);
      end;

    btMultiPart:
      begin
        MultiPart := ACrossReq.Body as THttpMultiPartFormData;
        if MultiPart = nil then Exit;
        for Field in MultiPart do
        begin
          if Field.FileName = '' then
            // ordinary form field
            AHorseReq.ContentFields.Dictionary.AddOrSetValue(Field.Name, Field.AsString)
          else
            // file upload – store the stream (non‑owning reference)
            AHorseReq.ContentFields.AddStream(Field.Name, Field.Value);
        end;
      end;

    btBinary:
      // binary data is not represented in ContentFields
      ; // do nothing
  end;
end;

end.