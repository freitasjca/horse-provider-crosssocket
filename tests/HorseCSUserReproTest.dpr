program HorseCSUserReproTest;

{$APPTYPE CONSOLE}

// ===========================================================================
//  BISECT SWITCHES - the whole point of this file.
//
//  All OFF is the provider-only baseline: run that FIRST. Then remove the
//  leading '// ' from ONE line, rebuild, run. Keep going down the list,
//  cumulatively, in the reporter's registration order. The first run whose T1
//  fails names the culprit.
//
//  A define is only in effect if the program's `middleware:` banner line
//  prints its name. That check exists because a define that is present in the
//  uses clause but never registered would silently clear the wrong suspect.
// ===========================================================================
// {$DEFINE USE_CORS}
// {$DEFINE USE_HANDLEEXCEPTION}
// {$DEFINE USE_COMPRESSION}
// {$DEFINE USE_JHONSON}
// {$DEFINE USE_JWT}
// {$DEFINE USE_OCTETSTREAM}
// {$DEFINE USE_LOGGER}

//   Horse + CrossSocket  —  user-reported PUT failures, reproduction harness
//   =======================================================================
//   Destination: horse-provider-crosssocket/tests/HorseCSUserReproTest.dpr
//   Requires HORSE_PROVIDER_CROSSSOCKET. Plain HTTP on 9252; `tls` arg for HTTPS.
//
//   Mirrors a production service that reported TWO distinct PUT failures. They are
//   separate faults with separate causes, and conflating them cost time:
//
//     (A) "No mapping for the Unicode character exists in the target multi-byte
//         code page" from Response.ContentAsString(TEncoding.UTF8).
//         CAUSE: double compression — Horse's Compression middleware AND the
//         provider's Cfg.Compressible both gzipped, the wire carried
//         gzip(gzip(json)) announcing one gzip. FIXED in the Delphi-Cross-Socket
//         fork v1.0.14 (FIX-DCS-DOUBLECOMPRESS-1); HorseCSCompressTest guards it.
//         Reproduced here as T3 because it is RESPONSE-side and size-dependent.
//
//     (B) HTTP 500 "Error decoding URL style (%XX) encoded string at position 30".
//         CAUSE not yet located. What IS established: the decoded string is
//         exactly one JSON value from the REQUEST body —
//
//             "descripcion":"Impuesto al Valor Agregado 13%"
//
//         30 characters, '%' is the 30th, i.e. TRAILING with no hex digits after
//         it. A URL decoder raises exactly that message at exactly that position.
//         The position is an offset INSIDE that value, not inside the body, which
//         is what identifies it: a whole-body decode would report ~2383.
//
//   ELIMINATED for (B), each read in the source of the reported versions
//   (Horse 3.3.9/3.3.10, provider 1.0.25, DCS 1.0.15):
//
//     - Horse.Utils.DecodeParam returns malformed percent input UNCHANGED rather
//       than raising (guard present from 3.3.9).
//     - Req.Query / Req.Params / Req.ContentFields are all built with
//       ADecodeValues=False, so no read-side decode.
//     - Req.Body (string) does not decode: on the CrossSocket path FWebRequest is
//       nil and it returns the stored body verbatim.
//     - The provider bridge classifies an application/json body as btBinary and
//       puts nothing in ContentFields; it contains no URL-decode call at all.
//     - A whole-body urlencoded misparse is excluded by the position (see above)
//       and because the payload holds no '&' and no '='.
//
//   So something ABOVE the provider parses the JSON and then URL-decodes an
//   individual string value. This harness exists to find which thing.
//
//   HOW TO USE IT AS A BISECT TOOL
//   ------------------------------
//   Every middleware the reporter runs is behind its own define, ALL OFF by
//   default so the file compiles with no extra Boss packages and establishes the
//   provider-only baseline first. Enable them ONE AT A TIME, in his order:
//
//       {$DEFINE USE_CORS}
//       {$DEFINE USE_HANDLEEXCEPTION}
//       {$DEFINE USE_COMPRESSION}
//       {$DEFINE USE_JHONSON}
//       {$DEFINE USE_JWT}
//       {$DEFINE USE_OCTETSTREAM}
//       {$DEFINE USE_LOGGER}
//
//   The run that first FAILS T1 names the culprit. If T1 passes with all seven
//   enabled, the decode is in application code, not middleware, and the next step
//   is the call stack rather than more permutations.
//
//   A TRAP THIS FILE DELIBERATELY AVOIDS: Res.Send(TJSONObject) produces an EMPTY
//   body unless a serializing middleware (Jhonson) is registered — it stores the
//   object and something else must render it. The reporter has Jhonson, so his
//   route works; a baseline run without it would send nothing and T1 would "pass"
//   while testing nothing. So the route sends a STRING unless USE_JHONSON is on.
//   C0 asserts a non-empty body for exactly this reason.
//
//   A SECOND TRAP, worth knowing outside this file: Format() treats '%' specially.
//   Never pass a body containing a literal '%' through Format() — that raises its
//   own unrelated error and sends you chasing the wrong fault. Nothing here does.
//
//   PAYLOAD. Drop the real Put_Body.json beside the exe and it is used verbatim;
//   otherwise an embedded fallback carrying the SAME trigger is used (a value whose
//   30th character is a trailing '%'). The embedded one is not his data.
//
//       T1  PUT, body has a trailing '%' in a JSON value  -> 200 + intact reply
//       T2  same body with the '%' removed                -> 200  (isolates '%')
//       T3  reply larger than MinCompressSize, base64      -> ContentAsString ok
//       T4  the 7 request headers his route reads          -> all arrive
//       C0  control: benign PUT, non-empty reply           -> proves the route runs
//
//   Exit code 0 = all passed, N = that many failed, 2 = VOID (nothing measured).

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.JSON,
  System.NetEncoding,
  System.Net.HttpClient,
  System.Net.URLClient,
  System.Net.HttpClientComponent,
  Horse,
  Horse.Commons,
  Horse.Provider.CrossSocket.Server,
  Horse.Provider.CrossSocket
{$IFDEF USE_CORS}           , Horse.CORS           {$ENDIF}
{$IFDEF USE_HANDLEEXCEPTION}, Horse.HandleException{$ENDIF}
{$IFDEF USE_COMPRESSION}    , Horse.Compression    {$ENDIF}
{$IFDEF USE_JHONSON}        , Horse.Jhonson        {$ENDIF}
{$IFDEF USE_JWT}            , Horse.JWT            {$ENDIF}
{$IFDEF USE_OCTETSTREAM}    , Horse.OctetStream    {$ENDIF}
{$IFDEF USE_LOGGER}         , Horse.Logger, Horse.Logger.Provider.Console{$ENDIF}
  ;

const
  PORT            = 9252;
  MIN_COMPRESS    = 512;          { his Cfg.MinCompressSize }
  COMPRESS_MW_MIN = 1024;         { his Compression(1024)   }

  { The trigger, isolated. 30 chars, '%' is the 30th. Built by concatenation so
    no Format() ever sees it. }
  TRIGGER_VALUE = 'Impuesto al Valor Agregado 13%';

var
  GPass:      Integer = 0;
  GFail:      Integer = 0;
  GExitCode:  Integer = 0;
  GUseTls:    Boolean = False;
  GListenErr: string  = '';
  GStarted:   TEvent;
  GHandlerHits: Integer = 0;
  GLastBodyLen: Integer = 0;
  GPipelineHits: Integer = 0;   { our own first middleware - see PipelineProbe }
  GSeenCType:    string  = '';
  GSeenMethod:   string  = '';
  GLastHeaders: string  = '';

{ ── reporting ─────────────────────────────────────────────────────────────── }

procedure Check(const AName: string; const AOk: Boolean; const ADetail: string = '');
begin
  if AOk then
  begin
    Inc(GPass);
    Writeln('  PASS  ' + AName);
  end
  else
  begin
    Inc(GFail);
    Writeln('  FAIL  ' + AName);
    if ADetail <> '' then
      Writeln('        ' + ADetail);
  end;
end;

procedure Void(const AWhy: string);
begin
  Writeln('  VOID  ' + AWhy);
  Writeln('        Nothing below would mean anything. Fix this first.');
  GExitCode := 2;
end;

function Scheme: string;
begin
  if GUseTls then Result := 'https' else Result := 'http';
end;

function Url(const APath: string): string;
begin
  Result := Scheme + '://127.0.0.1:' + IntToStr(PORT) + APath;
end;

{ ── payload ───────────────────────────────────────────────────────────────── }

function EmbeddedPayload(const ADescription: string): string;
begin
  { Same SHAPE as the reported document: a nested object, an array of items, and
    one description string that carries the trigger. Deliberately no '&' and no
    '=' anywhere, matching the real payload, so a urlencoded misparse cannot be
    confused with the percent decode. }
  Result :=
    '{"identificacion":{"version":4,"ambiente":"00","tipoDte":"03",' +
    '"numeroControl":"DTE-03-S002P001-000000000000162",' +
    '"codigoGeneracion":"3084FB2C-2414-4663-B9A3-B4FE56F69B40"},' +
    '"cuerpoDocumento":[{"numItem":1,"descripcion":"Producto de prueba",' +
    '"cantidad":1,"precioUni":16.0}],' +
    '"tributos":[{"codigo":"20","descripcion":"' + ADescription + '",' +
    '"valor":2.08}],' +
    '"resumen":{"totalPagar":18.08,"totalLetras":"DIECIOCHO 08/100"}}';
end;

function LoadPayload(const ADescription: string; out AFromFile: Boolean): string;
var
  LPath: string;
  LList: TStringList;
begin
  AFromFile := False;
  LPath := ExtractFilePath(ParamStr(0)) + 'Put_Body.json';
  if FileExists(LPath) then
  begin
    LList := TStringList.Create;
    try
      { LoadFromFile with explicit UTF8 so a BOM-less file is not read as ANSI }
      LList.LoadFromFile(LPath, TEncoding.UTF8);
      Result := LList.Text;
      AFromFile := True;
      Exit;
    finally
      LList.Free;
    end;
  end;
  Result := EmbeddedPayload(ADescription);
end;

{ ── routes: his handler's shape ───────────────────────────────────────────── }

procedure SendJson(Res: THorseResponse; AObj: TJSONObject; AStatus: Integer);
begin
{$IFDEF USE_JHONSON}
  { His exact call. Jhonson serialises the object in its finally block. }
  Res.ContentType('application/json; charset=utf-8').Send(AObj).Status(AStatus);
{$ELSE}
  { No serialising middleware: Send(TObject) would leave the body EMPTY, so
    render it here and free the object we created. }
  try
    Res.ContentType('application/json; charset=utf-8')
       .Send(AObj.ToJSON).Status(AStatus);
  finally
    AObj.Free;
  end;
{$ENDIF}
end;

procedure PutInvoice(Req: THorseRequest; Res: THorseResponse);
var
  LBody:  string;
  LObj:   TJSONObject;
  LBytes: TBytes;
  LBig:   string;
begin
  TInterlocked.Increment(GHandlerHits);

  { The seven headers his route reads, in his order. }
  GLastHeaders :=
    'Subsidiary='       + Req.Headers['Subsidiary']       + '|' +
    'Store='            + Req.Headers['Store']            + '|' +
    'IdEnvio='          + Req.Headers['IdEnvio']          + '|' +
    'Version='          + Req.Headers['Version']          + '|' +
    'TipoDte='          + Req.Headers['TipoDte']          + '|' +
    'CodigoGeneracion=' + Req.Headers['CodigoGeneracion'] + '|' +
    'User_Agent='       + Req.Headers['User_Agent'];

  { His line 5: Req.Body as a string, then Trim. }
  LBody := Req.Body.Trim;
  GLastBodyLen := Length(LBody);

  if LBody.IsEmpty then
  begin
    LObj := TJSONObject.Create;
    LObj.AddPair('error_code', '400');
    LObj.AddPair('message', 'El cuerpo de la peticion no puede estar vacio');
    SendJson(Res, LObj, 400);
    Exit;
  end;

  { His step 8: a base64 payload big enough to cross BOTH compression
    thresholds, which is what made the original fault size-specific. }
  SetLength(LBytes, 4096);
  FillChar(LBytes[0], Length(LBytes), $5A);
  LBig := TNetEncoding.Base64.EncodeBytesToString(LBytes);

  LObj := TJSONObject.Create;
  LObj.AddPair('success', 'true');
  LObj.AddPair('echo_len', TJSONNumber.Create(Length(LBody)));
  LObj.AddPair('data', LBig);
  SendJson(Res, LObj, 200);
end;

{ ALWAYS registered, before everything else, and it is OURS - not one of his.
  It answers one question that no amount of source reading settled: does the
  request reach Horse's pipeline at all before the 500 is produced?

    pipeline hits increases  -> the decode happens inside Horse or a middleware
    pipeline hits unchanged  -> it happens BELOW Horse, i.e. in the provider
                                bridge or in Delphi-Cross-Socket, before the
                                pipeline is entered

  That single bit is worth more than the four eliminations I made by reading. }
procedure PipelineProbe(Req: THorseRequest; Res: THorseResponse; Next: TNextProc);
begin
  TInterlocked.Increment(GPipelineHits);
  GSeenCType  := Req.Headers['Content-Type'];
  GSeenMethod := Req.MethodType.ToString;
  Next;
end;

procedure GetPing(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('text/plain; charset=utf-8').Send('pong');
end;

{ ── client ────────────────────────────────────────────────────────────────── }

function PutBody(const APath, ABody: string; out AStatus: Integer;
  out AReply: string; out AErr: string): Boolean;
var
  LClient: THTTPClient;          { one per call: THTTPClient is not thread-safe }
  LStream: TStringStream;
  LResp:   IHTTPResponse;
  LHeaders: TNetHeaders;
begin
  Result   := False;
  AStatus  := 0;
  AReply   := '';
  AErr     := '';
  LClient  := THTTPClient.Create;
  try
    try
      LClient.ConnectionTimeout := 15000;
      LClient.ResponseTimeout   := 30000;
      { His client sets ContentType on the client, not per-request. }
      LClient.ContentType := 'application/json; charset=utf-8';

      LHeaders := [
        TNetHeader.Create('Subsidiary',       'SUB-001'),
        TNetHeader.Create('Store',            'STO-001'),
        TNetHeader.Create('IdEnvio',          '162'),
        TNetHeader.Create('Version',          '4'),
        TNetHeader.Create('TipoDte',          '03'),
        TNetHeader.Create('CodigoGeneracion', '3084FB2C-2414-4663-B9A3-B4FE56F69B40'),
        TNetHeader.Create('User_Agent',       'HorseCSUserReproTest/1.0')
      ];

      LStream := TStringStream.Create(ABody, TEncoding.UTF8);
      try
        { The cast is required and is also exactly what his production client
          does: THTTPClient inherits Execute from TURLClient, which returns
          IURLResponse, and ContentAsString lives on IHTTPResponse. THTTPClient
          .Get returns IHTTPResponse directly, which is why the sibling probes
          need no cast and this does. }
        LResp   := IHTTPResponse(LClient.Execute('PUT', Url(APath), LStream,
                                                nil, LHeaders));
        AStatus := LResp.StatusCode;
        { His exact failing line. }
        AReply  := LResp.ContentAsString(TEncoding.UTF8);
        Result  := True;
      finally
        LStream.Free;
      end;
    except
      on E: Exception do
        AErr := E.ClassName + ': ' + E.Message;
    end;
  finally
    LClient.Free;
  end;
end;

function IsJsonObject(const AText: string): Boolean;
var
  LVal: TJSONValue;
begin
  Result := False;
  if AText = '' then Exit;
  LVal := TJSONObject.ParseJSONValue(AText);
  try
    Result := LVal is TJSONObject;
  finally
    LVal.Free;
  end;
end;

{ ── server thread ─────────────────────────────────────────────────────────── }

procedure StartServer;
var
  LCfg: THorseCrossSocketConfig;
begin
  LCfg                 := THorseCrossSocketConfig.Default;
  LCfg.Compressible    := True;            { his setting }
  LCfg.MinCompressSize := MIN_COMPRESS;    { his setting }
  LCfg.ServerBanner    := EmptyStr;        { his setting }

  if GUseTls then
  begin
    LCfg.SSLEnabled  := True;
    LCfg.SSLCertFile := ExtractFilePath(ParamStr(0)) + 'certs\server.crt';
    LCfg.SSLKeyFile  := ExtractFilePath(ParamStr(0)) + 'certs\server.key';
  end;

  { ours, first, always - the localiser }
  THorse.Use(
    procedure(Req: THorseRequest; Res: THorseResponse; Next: TNextProc)
    begin
      PipelineProbe(Req, Res, Next);
    end);

{$IFDEF USE_CORS}            THorse.Use(CORS);                          {$ENDIF}
{$IFDEF USE_HANDLEEXCEPTION} THorse.Use(HandleException);               {$ENDIF}
{$IFDEF USE_COMPRESSION}     THorse.Use(Compression(COMPRESS_MW_MIN));  {$ENDIF}
{$IFDEF USE_JHONSON}         THorse.Use(Jhonson('utf-8'));              {$ENDIF}
{$IFDEF USE_JWT}
  { His shape: a key plus SkipRoutes. The key value is irrelevant here - no test
    sends a token, and every route below is skipped, so JWT is present in the
    chain without gating the requests. If JWT rejected them the tests would fail
    for the wrong reason and the bisect would blame it wrongly. }
  THorse.Use(HorseJWT('repro-key-not-a-secret',
    THorseJWTConfig.New.SkipRoutes(['/ping', '/v2/invoice/send'])));
{$ENDIF}
{$IFDEF USE_OCTETSTREAM}     THorse.Use(OctetStream);                   {$ENDIF}
{$IFDEF USE_LOGGER}
  THorseLoggerManager.RegisterProvider(THorseLoggerProviderConsole.New);
  THorse.Use(THorseLoggerManager.HorseCallback);
{$ENDIF}

  { Registered through anonymous methods, which is the idiom the sibling probes
    use and therefore the one proven to compile here. Passing the named
    procedures directly relies on an implicit conversion to THorseCallback
    (a reference-to-procedure type) that nothing in this repo exercises - not
    worth discovering in a file that cannot be compiled where it is written. }
  THorse.Put('/v2/invoice/send',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      PutInvoice(Req, Res);
    end);

  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      GetPing(Req, Res);
    end);

  { His shape: listener on a background thread via ListenWithConfig. }
  TThread.CreateAnonymousThread(
    procedure
    begin
      try
        GStarted.SetEvent;
        THorse.ListenWithConfig(PORT, LCfg);
      except
        on E: Exception do
        begin
          GListenErr := E.ClassName + ': ' + E.Message;
          GStarted.SetEvent;
        end;
      end;
    end).Start;
end;

function WaitServerReady: Boolean;
var
  LClient: THTTPClient;
  LTry: Integer;
  LBody: string;
begin
  { Attempt count rather than a clock: GetTickCount would mean pulling in
    Winapi.Windows, which neither sibling probe needs, and 50 x 200 ms is the
    same 10 s ceiling without the platform unit. }
  Result := False;
  for LTry := 1 to 50 do
  begin
    LClient := THTTPClient.Create;
    try
      try
        LBody := LClient.Get(Url('/ping')).ContentAsString(TEncoding.UTF8);
        { Assert on a body only OUR handler emits: a foreign listener on this
          port would answer something else, and a 200 alone would fool us. }
        if LBody = 'pong' then
          Exit(True);
      except
        { not up yet }
      end;
    finally
      LClient.Free;
    end;
    Sleep(200);
  end;
end;

{ ── main ──────────────────────────────────────────────────────────────────── }

var
  LStatus:   Integer;
  LReply:    string;
  LErr:      string;
  LPayload:  string;
  LBenign:   string;
  LFromFile: Boolean;
  LHits:     Integer;
  LPipe:     Integer;

begin
  try
    GUseTls := (ParamCount >= 1) and SameText(ParamStr(1), 'tls');

    Writeln('Horse + CrossSocket  -  user-reported PUT reproduction');
    Writeln('  scheme ' + Scheme + ' | port ' + IntToStr(PORT) +
            ' | Compressible True | MinCompressSize ' + IntToStr(MIN_COMPRESS));
    Write  ('  middleware:');
{$IFDEF USE_CORS}            Write(' CORS');            {$ENDIF}
{$IFDEF USE_HANDLEEXCEPTION} Write(' HandleException'); {$ENDIF}
{$IFDEF USE_COMPRESSION}     Write(' Compression');     {$ENDIF}
{$IFDEF USE_JHONSON}         Write(' Jhonson');         {$ENDIF}
{$IFDEF USE_JWT}             Write(' JWT');             {$ENDIF}
{$IFDEF USE_OCTETSTREAM}     Write(' OctetStream');     {$ENDIF}
{$IFDEF USE_LOGGER}          Write(' Logger');          {$ENDIF}
    Writeln;
{$IFNDEF USE_JHONSON}
    Writeln('  NOTE: Jhonson is OFF, so the route renders JSON itself.');
    Writeln('        Res.Send(TJSONObject) alone would send an EMPTY body.');
{$ENDIF}
    Writeln;

    LPayload := LoadPayload(TRIGGER_VALUE, LFromFile);
    LBenign  := StringReplace(LPayload, '13%', '13 pct', [rfReplaceAll]);

    if LFromFile then
      Writeln('  payload: Put_Body.json beside the exe (' +
              IntToStr(Length(LPayload)) + ' chars)')
    else
      Writeln('  payload: embedded fallback (' +
              IntToStr(Length(LPayload)) + ' chars)');
    if Pos('%', LPayload) = 0 then
    begin
      Void('the payload contains no ''%'' - T1 cannot exercise the fault.');
      Halt(GExitCode);
    end;
    Writeln('  trigger: ''%'' present, ' + IntToStr(Length(LPayload) - Pos('%', LPayload)) +
            ' chars follow it in the body');
    Writeln;

    GStarted := TEvent.Create(nil, True, False, '');
    try
      StartServer;
      GStarted.WaitFor(5000);
      if GListenErr <> '' then
      begin
        Void('ListenWithConfig raised: ' + GListenErr);
        Halt(GExitCode);
      end;
      if not WaitServerReady then
      begin
        Void('GET /ping never returned the body ''pong'' on port ' + IntToStr(PORT) +
             ' - server not up, or a foreign listener owns the port.');
        Halt(GExitCode);
      end;

      { ── C0 ─────────────────────────────────────────────────────────────── }
      Writeln('  control: benign PUT, no ''%'' anywhere...');
      LHits := GHandlerHits;
      if not PutBody('/v2/invoice/send', LBenign, LStatus, LReply, LErr) then
      begin
        Void('the benign PUT failed at transport level: ' + LErr);
        Halt(GExitCode);
      end;
      Check('C0  benign PUT returns 200', LStatus = 200,
            'status=' + IntToStr(LStatus) + ' reply=' + Copy(LReply, 1, 200));
      Check('C0b the handler actually ran', GHandlerHits > LHits,
            'handler hits did not increase - something answered before the route');
      Check('C0c the reply has a non-empty JSON body', IsJsonObject(LReply),
            'len=' + IntToStr(Length(LReply)) + ' first=' + Copy(LReply, 1, 120));
      Writeln;

      { ── T2 before T1: establishes that the benign path is clean ─────────── }
      Check('T2  the same document without ''%'' is accepted', LStatus = 200,
            'status=' + IntToStr(LStatus));
      Writeln;

      { ── T1, the reproduction ───────────────────────────────────────────── }
      Writeln('  PUT with a trailing ''%'' inside a JSON string value...');
      LHits := GHandlerHits;
      LPipe := GPipelineHits;
      if not PutBody('/v2/invoice/send', LPayload, LStatus, LReply, LErr) then
      begin
        Check('T1  PUT with ''%'' completes at transport level', False, LErr);
      end
      else
      begin
        Writeln('    status=' + IntToStr(LStatus));
        Writeln('    reply =' + Copy(LReply, 1, 300));
        Writeln('    handler ran      : ' + BoolToStr(GHandlerHits > LHits, True) +
                '   (body it saw: ' + IntToStr(GLastBodyLen) + ' chars)');
        Writeln('    pipeline entered : ' + BoolToStr(GPipelineHits > LPipe, True) +
                '   <- THE localiser. False = the 500 is raised BELOW Horse,');
        Writeln('                        i.e. in the provider bridge or in DCS,');
        Writeln('                        before any middleware or route runs.');
        Writeln('    Content-Type seen: ' + GSeenCType);
        Writeln('    method seen      : ' + GSeenMethod);
        Check('T1  a trailing ''%'' in a JSON value does NOT cause a 500',
              LStatus = 200,
              'status=' + IntToStr(LStatus) + ' - if this is 500 with ' +
              '"Error decoding URL style (%XX)", the decode is in the enabled ' +
              'middleware above, or below it if none are enabled');
        Check('T1b the reply is still valid JSON', IsJsonObject(LReply),
              'len=' + IntToStr(Length(LReply)));
      end;
      Writeln;

      { ── T3, the response-side fault ────────────────────────────────────── }
      Check('T3  ContentAsString(UTF8) decodes a >MinCompressSize reply',
            IsJsonObject(LReply) or (LStatus <> 200),
            'a "No mapping for the Unicode character" here means double ' +
            'compression - needs Delphi-Cross-Socket >= 1.0.14');
      Writeln;

      { ── T4, headers ────────────────────────────────────────────────────── }
      Check('T4  all seven request headers reached the handler',
            (Pos('Subsidiary=SUB-001', GLastHeaders) > 0) and
            (Pos('User_Agent=HorseCSUserReproTest/1.0', GLastHeaders) > 0),
            GLastHeaders);
      Writeln;

      Writeln('Results: ' + IntToStr(GPass) + ' passed, ' +
              IntToStr(GFail) + ' failed');
      if GExitCode = 0 then
        GExitCode := GFail;
    finally
      GStarted.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln('UNHANDLED ' + E.ClassName + ': ' + E.Message);
      GExitCode := 2;
    end;
  end;
  Halt(GExitCode);
end.
