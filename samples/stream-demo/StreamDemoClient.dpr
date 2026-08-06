program StreamDemoClient;

// ============================================================================
//  StreamDemoClient — hits StreamDemoServer's 7 diagnostic endpoints, records
//  what came back on the wire, and produces a PASS/FAIL report + artifact
//  files so you can hex-diff the actual bytes when a test fails.
//
//  Uses TCrossHttpClient (from Delphi-Cross-Socket) — same transport as the
//  server side, so the client's dechunking / Content-Length handling exactly
//  mirrors what CrossSocket would do inside a Horse deployment.
//
//  Produces `received-<name>.bin` files next to the .exe for every response,
//  regardless of pass/fail — useful for `fc /b server-payload.bin received-XXX.bin`
//  comparison against files the server saved. See README.md for the full
//  workflow.
//
//  Build (Windows):
//    Delphi IDE → Open → StreamDemoClient.dpr → Project → Build
//
//  Run (server must be listening on 9080):
//    ./StreamDemoClient.exe
// ============================================================================

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.StrUtils,
  Winapi.ActiveX,           { CoInitialize/CoUninitialize for the main thread — }
                            { console apps don't get automatic COM init from   }
                            { the Delphi RTL (VCL apps do via Vcl.Forms).      }
                            { LoadFromStream(sfXML) uses MSXML which is COM.   }
  Net.CrossHttpClient,
  Data.DB,
  FireDAC.Comp.Client,
  FireDAC.Stan.Intf,
  FireDAC.Stan.StorageBin,
  FireDAC.Stan.StorageXML,
  FireDAC.Stan.StorageJSON,
  Xml.Win.msxmldom;         { registers MSXML as a DOM vendor for FireDAC's    }
                            { sfXML — same reason as StreamDemoServer.dpr.     }

const
  // Must match StreamDemoServer.dpr DEMO_PORT. See that file's comment and
  // README.md > Troubleshooting for why 9080 was abandoned (NahimicService
  // and similar OEM services squat on ports in the 9000-9100 range and
  // return `301 → about:blank` for every request).
  BASE_URL   = 'http://127.0.0.1:18080';
  TIMEOUT_MS = 30000;

var
  GPassCount: Integer = 0;
  GFailCount: Integer = 0;

// ─── Reusable helpers ──────────────────────────────────────────────────────

type
  TDownloadResult = record
    Status:    Integer;
    Body:      TBytes;
    HeadersFmt: string;   // key: value \n key: value \n ...
    Errored:   Boolean;
    Error:     string;
  end;

// Synchronous GET. Returns status + full body bytes + headers as text.
function Download(const APath: string): TDownloadResult;
var
  Client:     TCrossHttpClient;
  Event:      TEvent;
  Body:       TMemoryStream;
  ResHolder:  TDownloadResult;
begin
  ResHolder := Default(TDownloadResult);
  Body   := TMemoryStream.Create;
  Event  := TEvent.Create(nil, True, False, '');
  Client := TCrossHttpClient.Create;
  try
    Client.DoRequest('GET', BASE_URL + APath, nil, TBytes(nil), nil, nil,
      procedure(const AResp: ICrossHttpClientResponse)
      var
        I: Integer;
      begin
        if AResp <> nil then
        begin
          ResHolder.Status := AResp.StatusCode;
          if (AResp.Content <> nil) and (AResp.Content.Size > 0) then
          begin
            AResp.Content.Position := 0;
            Body.CopyFrom(AResp.Content, AResp.Content.Size);
          end;
          ResHolder.HeadersFmt := '';
          for I := 0 to AResp.Header.Count - 1 do
            ResHolder.HeadersFmt := ResHolder.HeadersFmt +
              '    ' + AResp.Header.Items[I].Name + ': ' +
              AResp.Header.Items[I].Value + sLineBreak;
        end;
        Event.SetEvent;
      end);
    if Event.WaitFor(TIMEOUT_MS) <> wrSignaled then
    begin
      ResHolder.Errored := True;
      ResHolder.Error   := Format('timeout after %d ms', [TIMEOUT_MS]);
    end;
    SetLength(ResHolder.Body, Body.Size);
    if Body.Size > 0 then
    begin
      Body.Position := 0;
      Body.ReadBuffer(ResHolder.Body[0], Body.Size);
    end;
  finally
    Body.Free;
    Event.Free;
    Client.Free;
  end;
  Result := ResHolder;
end;

procedure Check(const AName: string; APassed: Boolean; const ADetail: string = '');
begin
  if APassed then
  begin
    WriteLn('  PASS  ', AName);
    Inc(GPassCount);
  end
  else
  begin
    if ADetail = '' then
      WriteLn('  FAIL  ', AName)
    else
      WriteLn('  FAIL  ', AName, '  [', ADetail, ']');
    Inc(GFailCount);
  end;
end;

procedure Section(const S: string);
begin
  WriteLn;
  WriteLn('── ', S);
end;

// Save response body to file next to the .exe so it can be hex-diffed against
// a server-side reference file.
procedure SaveArtifact(const AName: string; const ABytes: TBytes);
var
  F: TFileStream;
  Path: string;
begin
  Path := ExtractFilePath(ParamStr(0)) + 'received-' + AName + '.bin';
  F := TFileStream.Create(Path, fmCreate);
  try
    if Length(ABytes) > 0 then
      F.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    F.Free;
  end;
  WriteLn('    saved: ', Path, '  (', Length(ABytes), ' bytes)');
end;

// ─── Test cases ─────────────────────────────────────────────────────────────

procedure TestPositionBug;
var R: TDownloadResult;
begin
  Section('01  GET /stream/position-bug  — server leaves position at end; PATCH-RES-8 resets internally');
  R := Download('/stream/position-bug');
  Check('request completed (no timeout/error)', not R.Errored, R.Error);
  Check('status 200', R.Status = 200, IntToStr(R.Status));
  // PATCH-RES-8: DoSendStream resets Position := 0 before copying, so the
  // "position left at end" gotcha is now a non-issue — full body sent.
  Check('body length = 30 (DoSendStream resets Position internally)',
    Length(R.Body) = 30, Format('got %d bytes', [Length(R.Body)]));
  if Length(R.Body) >= 5 then
    Check('body starts with "Hello"',
      TEncoding.ASCII.GetString(R.Body, 0, 5) = 'Hello',
      TEncoding.ASCII.GetString(R.Body));
  SaveArtifact('position-bug', R.Body);
end;

procedure TestPositionFixed;
var R: TDownloadResult;
begin
  Section('02  GET /stream/position-fixed  — Send<TStream> with Pos:=0 (PATCH-RES-8: now WORKS)');
  R := Download('/stream/position-fixed');
  Check('request completed', not R.Errored, R.Error);
  Check('status 200', R.Status = 200, IntToStr(R.Status));
  Check('body length = 30', Length(R.Body) = 30,
    Format('got %d bytes', [Length(R.Body)]));
  if Length(R.Body) >= 5 then
    Check('body starts with "Hello"',
      TEncoding.ASCII.GetString(R.Body, 0, 5) = 'Hello',
      TEncoding.ASCII.GetString(R.Body));
  SaveArtifact('position-fixed', R.Body);
end;

procedure TestPattern;
var
  R: TDownloadResult;
  I, FirstMismatch: Integer;
  Detail: string;
begin
  Section('03  GET /stream/pattern  — Send<TStream> 1024-byte pattern (PATCH-RES-8: byte-perfect)');
  R := Download('/stream/pattern');
  Check('request completed', not R.Errored, R.Error);
  Check('status 200', R.Status = 200, IntToStr(R.Status));
  Check('body length = 1024', Length(R.Body) = 1024,
    Format('got %d bytes', [Length(R.Body)]));

  FirstMismatch := -1;
  for I := 0 to Length(R.Body) - 1 do
    if R.Body[I] <> Byte(I and $FF) then
    begin
      FirstMismatch := I;
      Break;
    end;
  if (FirstMismatch = -1) or (Length(R.Body) = 0) then
    Detail := ''
  else
    Detail := Format('first mismatch at byte %d: expected %d, got %d',
      [FirstMismatch, FirstMismatch and $FF, R.Body[FirstMismatch]]);
  Check('every byte matches expected [0,1,2...255,0,1,...] pattern',
    (FirstMismatch = -1) and (Length(R.Body) = 1024), Detail);
  SaveArtifact('pattern', R.Body);
end;

procedure TestLarge;
var R: TDownloadResult;
begin
  Section('04  GET /stream/large  — Send<TStream> 64KB (PATCH-RES-8: full payload)');
  R := Download('/stream/large');
  Check('request completed', not R.Errored, R.Error);
  Check('status 200', R.Status = 200, IntToStr(R.Status));
  Check('body length = 65536', Length(R.Body) = 65536,
    Format('got %d bytes', [Length(R.Body)]));
  SaveArtifact('large', R.Body);
end;

procedure TestFDMemTable(const AEndpointName: string; ALoadFormat: TFDStorageFormat;
  const AFormatLabel: string);
var
  R:        TDownloadResult;
  BodyText: string;
  Stream:   TMemoryStream;
  Tbl:      TFDMemTable;
begin
  Section(Format('  GET /stream/fdmemtable-%s  — Send<TStream> with %s (PATCH-RES-8: full stream)',
    [AEndpointName, AFormatLabel]));
  R := Download('/stream/fdmemtable-' + AEndpointName);
  Check('request completed', not R.Errored, R.Error);

  // Environmental skip: FireDAC's sfXML requires MSXML on both server (for
  // SaveToStream) and client (for LoadFromStream).  If MSXML is missing on the
  // server, SaveToStream raises inside the handler → Horse returns 500 with a
  // short error body.  That's a machine-config issue, not something the demo
  // can prove anything about — report SKIP and don't fail the run.
  if (SameText(AEndpointName, 'xml')) and (R.Status = 500) and (Length(R.Body) > 0) then
  begin
    BodyText := TEncoding.ASCII.GetString(R.Body);
    if Pos('MSXML', BodyText) > 0 then
    begin
      WriteLn('  SKIP  server-side SaveToStream(sfXML) raised: ', BodyText);
      WriteLn('        (install MSXML6 to enable this test — see README > Troubleshooting)');
      SaveArtifact('fdmemtable-' + AEndpointName, R.Body);
      Exit;
    end;
  end;

  Check('status 200', R.Status = 200, IntToStr(R.Status));
  Check('body length > 0', Length(R.Body) > 0,
    Format('got %d bytes', [Length(R.Body)]));
  SaveArtifact('fdmemtable-' + AEndpointName, R.Body);

  if Length(R.Body) = 0 then Exit;

  Stream := TMemoryStream.Create;
  Tbl    := TFDMemTable.Create(nil);
  try
    Stream.WriteBuffer(R.Body[0], Length(R.Body));
    Stream.Position := 0;
    try
      Tbl.LoadFromStream(Stream, ALoadFormat);
      Check(Format('FDMemTable.LoadFromStream(..., %s) succeeded', [AFormatLabel]), True);
      Check('3 rows loaded', Tbl.RecordCount = 3, IntToStr(Tbl.RecordCount));
      if Tbl.RecordCount = 3 then
      begin
        Tbl.First;
        Check('row 1: id=1, name=Alpha, amount=10.5',
          (Tbl.FieldByName('id').AsInteger    = 1) and
          (Tbl.FieldByName('name').AsString   = 'Alpha') and
          (Abs(Tbl.FieldByName('amount').AsFloat - 10.5) < 0.001));
      end;
    except
      on E: Exception do
        Check(Format('FDMemTable.LoadFromStream(..., %s) succeeded', [AFormatLabel]),
          False, E.ClassName + ': ' + E.Message);
    end;
  finally
    Tbl.Free;
    Stream.Free;
  end;
end;

// ─── SendFile group — the correct API for stream bodies ────────────────────

procedure TestSendFileFixed;
var R: TDownloadResult;
begin
  Section('08  GET /stream/send-file-fixed  — SendFile 30-byte payload (WORKS)');
  R := Download('/stream/send-file-fixed');
  Check('request completed', not R.Errored, R.Error);
  Check('status 200', R.Status = 200, IntToStr(R.Status));
  Check('body length = 30', Length(R.Body) = 30,
    Format('got %d bytes', [Length(R.Body)]));
  if Length(R.Body) >= 5 then
    Check('body starts with "Hello"',
      TEncoding.ASCII.GetString(R.Body, 0, 5) = 'Hello',
      TEncoding.ASCII.GetString(R.Body));
  SaveArtifact('send-file-fixed', R.Body);
end;

procedure TestSendFilePattern;
var
  R: TDownloadResult;
  I, FirstMismatch: Integer;
  Detail: string;
begin
  Section('09  GET /stream/send-file-pattern  — SendFile 1024-byte pattern (WORKS)');
  R := Download('/stream/send-file-pattern');
  Check('request completed', not R.Errored, R.Error);
  Check('status 200', R.Status = 200, IntToStr(R.Status));
  Check('body length = 1024', Length(R.Body) = 1024,
    Format('got %d bytes', [Length(R.Body)]));

  FirstMismatch := -1;
  for I := 0 to Length(R.Body) - 1 do
    if R.Body[I] <> Byte(I and $FF) then
    begin
      FirstMismatch := I;
      Break;
    end;
  if (FirstMismatch = -1) or (Length(R.Body) = 0) then
    Detail := ''
  else
    Detail := Format('first mismatch at byte %d: expected %d, got %d',
      [FirstMismatch, FirstMismatch and $FF, R.Body[FirstMismatch]]);
  Check('every byte matches expected [0,1,2...255,0,1,...] pattern',
    (FirstMismatch = -1) and (Length(R.Body) = 1024), Detail);
  SaveArtifact('send-file-pattern', R.Body);
end;

procedure TestSendFileFDMemTable;
var
  R:      TDownloadResult;
  Stream: TMemoryStream;
  Tbl:    TFDMemTable;
begin
  Section('10  GET /stream/send-file-fdmemtable-binary  — SendFile FDMemTable sfBinary (WORKS)');
  R := Download('/stream/send-file-fdmemtable-binary');
  Check('request completed', not R.Errored, R.Error);
  Check('status 200', R.Status = 200, IntToStr(R.Status));
  Check('body length > 0', Length(R.Body) > 0,
    Format('got %d bytes', [Length(R.Body)]));
  SaveArtifact('send-file-fdmemtable-binary', R.Body);

  if Length(R.Body) = 0 then Exit;

  Stream := TMemoryStream.Create;
  Tbl    := TFDMemTable.Create(nil);
  try
    Stream.WriteBuffer(R.Body[0], Length(R.Body));
    Stream.Position := 0;
    try
      Tbl.LoadFromStream(Stream, sfBinary);
      Check('FDMemTable.LoadFromStream(..., sfBinary) succeeded', True);
      Check('3 rows loaded', Tbl.RecordCount = 3, IntToStr(Tbl.RecordCount));
      if Tbl.RecordCount = 3 then
      begin
        Tbl.First;
        Check('row 1: id=1, name=Alpha, amount=10.5',
          (Tbl.FieldByName('id').AsInteger    = 1) and
          (Tbl.FieldByName('name').AsString   = 'Alpha') and
          (Abs(Tbl.FieldByName('amount').AsFloat - 10.5) < 0.001));
      end;
    except
      on E: Exception do
        Check('FDMemTable.LoadFromStream(..., sfBinary) succeeded',
          False, E.ClassName + ': ' + E.Message);
    end;
  finally
    Tbl.Free;
    Stream.Free;
  end;
end;

// ─── Main ──────────────────────────────────────────────────────────────────

begin
  // Console apps don't get automatic COM init from the Delphi RTL, so
  // FireDAC's sfXML LoadFromStream (MSXML-based, COM) fails without this.
  // Xml.Win.msxmldom uses reference above registers MSXML as the DOM vendor;
  // this call activates COM on the main thread so MSXML can be created.
  CoInitialize(nil);
  try
    WriteLn('StreamDemoClient — CrossSocket TStream diagnostics');
    WriteLn('Target: ', BASE_URL);
    WriteLn('Artifacts: received-*.bin next to this .exe (', ExtractFilePath(ParamStr(0)), ')');
    WriteLn('Ensure StreamDemoServer.exe is running at ', BASE_URL, '.');
    WriteLn;

    TestPositionBug;
    TestPositionFixed;
    TestPattern;
    TestLarge;
    TestFDMemTable('binary', sfBinary, 'sfBinary');
    TestFDMemTable('xml',    sfXML,    'sfXML');
    TestFDMemTable('json',   sfJSON,   'sfJSON');

    // SendFile group — the correct API for stream bodies
    TestSendFileFixed;
    TestSendFilePattern;
    TestSendFileFDMemTable;

    WriteLn;
    WriteLn(Format('[StreamDemo] %d passed, %d failed', [GPassCount, GFailCount]));
    if GFailCount > 0 then
    begin
      WriteLn('[StreamDemo] Some tests FAILED — inspect the received-*.bin files or hex-diff against server-side references.');
      ExitCode := 1;
    end
    else
      WriteLn('[StreamDemo] All tests PASSED.');
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, 'FATAL: ', E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
  CoUninitialize;

  WriteLn;
  Write('Press ENTER to exit...');
  ReadLn;
end.
