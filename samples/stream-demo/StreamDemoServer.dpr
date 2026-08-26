program StreamDemoServer;

// ============================================================================
//  StreamDemoServer — CrossSocket TStream response diagnostics
//
//  Exposes 7 endpoints that exercise the specific failure modes of
//  Res.Send<TStream>(...) on the horse-provider-crosssocket transport.
//  Pair with StreamDemoClient to identify which failure mode a given
//  production issue matches.
//
//  ── HISTORY ────────────────────────────────────────────────────────────────
//  Prior to PATCH-RES-8, `Res.Send<TStream>(S)` was a NO-OP on every Horse
//  provider — Send<T> only assigned `FContent := AContent` and no provider
//  bridge ever read FContent as a stream, so responses went out with
//  `Content-Length: 0` regardless of payload.  This demo originally proved
//  the misuse pattern via the seven `/stream/*` endpoints and the correct
//  workaround via the three `/stream/send-file-*` endpoints.
//
//  PATCH-RES-8 (patches/horse/src/Horse.Response.pas) fixes it: `Send<TStream>`
//  and the new typed `Send(TStream)` overload now copy the stream into the
//  active body slot (FCSContentStream / FWebResponse.ContentStream), default
//  Content-Type to application/octet-stream, and free the source stream.
//  Position is reset to 0 internally, so the historical "position at end"
//  gotcha is also fixed.
//
//  Both endpoint groups now produce identical byte content.  The SendFile
//  group is kept as a regression check — it uses a different code path
//  (FCSContentStream via SendFile) and its parity with Send<TStream> confirms
//  DoSendStream is copying correctly.
//  ───────────────────────────────────────────────────────────────────────────
//
//  Endpoint matrix — Send<TStream> group (all produce full body via PATCH-RES-8):
//    /stream/position-bug        — Send<TStream> position-at-end (auto-fixed)
//    /stream/position-fixed      — Send<TStream> with explicit Position:=0
//    /stream/pattern             — 1024-byte pattern via Send<TStream>
//    /stream/large               — 64 KB payload via Send<TStream>
//    /stream/fdmemtable-binary   — TFDMemTable sfBinary via Send<TStream>
//    /stream/fdmemtable-xml      — TFDMemTable sfXML via Send<TStream>
//    /stream/fdmemtable-json     — TFDMemTable sfJSON via Send<TStream>
//
//  Endpoint matrix — SendFile group (regression checks, always worked):
//    /stream/send-file-fixed        — 30-byte payload via SendFile
//    /stream/send-file-pattern      — 1024-byte pattern via SendFile
//    /stream/send-file-fdmemtable-binary — TFDMemTable sfBinary via SendFile
//
//  Requires:
//    - HashLoad/Horse 3.3.0+
//    - horse-provider-crosssocket
//    - Delphi 10.4+ with FireDAC (Enterprise or higher)
//
//  Build (Windows):
//    Delphi IDE → Open → StreamDemoServer.dpr → Project → Build
//
//  Run:
//    ./StreamDemoServer.exe   (blocks; Ctrl-C to stop)
//
//  Test:
//    ./StreamDemoClient.exe   (from same folder, hits localhost:9080)
// ============================================================================

{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_CROSSSOCKET}

uses
  System.SysUtils,
  System.Classes,
  Winapi.ActiveX,                        { CoInitialize/CoUninitialize — needed on      }
                                         { CrossSocket worker threads for MSXML COM     }
                                         { calls (FireDAC sfXML). Main thread already   }
                                         { has COM init'd by the Delphi RTL, but        }
                                         { CrossSocket IOCP worker threads do not, so   }
                                         { CoCreateInstance(IXMLDOMDocument) silently   }
                                         { returns a broken interface → "No active      }
                                         { document" on the first DOM operation.        }
  Horse,
  Horse.Provider.CrossSocket,
  Data.DB,                               { for TFieldType constants                     }
  FireDAC.Comp.Client,                   { TFDMemTable                                  }
  FireDAC.Stan.Intf,                     { TFDStorageFormat: sfBinary/sfXML/sfJSON/etc }
  FireDAC.Stan.StorageBin,               { pulls in the binary persistence unit         }
  FireDAC.Stan.StorageXML,               { pulls in the XML persistence unit            }
  FireDAC.Stan.StorageJSON,              { pulls in the JSON persistence unit           }
  Xml.Win.msxmldom;                      { registers MSXML as a DOM vendor — required   }
                                         { for FireDAC's sfXML persistence to work.     }
                                         { Without this uses-clause reference, MSXML    }
                                         { is not on Delphi's DOM-vendor list even if   }
                                         { msxml6.dll is present on disk, and           }
                                         { SaveToStream(S, sfXML) raises "MSXML is not  }
                                         { installed". The unit's initialization        }
                                         { section calls RegisterDOMVendor at startup;  }
                                         { no explicit factory assignment is needed.    }

const
  // Port 18080 chosen deliberately: NahimicService.exe and several other
  // Windows OEM audio/vendor services bind random ports in the 9000-9100 range
  // on laptops and return `301 Moved Permanently → Location: about:blank`
  // for every request, which looks a lot like a broken Horse route. Picking
  // an uncommon port in the private range avoids that entire category of
  // false positive. See README.md > Troubleshooting.
  DEMO_PORT       = 18080;
  BUG_PAYLOAD     : AnsiString = 'Hello CrossSocket Stream World';   // 30 bytes ASCII
  PATTERN_BYTES   = 1024;
  LARGE_BYTES     = 65536;

// ─── Sample table used by the FDMemTable endpoints ──────────────────────────

function BuildSampleTable: TFDMemTable;
begin
  Result := TFDMemTable.Create(nil);
  Result.FieldDefs.Add('id',     ftInteger);
  Result.FieldDefs.Add('name',   ftString, 40);
  Result.FieldDefs.Add('amount', ftFloat);
  Result.CreateDataSet;
  Result.AppendRecord([1, 'Alpha', 10.5]);
  Result.AppendRecord([2, 'Beta',  20.75]);
  Result.AppendRecord([3, 'Gamma', 33.33]);
end;

// ─── 1. Position bug ────────────────────────────────────────────────────────
// Deliberately leaves the stream position at end-of-stream after writing.
// Res.Send<TStream> reads from the current position to end → 0 bytes sent.
// This is the #1 gotcha with Send<TStream> and the most likely cause of
// "empty body" symptoms on the client side.

procedure GetPositionBug(Req: THorseRequest; Res: THorseResponse);
var
  S: TMemoryStream;
begin
  S := TMemoryStream.Create;
  S.WriteBuffer(BUG_PAYLOAD[1], Length(BUG_PAYLOAD));   // position now = 30
  // NOTE: S.Position INTENTIONALLY not reset — this is the bug we're testing.
  Res.ContentType('text/plain').Send<TStream>(S).Status(200);
end;

// ─── 2. Position fixed ──────────────────────────────────────────────────────
// Same code as position-bug, but with Position := 0 before Send. This is the
// correct pattern — client should receive the full 30-byte payload.

procedure GetPositionFixed(Req: THorseRequest; Res: THorseResponse);
var
  S: TMemoryStream;
begin
  S := TMemoryStream.Create;
  S.WriteBuffer(BUG_PAYLOAD[1], Length(BUG_PAYLOAD));
  S.Position := 0;      // ← THE fix
  Res.ContentType('text/plain').Send<TStream>(S).Status(200);
end;

// ─── 3. Deterministic pattern ───────────────────────────────────────────────
// 1024 bytes of [0,1,2...255,0,1,...]. The client verifies every byte,
// catching corruption / truncation / off-by-one issues in the transport.

procedure GetPattern(Req: THorseRequest; Res: THorseResponse);
var
  S: TMemoryStream;
  Buf: array[0..PATTERN_BYTES - 1] of Byte;
  I: Integer;
begin
  for I := 0 to High(Buf) do
    Buf[I] := Byte(I and $FF);
  S := TMemoryStream.Create;
  S.WriteBuffer(Buf, PATTERN_BYTES);
  S.Position := 0;
  Res.ContentType('application/octet-stream')
     .AddHeader('X-Pattern-Bytes', IntToStr(PATTERN_BYTES))
     .Send<TStream>(S).Status(200);
end;

// ─── 4. Large payload ───────────────────────────────────────────────────────
// 64 KB body. Depending on CrossSocket's Content-Length / Transfer-Encoding
// heuristics, this may cross the threshold that triggers chunked encoding.
// A client that doesn't correctly dechunk will show extra "chunk-length"
// hex prefixes in the body — captured by the client's diagnostic report.

procedure GetLarge(Req: THorseRequest; Res: THorseResponse);
var
  S: TMemoryStream;
  Buf: array[0..1023] of Byte;
  I: Integer;
begin
  for I := 0 to High(Buf) do
    Buf[I] := Byte(I and $FF);
  S := TMemoryStream.Create;
  for I := 0 to 63 do              // 64 * 1024 = 65536
    S.WriteBuffer(Buf, SizeOf(Buf));
  S.Position := 0;
  Res.ContentType('application/octet-stream').Send<TStream>(S).Status(200);
end;

// ─── 5/6/7. TFDMemTable in each persistence format ──────────────────────────
// The client tries to load each with the MATCHING format; a mismatch produces
// the "invalid format" error the user complained about. Running all three
// server-side and having the client attempt each format on each response
// makes the compatibility matrix explicit.

procedure GetFDMemTableBinary(Req: THorseRequest; Res: THorseResponse);
var
  Tbl: TFDMemTable;
  S:   TMemoryStream;
begin
  Tbl := BuildSampleTable;
  try
    S := TMemoryStream.Create;
    Tbl.SaveToStream(S, sfBinary);
    S.Position := 0;
    Res.ContentType('application/octet-stream')
       .AddHeader('X-FDMemTable-Format', 'sfBinary')
       .Send<TStream>(S).Status(200);
  finally
    Tbl.Free;
  end;
end;

procedure GetFDMemTableXml(Req: THorseRequest; Res: THorseResponse);
var
  Tbl: TFDMemTable;
  S:   TMemoryStream;
begin
  // CrossSocket worker threads don't have COM initialized, but MSXML (used
  // internally by FireDAC's sfXML persistence) needs it — otherwise
  // CoCreateInstance(IXMLDOMDocument) returns a broken interface reference
  // and the first DOM operation fails with "No active document".
  // Call this per handler that touches MSXML; leave sfBinary/sfJSON handlers
  // alone — they use pure Delphi code and don't touch COM.
  CoInitialize(nil);
  try
    Tbl := BuildSampleTable;
    try
      S := TMemoryStream.Create;
      Tbl.SaveToStream(S, sfXML);
      S.Position := 0;
      Res.ContentType('application/xml; charset=utf-8')
         .AddHeader('X-FDMemTable-Format', 'sfXML')
         .Send<TStream>(S).Status(200);
    finally
      Tbl.Free;
    end;
  finally
    CoUninitialize;
  end;
end;

procedure GetFDMemTableJson(Req: THorseRequest; Res: THorseResponse);
var
  Tbl: TFDMemTable;
  S:   TMemoryStream;
begin
  Tbl := BuildSampleTable;
  try
    S := TMemoryStream.Create;
    Tbl.SaveToStream(S, sfJSON);
    S.Position := 0;
    Res.ContentType('application/json; charset=utf-8')
       .AddHeader('X-FDMemTable-Format', 'sfJSON')
       .Send<TStream>(S).Status(200);
  finally
    Tbl.Free;
  end;
end;

// ─── 8/9/10. The CORRECT pattern — Res.SendFile(AStream, name, type) ──────
// Same payloads as endpoints 2, 3, 5 but routed through SendFile instead of
// Send<TStream>. SendFile populates FCSContentStream, which the WriteBody
// bridge in horse-provider-crosssocket actually reads and writes to the wire.
// These endpoints demonstrate that the transport is fine — the empty-body
// bug in the Send<TStream> endpoints is an API misuse, not a provider bug.

procedure GetSendFileFixed(Req: THorseRequest; Res: THorseResponse);
var
  S: TMemoryStream;
begin
  S := TMemoryStream.Create;
  try
    S.WriteBuffer(BUG_PAYLOAD[1], Length(BUG_PAYLOAD));
    S.Position := 0;
    Res.SendFile(S, 'payload.txt', 'text/plain').Status(200);
  finally
    S.Free;  // SendFile copies into an owned buffer — safe to free ours
  end;
end;

procedure GetSendFilePattern(Req: THorseRequest; Res: THorseResponse);
var
  S:   TMemoryStream;
  Buf: array[0..PATTERN_BYTES - 1] of Byte;
  I:   Integer;
begin
  for I := 0 to High(Buf) do
    Buf[I] := Byte(I and $FF);
  S := TMemoryStream.Create;
  try
    S.WriteBuffer(Buf, PATTERN_BYTES);
    S.Position := 0;
    Res.SendFile(S, 'pattern.bin', 'application/octet-stream').Status(200);
  finally
    S.Free;
  end;
end;

procedure GetSendFileFDMemTableBinary(Req: THorseRequest; Res: THorseResponse);
var
  Tbl: TFDMemTable;
  S:   TMemoryStream;
begin
  Tbl := BuildSampleTable;
  try
    S := TMemoryStream.Create;
    try
      Tbl.SaveToStream(S, sfBinary);
      S.Position := 0;
      Res.SendFile(S, 'data.bin', 'application/octet-stream').Status(200);
    finally
      S.Free;
    end;
  finally
    Tbl.Free;
  end;
end;

// ─── Main ──────────────────────────────────────────────────────────────────

begin
  try
    // MSXML is registered as a DOM vendor automatically via the
    // Xml.Win.msxmldom initialization section — see the uses clause above.
    // No explicit factory assignment is required for FireDAC's sfXML to work.

    WriteLn('StreamDemoServer — CrossSocket TStream diagnostics on port ', DEMO_PORT);
    WriteLn('URL base: http://127.0.0.1:', DEMO_PORT);
    WriteLn;
    WriteLn('Endpoints — Send<TStream> group (fixed by PATCH-RES-8, all produce full body):');
    WriteLn('  GET /stream/position-bug              — Send<TStream> pos-at-end (auto-fixed)');
    WriteLn('  GET /stream/position-fixed            — Send<TStream> with explicit Position:=0');
    WriteLn('  GET /stream/pattern                   — 1024-byte pattern');
    WriteLn('  GET /stream/large                     — 64KB payload');
    WriteLn('  GET /stream/fdmemtable-binary         — TFDMemTable sfBinary');
    WriteLn('  GET /stream/fdmemtable-xml            — TFDMemTable sfXML');
    WriteLn('  GET /stream/fdmemtable-json           — TFDMemTable sfJSON');
    WriteLn;
    WriteLn('Endpoints — SendFile group (regression checks, always worked):');
    WriteLn('  GET /stream/send-file-fixed           — 30-byte payload via SendFile');
    WriteLn('  GET /stream/send-file-pattern         — 1024-byte pattern via SendFile');
    WriteLn('  GET /stream/send-file-fdmemtable-binary — TFDMemTable sfBinary via SendFile');
    WriteLn;
    WriteLn('Run the paired StreamDemoClient.exe to test.');
    WriteLn('Ctrl-C to stop.');
    WriteLn;

    THorse.Get('/stream/position-bug',      GetPositionBug);
    THorse.Get('/stream/position-fixed',    GetPositionFixed);
    THorse.Get('/stream/pattern',           GetPattern);
    THorse.Get('/stream/large',             GetLarge);
    THorse.Get('/stream/fdmemtable-binary', GetFDMemTableBinary);
    THorse.Get('/stream/fdmemtable-xml',    GetFDMemTableXml);
    THorse.Get('/stream/fdmemtable-json',   GetFDMemTableJson);

    // SendFile group — the correct pattern
    THorse.Get('/stream/send-file-fixed',              GetSendFileFixed);
    THorse.Get('/stream/send-file-pattern',            GetSendFilePattern);
    THorse.Get('/stream/send-file-fdmemtable-binary',  GetSendFileFDMemTableBinary);

    THorse.Listen(DEMO_PORT);
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, '[FATAL] ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
