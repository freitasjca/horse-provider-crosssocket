program HorseCSDiagClient;

{$APPTYPE CONSOLE}

(*
  Horse + CrossSocket  —  PUT / response-encoding DIAGNOSTIC client
  =================================================================
  Destination: horse-provider-crosssocket/samples/tests/HorseCSDiagClient.dpr

  Run HorseCSDiagServer first. Then:

    HorseCSDiagClient.exe                          → http://127.0.0.1:18080
    HorseCSDiagClient.exe http://127.0.0.1:18080   → explicit base URL

  This deliberately uses System.Net.HttpClient (THTTPClient), NOT the
  CrossSocket client used by the other test programs in this folder, because
  THTTPClient is what fails in the report and its decompression behaviour is
  part of what is being tested.

  What it does
  ------------
  Phase 1  The control matrix, with AutomaticDecompression OFF:
             method {GET, POST, PUT} x route {small, large, accents}
                                     x Accept-Encoding {absent, gzip}
           One line per case. This answers the central question:

             only PUT fails              -> the method really is the variable
             every /large fails          -> it was SIZE all along, not PUT
             only Accept-Encoding: gzip  -> it is compression, conclusively
               cases fail

  Phase 2  Re-runs every Phase 1 failure with AutomaticDecompression ON.
           If the failures turn into passes, the payload was compressed and
           the client simply was not decompressing it.

  Phase 3  Full forensics on the first failing case: every response header,
           a hex dump of the first bytes, magic-number detection, and the
           exact exception from ContentAsString(TEncoding.UTF8).

  --probe  Standalone mode. Skips all of the above and runs the same forensics
           against ONE arbitrary URL, so it can be aimed at a real server:

             HorseCSDiagClient --probe <METHOD> <URL> [Name:Value ...] [--body <text>]

           AutomaticDecompression is OFF, so what it prints is what is on the
           wire. Use this when the matrix passes but the real endpoint fails.

  Reading a FAIL
  --------------
  "EEncodingError: No mapping for the Unicode character..." means the bytes
  are not valid UTF-8. Phase 3 tells you which bytes:
     1F 8B ...  -> gzip. The server compressed and this client did not expand.
     78 01/9C/DA -> zlib/deflate. Same story.
     printable   -> not compression. The body is text that got truncated or
                    re-encoded; compare "declared" vs "actual" byte counts.
*)

uses
  System.SysUtils,
  System.Classes,
  System.Net.HttpClient,
  System.Net.URLClient;

const
  DEFAULT_BASE_URL = 'http://127.0.0.1:18080';

type
  TProbeCase = record
    Method:         string;
    Route:          string;
    SendAcceptGzip: Boolean;
  end;

  TProbeResult = record
    Ok:            Boolean;
    StatusCode:    Integer;
    Detail:        string;   // exception text, or a short note
    ContentEnc:    string;
    DeclaredLen:   string;   // Content-Length header as sent, '' if absent
    ActualLen:     Integer;  // bytes actually received
    TransferEnc:   string;
  end;

var
  GBaseURL:   string;
  GPassCount: Integer = 0;
  GFailCount: Integer = 0;

// ── Small helpers ─────────────────────────────────────────────────────────────

// No 'const' on the interface parameter: const skips the _AddRef, so if the
// caller released its reference mid-call the response could be freed underneath
// us. const stays on AName, which is a string.
function GetHeader(AResponse: IHTTPResponse; const AName: string): string;
var
  LPair: TNameValuePair;
begin
  { Looked up by hand rather than via HeaderValue[] so this compiles across
    RTL versions without relying on that indexer being present. }
  Result := '';
  for LPair in AResponse.Headers do
    if SameText(LPair.Name, AName) then
      Exit(LPair.Value);
end;

function HexPreview(const ABytes: TBytes; const AMaxCount: Integer): string;
var
  I: Integer;
  LCount: Integer;
begin
  Result := '';
  LCount := Length(ABytes);
  if LCount > AMaxCount then
    LCount := AMaxCount;
  for I := 0 to LCount - 1 do
    Result := Result + IntToHex(ABytes[I], 2) + ' ';
  Result := Trim(Result);
end;

function PrintablePreview(const ABytes: TBytes; const AMaxCount: Integer): string;
var
  I: Integer;
  LCount: Integer;
  LChar:     Byte;
begin
  Result := '';
  LCount := Length(ABytes);
  if LCount > AMaxCount then
    LCount := AMaxCount;
  for I := 0 to LCount - 1 do
  begin
    LChar := ABytes[I];
    if (LChar >= 32) and (LChar < 127) then
      Result := Result + Chr(LChar)
    else
      Result := Result + '.';
  end;
end;

{ Name the payload from its leading bytes. This is the single fastest way to
  tell "compressed" from "corrupted text". }
function DescribeMagic(const ABytes: TBytes): string;
begin
  Result := 'not a known compressed format';
  if Length(ABytes) < 2 then
    Exit('(too short to classify)');

  if (ABytes[0] = $1F) and (ABytes[1] = $8B) then
    Exit('GZIP (1F 8B) — server compressed the body, client did not decompress')
  else if (ABytes[0] = $78) and (ABytes[1] in [$01, $5E, $9C, $DA]) then
    Exit('ZLIB/DEFLATE (78 ..) — server compressed the body, client did not decompress')
  else if (ABytes[0] = $EF) and (ABytes[1] = $BB) then
    Exit('UTF-8 BOM')
  else if ((ABytes[0] = $FF) and (ABytes[1] = $FE)) or
          ((ABytes[0] = $FE) and (ABytes[1] = $FF)) then
    Exit('UTF-16 BOM — body is not UTF-8 at all');
end;

function ReadAllBytes(const AStream: TStream): TBytes;
begin
  SetLength(Result, 0);
  if not Assigned(AStream) then
    Exit;
  AStream.Position := 0;
  SetLength(Result, AStream.Size);
  if Length(Result) > 0 then
    AStream.ReadBuffer(Result[0], Length(Result));
  AStream.Position := 0;
end;

function CaseLabel(const ACase: TProbeCase): string;
begin
  if ACase.SendAcceptGzip then
    Result := Format('%-4s %-16s A-E:gzip', [ACase.Method, ACase.Route])
  else
    Result := Format('%-4s %-16s A-E:none', [ACase.Method, ACase.Route]);
end;

{ Declared here rather than beside the other reporting helpers because Delphi
  resolves routines strictly top-down: RunCase calls it. }
function IfThenStr(const ACondition: Boolean; const ATrue, AFalse: string): string;
begin
  if ACondition then
    Result := ATrue
  else
    Result := AFalse;
end;

// ── The probe ─────────────────────────────────────────────────────────────────

function RunCase(const ACase: TProbeCase; const AAutoDecompress: Boolean;
  const AVerbose: Boolean): TProbeResult;
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
  LBodyStm:  TStringStream;
  LHeaders:  TNetHeaders;
  LBytes:    TBytes;
  LText:     string;
  LPair:     TNameValuePair;
begin
  Result := Default(TProbeResult);
  Result.Ok := False;

  LClient := THTTPClient.Create;
  try
    if AAutoDecompress then
      LClient.AutomaticDecompression := [THTTPCompressionMethod.GZip,
                                         THTTPCompressionMethod.Deflate]
    else
      LClient.AutomaticDecompression := [];

    SetLength(LHeaders, 0);
    if ACase.SendAcceptGzip then
      LHeaders := [TNameValuePair.Create('Accept-Encoding', 'gzip, deflate')];

    { POST/PUT carry a body; GET does not. Matches the reported client. }
    LBodyStm := nil;
    try
      if SameText(ACase.Method, 'GET') then
        LClient.ContentType := 'application/json; charset=utf-8'
      else
      begin
        LBodyStm := TStringStream.Create('{"probe":"request body"}', TEncoding.UTF8);
        LClient.ContentType := 'application/json; charset=utf-8';
      end;

      try
        // The 5-argument string-URL Execute is declared on TURLClient, not on
        // THTTPClient, so it returns IURLResponse and assigning it straight to
        // an IHTTPResponse is E2010. IHTTPResponse descends from IURLResponse
        // and has a GUID, so 'as' does a real QueryInterface here -- preferred
        // over a hard IHTTPResponse(...) cast, which would reinterpret blindly.
        // StatusCode is the reason the cast is needed at all: ContentStream,
        // ContentAsString and Headers are on IURLResponse, StatusCode is not.
        LResponse := LClient.Execute(ACase.Method, GBaseURL + ACase.Route,
                                     LBodyStm, nil, LHeaders) as IHTTPResponse;
      except
        on E: Exception do
        begin
          Result.Detail := Format('transport failed: %s: %s',
            [E.ClassName, E.Message]);
          Exit;
        end;
      end;

      Result.StatusCode  := LResponse.StatusCode;
      Result.ContentEnc  := GetHeader(LResponse, 'Content-Encoding');
      Result.DeclaredLen := GetHeader(LResponse, 'Content-Length');
      Result.TransferEnc := GetHeader(LResponse, 'Transfer-Encoding');

      LBytes := ReadAllBytes(LResponse.ContentStream);
      Result.ActualLen := Length(LBytes);

      if AVerbose then
      begin
        Writeln;
        Writeln('  --- FORENSICS: ', CaseLabel(ACase),
                '  (AutomaticDecompression=', BoolToStr(AAutoDecompress, True), ') ---');
        Writeln('  HTTP status      : ', Result.StatusCode);
        Writeln('  Response headers :');
        for LPair in LResponse.Headers do
          Writeln('      ', LPair.Name, ': ', LPair.Value);
        Writeln('  Declared length  : ',
          IfThenStr(Result.DeclaredLen = '', '(no Content-Length header)',
                    Result.DeclaredLen));
        Writeln('  Actual bytes     : ', Result.ActualLen);
        Writeln('  First 24 bytes   : ', HexPreview(LBytes, 24));
        Writeln('  As printable     : ', PrintablePreview(LBytes, 72));
        Writeln('  Magic            : ', DescribeMagic(LBytes));
      end;

      { The exact call that fails in the report. }
      try
        LText := LResponse.ContentAsString(TEncoding.UTF8);
        Result.Ok := True;
        Result.Detail := Format('decoded %d chars', [Length(LText)]);
        if AVerbose then
          Writeln('  ContentAsString  : OK, ', Length(LText), ' chars');
      except
        on E: Exception do
        begin
          Result.Ok := False;
          Result.Detail := Format('%s: %s', [E.ClassName, E.Message]);
          if AVerbose then
          begin
            Writeln('  ContentAsString  : RAISED');
            Writeln('      ', E.ClassName, ': ', E.Message);
          end;
        end;
      end;

      if AVerbose then
        Writeln('  --- end forensics ---');
    finally
      LBodyStm.Free;
    end;
  finally
    LClient.Free;
  end;
end;

// ── Raw probe — forensics on ONE arbitrary URL ────────────────────────────────

{ Offset of the first byte >= $80, or -1 if the payload is pure ASCII.
  A while-loop with a sentinel rather than a for-loop with Break (Break is
  forbidden by the project's Delphi standards). }
function FirstNonAsciiOffset(const ABytes: TBytes): Integer;
var
  I: Integer;
begin
  Result := -1;
  I := 0;
  while (I <= High(ABytes)) and (Result < 0) do
  begin
    if ABytes[I] >= $80 then
      Result := I;
    Inc(I);
  end;
end;

{ Point this at the REAL failing endpoint and dump exactly what comes back.

    HorseCSDiagClient --probe <METHOD> <URL> [Name:Value ...] [--body <text>]

  Everything else in this program tests the diag server. This does not: it is a
  single request against whatever URL you give it, with whatever headers you
  give it, running the same forensics the matrix uses -- full header list, hex
  dump, magic-number check, and the exact ContentAsString(TEncoding.UTF8) call
  that fails in the report. AutomaticDecompression is deliberately OFF so the
  bytes printed are the bytes on the wire. }
procedure RunRawProbe;
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
  LHeaders:  TNetHeaders;
  LBodyStm:  TStringStream;
  LMethod:   string;
  LUrl:      string;
  LBody:     string;
  LArg:      string;
  LPair:     TNameValuePair;
  LBytes:    TBytes;
  LText:     string;
  LSep:      Integer;
  LOffset:   Integer;
  I:         Integer;
begin
  if (ParamStr(2) = '') or (ParamStr(3) = '') then
  begin
    Writeln('Usage: HorseCSDiagClient --probe <METHOD> <URL> [Name:Value ...] [--body <text>]');
    Writeln('   eg: HorseCSDiagClient --probe PUT http://127.0.0.1:9000/v2/invoice/send ^');
    Writeln('         Subsidiary:S1 Store:ST1 IdEnvio:1 Version:1 TipoDte:01 --body "{}"');
    Exit;
  end;

  LMethod := UpperCase(ParamStr(2));
  LUrl    := ParamStr(3);
  LBody   := '';
  SetLength(LHeaders, 0);

  I := 4;
  while I <= ParamCount do
  begin
    LArg := ParamStr(I);
    if SameText(LArg, '--body') then
    begin
      Inc(I);
      LBody := ParamStr(I);
    end
    else
    begin
      // First colon splits Name:Value; LSep > 1 guarantees a non-empty name.
      LSep := Pos(':', LArg);
      if LSep > 1 then
      begin
        SetLength(LHeaders, Length(LHeaders) + 1);
        LHeaders[High(LHeaders)] :=
          TNameValuePair.Create(Copy(LArg, 1, LSep - 1), Copy(LArg, LSep + 1, MaxInt));
      end;
    end;
    Inc(I);
  end;

  Writeln('RAW PROBE — forensics on one request');
  Writeln('-----------------------------------------------------------');
  Writeln('  ', LMethod, ' ', LUrl);
  for LPair in LHeaders do
    Writeln('  header : ', LPair.Name, ': ', LPair.Value);
  Writeln('  body   : ', Length(LBody), ' chars');
  Writeln;

  LClient := THTTPClient.Create;
  try
    LClient.AutomaticDecompression := [];
    LClient.ContentType := 'application/json; charset=utf-8';

    LBodyStm := nil;
    try
      if LBody <> '' then
        LBodyStm := TStringStream.Create(LBody, TEncoding.UTF8);

      try
        LResponse := LClient.Execute(LMethod, LUrl, LBodyStm, nil, LHeaders) as IHTTPResponse;
      except
        on E: Exception do
        begin
          Writeln('  transport failed: ', E.ClassName, ': ', E.Message);
          Exit;
        end;
      end;

      Writeln('  HTTP status      : ', LResponse.StatusCode);
      Writeln('  Response headers :');
      for LPair in LResponse.Headers do
        Writeln('      ', LPair.Name, ': ', LPair.Value);

      LBytes := ReadAllBytes(LResponse.ContentStream);
      Writeln('  Actual bytes     : ', Length(LBytes));
      Writeln('  First 48 bytes   : ', HexPreview(LBytes, 48));
      Writeln('  As printable     : ', PrintablePreview(LBytes, 120));
      Writeln('  Magic            : ', DescribeMagic(LBytes));

      LOffset := FirstNonAsciiOffset(LBytes);
      if LOffset < 0 then
        Writeln('  Non-ASCII        : none — payload is pure ASCII')
      else
        Writeln(Format('  Non-ASCII        : first at offset %d = $%s',
          [LOffset, IntToHex(LBytes[LOffset], 2)]));

      try
        LText := LResponse.ContentAsString(TEncoding.UTF8);
        Writeln('  ContentAsString  : OK, ', Length(LText), ' chars');
        Writeln('  First 300 chars  : ', Copy(LText, 1, 300));
      except
        on E: Exception do
        begin
          Writeln('  ContentAsString  : RAISED  <<< THIS IS THE REPORTED FAILURE');
          Writeln('      ', E.ClassName, ': ', E.Message);
          Writeln('  The hex dump above is the evidence: look at the offset');
          Writeln('  reported on the Non-ASCII line. A single byte in $80..$FF');
          Writeln('  with no valid continuation byte after it means the payload');
          Writeln('  was encoded as ANSI/CP-1252, not UTF-8.');
        end;
      end;
    finally
      LBodyStm.Free;
    end;
  finally
    LClient.Free;
  end;
end;

// ── Reporting ─────────────────────────────────────────────────────────────────

procedure ReportCase(const ACase: TProbeCase; const AResult: TProbeResult);
var
  LStatus: string;
  LEnc:    string;
begin
  if AResult.Ok then
  begin
    Inc(GPassCount);
    LStatus := 'PASS';
  end
  else
  begin
    Inc(GFailCount);
    LStatus := 'FAIL';
  end;

  LEnc := AResult.ContentEnc;
  if LEnc = '' then
    LEnc := '-';

  Writeln(Format('  %s  %s  http=%d  enc=%-8s bytes=%-7d %s',
    [LStatus, CaseLabel(ACase), AResult.StatusCode, LEnc,
     AResult.ActualLen, AResult.Detail]));
end;

// ── Matrix construction ───────────────────────────────────────────────────────

function BuildMatrix: TArray<TProbeCase>;
const
  METHODS: array[0..2] of string = ('GET', 'POST', 'PUT');
  { /probe/object and /probe/usershape are the ones that matter now: both send a
    TJSONObject rather than a string, which is what the reported handler does and
    what v1 of this matrix never exercised. }
  ROUTES:  array[0..4] of string = ('/probe/small', '/probe/large', '/probe/accents',
                                    '/probe/object', '/probe/usershape');
var
  LList:    TArray<TProbeCase>;
  M:        Integer;
  R:        Integer;
  LGzip:    Boolean;
  LIndex:   Integer;
begin
  SetLength(LList, Length(METHODS) * Length(ROUTES) * 2);
  LIndex := 0;
  for M := Low(METHODS) to High(METHODS) do
    for R := Low(ROUTES) to High(ROUTES) do
      for LGzip := False to True do
      begin
        LList[LIndex].Method         := METHODS[M];
        LList[LIndex].Route          := ROUTES[R];
        LList[LIndex].SendAcceptGzip := LGzip;
        Inc(LIndex);
      end;
  Result := LList;
end;

// ── Main ──────────────────────────────────────────────────────────────────────

var
  GMatrix:      TArray<TProbeCase>;
  GResults:     TArray<TProbeResult>;
  GCase:        TProbeCase;
  GResult:      TProbeResult;
  I:            Integer;
  GFirstFailIx: Integer;
  GRecovered:   Integer;
  GSelfCase:    TProbeCase;
  GSelfResult:  TProbeResult;

begin
  try
    { --probe runs a single forensic request against an arbitrary URL and stops.
      Use it to aim this client at the REAL failing endpoint; everything below
      only ever tests the diag server, which now passes 30/30. }
    if SameText(ParamStr(1), '--probe') then
    begin
      RunRawProbe;
      Writeln;
      Writeln('Done. Press Enter to exit.');
      Readln;
      Exit;
    end;

    GBaseURL := DEFAULT_BASE_URL;
    if ParamCount >= 1 then
      GBaseURL := ParamStr(1);
    while GBaseURL.EndsWith('/') do
      GBaseURL := GBaseURL.Substring(0, GBaseURL.Length - 1);

    Writeln('===========================================================');
    Writeln(' Horse CrossSocket — response-encoding diagnostics (client)');
    Writeln('===========================================================');
    Writeln(' Target: ', GBaseURL);
    Writeln;

    GMatrix := BuildMatrix;
    SetLength(GResults, Length(GMatrix));
    GFirstFailIx := -1;

    // ── Phase 0 — prove this harness can actually fail ───────────────────────
    // /probe/badbytes returns deliberately invalid UTF-8 through the bridge's
    // raw-bytes branch. ContentAsString(TEncoding.UTF8) MUST raise on it. A
    // matrix that has only ever passed says nothing about whether it could
    // detect the reported defect, so this runs first and gates the rest.
    Writeln('PHASE 0 — harness self-test (positive control)');
    Writeln('-----------------------------------------------------------');
    GSelfCase.Method         := 'PUT';
    GSelfCase.Route          := '/probe/badbytes';
    GSelfCase.SendAcceptGzip := False;
    GSelfResult := RunCase(GSelfCase, False, False);
    if GSelfResult.Ok then
    begin
      Writeln('  *** SELF-TEST FAILED — RESULTS BELOW ARE NOT TRUSTWORTHY ***');
      Writeln('  Invalid UTF-8 was decoded without raising, so this client');
      Writeln('  cannot detect the reported failure mode. Every PASS below is');
      Writeln('  meaningless until this is understood.');
    end
    else
      Writeln('  OK — invalid UTF-8 is detected as expected:');
    Writeln('       ' + GSelfResult.Detail);
    Writeln;

    // ── Phase 1 ──────────────────────────────────────────────────────────────
    Writeln('PHASE 1 — control matrix, AutomaticDecompression = OFF');
    Writeln('-----------------------------------------------------------');
    for I := 0 to High(GMatrix) do
    begin
      GCase := GMatrix[I];
      GResult := RunCase(GCase, False, False);
      GResults[I] := GResult;
      ReportCase(GCase, GResult);
      if (not GResult.Ok) and (GFirstFailIx < 0) then
        GFirstFailIx := I;
    end;
    Writeln;
    Writeln(Format('  Phase 1: %d passed, %d failed', [GPassCount, GFailCount]));
    Writeln;

    // ── Phase 2 ──────────────────────────────────────────────────────────────
    if GFailCount = 0 then
    begin
      Writeln('PHASE 2 — skipped: nothing failed.');
      Writeln;
      Writeln('  Every case decoded cleanly as UTF-8. The defect did not');
      Writeln('  reproduce here, so something in the real app differs from');
      Writeln('  this reduction — most likely a middleware, or a handler that');
      Writeln('  writes a stream/TBytes body. Check the server [SLOTS] lines:');
      Writeln('  any request showing ContentStream or BodyBytes is on the');
      Writeln('  raw-bytes branch and is the one to compare against.');
    end
    else
    begin
      Writeln('PHASE 2 — re-running only the failures, AutomaticDecompression = ON');
      Writeln('-----------------------------------------------------------');
      GRecovered := 0;
      for I := 0 to High(GMatrix) do
      begin
        if not GResults[I].Ok then
        begin
          GCase := GMatrix[I];
          GResult := RunCase(GCase, True, False);
          if GResult.Ok then
          begin
            Inc(GRecovered);
            Writeln(Format('  RECOVERED  %s  -> %s',
              [CaseLabel(GCase), GResult.Detail]));
          end
          else
            Writeln(Format('  STILL FAIL %s  -> %s',
              [CaseLabel(GCase), GResult.Detail]));
        end;
      end;
      Writeln;
      Writeln(Format('  Phase 2: %d of %d failures recovered by decompression',
        [GRecovered, GFailCount]));
      Writeln;

      // ── Phase 3 ────────────────────────────────────────────────────────────
      Writeln('PHASE 3 — forensics on the first failing case');
      Writeln('-----------------------------------------------------------');
      RunCase(GMatrix[GFirstFailIx], False, True);
      Writeln;

      Writeln('VERDICT');
      Writeln('-----------------------------------------------------------');
      if GRecovered = GFailCount then
      begin
        Writeln('  Every failure was fixed by enabling decompression.');
        Writeln('  Cause: the server gzip-compressed the response and this');
        Writeln('  client was handing raw gzip bytes to TEncoding.UTF8.');
        Writeln('  Fix either side:');
        Writeln('    client: FHTTPClient.AutomaticDecompression :=');
        Writeln('              [THTTPCompressionMethod.GZip,');
        Writeln('               THTTPCompressionMethod.Deflate];');
        Writeln('    server: ListenWithConfig with Compressible := False');
        Writeln('            (already the Horse default — check you are not');
        Writeln('             overriding it).');
      end
      else if GRecovered = 0 then
      begin
        Writeln('  Decompression changed nothing, so this is NOT compression.');
        Writeln('  Read the Phase 3 hex dump: compare "Declared length" to');
        Writeln('  "Actual bytes", and check the server [SLOTS] line for that');
        Writeln('  route. A ContentStream/BodyBytes slot means the raw-bytes');
        Writeln('  branch emitted non-UTF-8 content.');
      end
      else
        Writeln('  Mixed result — more than one cause is in play. Compare the');
        Writeln('  recovered cases against the ones that still fail.');
    end;

    Writeln;
    Writeln('Done. Press Enter to exit.');
    Readln;
  except
    on E: Exception do
    begin
      Writeln('[FATAL] ', E.ClassName, ': ', E.Message);
      Readln;
    end;
  end;
end.
