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

  ── Improvements ────────────────────────────────────────────────────────────
  [IMP-1a] Use ACrossReq.Path (already decoded by CrossSocket) instead of
           manually splitting RawPathAndParams.  The raw URL is still checked
           for length ([SEC-14]) before Path is used.

  [IMP-1b] Use ACrossReq.Query (THttpUrlParams, already parsed by CrossSocket)
           instead of calling ParseQueryString on the raw string.  Size limits
           ([SEC-18]) are still enforced on the already-decoded values.

  [IMP-1c] Use ACrossReq.Cookies (TRequestCookies, already parsed by
           CrossSocket) instead of PopulateCookiesFromHeader.  Iterating the
           library's parsed collection is more robust than manual semicolon
           splitting and avoids double-parsing.

  ── API reference (all verified against uploaded source files) ───────────────
  ICrossHttpRequest (Net.CrossHttpServer.pas):
    property Method:           string        ('GET', 'POST', ...)
    property Path:             string        (decoded path, no query string)
    property RawPathAndParams: string        (raw un-decoded path + '?' + query)
    property HostName:         string
    property ContentType:      string
    property Header:           THttpHeader   (see below)
    property Query:            THttpUrlParams (already-parsed query — TBaseParams)
    property Cookies:          TRequestCookies (already-parsed cookies — TBaseParams)
    property Body:             TObject       (TMemoryStream when btBinary)
    property BodyType:         TBodyType     (btNone/btUrlEncoded/btMultiPart/btBinary)
    property Connection:       ICrossHttpConnection -> .PeerAddr: string

  THttpHeader = class(TBaseParams) (Net.CrossHttpParams.pas — confirmed):
    Inherits all TBaseParams members:
      property Count: Integer                        (total header entries)
      property Items[AIndex: Integer]: TNameValue    (integer-indexed access)
      property Params[const AName: string]: string   (string default indexer)
      function GetEnumerator: TEnumerator            (for..in yields TNameValue)
      procedure Clear
    TNameValue = record Name, Value: string end

  THttpUrlParams = class(TBaseParams) — same enumerator as THttpHeader.
  TRequestCookies = class(TBaseParams) — same enumerator as THttpHeader.

  THorseRequest (patched Horse.Request.pas, PATCH-REQ-3):
    procedure Populate(AMethod, AMethodType, APath, AContentType, ARemoteAddr)
    function  Headers: THorseCoreParam -> .Dictionary.AddOrSetValue(K, V)
    function  Query:   THorseCoreParam -> .Dictionary.AddOrSetValue(K, V)
    function  Cookie:  THorseCoreParam -> .Dictionary.AddOrSetValue(K, V)
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
    // [IMP-1b] Populate query params from CrossSocket's already-parsed Query
    class procedure PopulateQuery(
                      const ACrossReq: ICrossHttpRequest;
                            AHorseReq: THorseRequest);
    // [IMP-1c] Populate cookie collection from CrossSocket's already-parsed Cookies
    class procedure PopulateCookies(
                      const ACrossReq: ICrossHttpRequest;
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
  RawUrl:  string;
  Path:    string;
  PeerAddr: string;
begin
  ARejectReason := '';

  // ── [SEC-15] Method allowlist ─────────────────────────────────────────────
  if not ValidateMethod(ACrossReq.Method) then
  begin
    ARejectReason := 'Method Not Allowed: ' + ACrossReq.Method;
    Exit(rvMethodNotAllowed);
  end;

  // ── [SEC-14] URL length guard — check raw URL before any parsing ──────────
  // RawPathAndParams: confirmed property on ICrossHttpRequest.
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

  // ── Probe-only guard ──────────────────────────────────────────────────────
  // ExecutePipeline calls Populate(ACrossReq, nil, ...) as a validation-only
  // probe before acquiring a context from the pool.  All security checks above
  // have passed.  If AHorseReq is nil there is nothing to populate — return
  // rvOK so the caller knows the request is safe to process.
  if not Assigned(AHorseReq) then
    Exit(rvOK);


  // ── [IMP-1a] Use CrossSocket's already-decoded Path ───────────────────────
  // ACrossReq.Path is the decoded path segment without the query string.
  // The raw URL was already validated for length above.
  Path := ACrossReq.Path;
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

  // ── [IMP-1c] Cookie population from CrossSocket's parsed Cookies ──────────
  // Uses ACrossReq.Cookies (TRequestCookies) instead of raw Cookie header
  // string, avoiding double-parsing and manual semicolon splitting.
  PopulateCookies(ACrossReq, AHorseReq);

  // ── [IMP-1b] Query population from CrossSocket's parsed Query ─────────────
  // Uses ACrossReq.Query (THttpUrlParams) instead of raw query string,
  // avoiding manual URL decoding.  Size limits [SEC-18] still applied.
  PopulateQuery(ACrossReq, AHorseReq);

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

// ── [IMP-1b] Query population from CrossSocket's parsed THttpUrlParams ────────
// Replaces manual ParseQueryString / TNetEncoding.URL.Decode calls.
// CrossSocket has already URL-decoded the keys and values; we only apply
// the [SEC-18] size limits on the already-decoded strings.
class procedure TRequestBridge.PopulateQuery(
  const ACrossReq: ICrossHttpRequest;
        AHorseReq: THorseRequest);
var
  NV: TNameValue;
begin
  for NV in ACrossReq.Query do
  begin
    if NV.Name = '' then Continue;
    // [SEC-18] Drop oversized keys/values silently
    if (Length(NV.Name)  > MAX_QUERY_KEY_LEN) or
       (Length(NV.Value) > MAX_QUERY_VALUE_LEN) then Continue;
    AHorseReq.Query.Dictionary.AddOrSetValue(NV.Name, NV.Value);
  end;
end;

// ── [IMP-1c] Cookie population from CrossSocket's parsed TRequestCookies ──────
// Replaces PopulateCookiesFromHeader / manual semicolon split.
// CrossSocket has already parsed the Cookie header; we just iterate.
class procedure TRequestBridge.PopulateCookies(
  const ACrossReq: ICrossHttpRequest;
        AHorseReq: THorseRequest);
var
  NV: TNameValue;
begin
  for NV in ACrossReq.Cookies do
  begin
    if NV.Name = '' then Continue;
    AHorseReq.Cookie.Dictionary.AddOrSetValue(NV.Name, NV.Value);
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
            // file upload – store the stream (non-owning reference)
            AHorseReq.ContentFields.AddStream(Field.Name, Field.Value);
        end;
      end;

    btBinary:
      // binary data is not represented in ContentFields
      ; // do nothing
  end;
end;

end.
