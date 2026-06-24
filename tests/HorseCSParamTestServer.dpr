program HorseCSParamTestServer;

{$APPTYPE CONSOLE}

{
  Horse + CrossSocket  —  Named-parameter isolation + memory-leak test server
  ===========================================================================
  Destination: horse-provider-crosssocket/samples/tests/HorseCSParamTestServer.dpr

  Requires: HORSE_PROVIDER_CROSSSOCKET (or legacy HORSE_CROSSSOCKET) must be set
  in Project Options → Conditional defines before building.

  Two test concerns:
    1. Named-param contamination — value from request N must not appear in N+1.
    2. Memory growth — process working-set must not grow unboundedly under load.

  Port: 9100 (distinct from CrossSocket integration tests on 9010 and mORMot on 9200).
  Start this server first, then run HorseCSParamTestClient.

  Routes registered:
    GET    /ping                                   health check
    DELETE /param/:id                              single-param echo (primary test target)
    PUT    /param/:id                              single-param echo
    GET    /param/:id                              single-param echo
    PATCH  /param/:id                              single-param echo
    POST   /param/:id                              single-param + body echo
    DELETE /multi/:a/:b                            two-param echo
    PUT    /multi/:a/:b                            two-param echo
    DELETE /product_category/uuid_product_category/:uuid   real-world pattern
    PUT    /product_category/uuid_product_category/:uuid   real-world pattern
    GET    /mem                                    process working-set in KB
    GET    /mem/pool                               pool idle-context count + constants

  ReportMemoryLeaksOnShutdown is enabled when running under the Delphi debugger
  (DebugHook <> 0).  It has no effect in non-interactive CI runs.
}

{$IFNDEF HORSE_PROVIDER_CROSSSOCKET}
  {$IFNDEF HORSE_CROSSSOCKET}
    {$MESSAGE FATAL 'Set HORSE_PROVIDER_CROSSSOCKET (or HORSE_CROSSSOCKET) in Project Options → Conditional defines'}
  {$ENDIF}
{$ENDIF}

uses
  System.SysUtils,
  System.Classes,
{$IFDEF MSWINDOWS}
  Winapi.Windows,
  Winapi.PsAPI,
{$ENDIF}
  Horse,
  Horse.Commons,
  Horse.Core.Cookie,
  Horse.Provider.CrossSocket,
  Horse.Provider.CrossSocket.Pool;

const
  TEST_PORT = 9100;

  // ── Stream-body fixtures (Section H) ──────────────────────────────────────────
  // Response bodies served as a TStream via Res.SendFile.  The CrossSocket bridge
  // sends them with ACrossRes.Send(Stream); the client checks the bytes arrive
  // intact.  Must match HorseCSParamTestClient.
  STREAM_SMALL_PAYLOAD =
    'stream-body-OK-0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  STREAM_LARGE_LEN = 65536;   // large body — guards against truncation

  // ── Wildcard + SendFile regression (Section J) ────────────────────────────────
  // Payload served by the Get('/*') catch-all via SendFile.  Must match the client.
  WILDCARD_PAYLOAD = 'wildcard-sendfile-OK-0123456789-ABCDEF';

// ── Helpers ────────────────────────────────────────────────────────────────────

{ Minimal JSON string escaping for inline Format() calls. }
function JE(const S: string): string;
begin
  Result := StringReplace(S,  '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
end;

{ Deterministic ASCII payload of ALen bytes (char[i] = 'A'..'Z' cycling).
  The client builds the identical string to compare byte-for-byte. }
function BuildLargePayload(const ALen: Integer): string;
var
  I: Integer;
begin
  SetLength(Result, ALen);
  for I := 1 to ALen do
    Result[I] := Chr(Ord('A') + ((I - 1) mod 26));
end;

{ Current process working-set size in KB.
  Windows: GetProcessMemoryInfo (Winapi.PsAPI).
  Linux:   VmRSS from /proc/self/status (already in kB).
  Returns -1 if the measurement is unavailable on this platform. }
function GetWorkingSetKB: Int64;
{$IFDEF MSWINDOWS}
var
  MC: PROCESS_MEMORY_COUNTERS;
begin
  if GetProcessMemoryInfo(GetCurrentProcess, @MC, SizeOf(MC)) then
    Result := MC.WorkingSetSize div 1024
  else
    Result := -1;
end;
{$ELSE}
var
  F:    Text;
  S:    string;
  ColP: Integer;
  Val:  string;
begin
  Result := -1;
  try
    Assign(F, '/proc/self/status');
    Reset(F);
    try
      while not EOF(F) do
      begin
        ReadLn(F, S);
        if Pos('VmRSS:', S) = 1 then
        begin
          ColP := Pos(':', S) + 1;
          Val  := Trim(Copy(S, ColP, MaxInt));
          if Pos(' ', Val) > 0 then
            Val := Copy(Val, 1, Pos(' ', Val) - 1);
          Result := StrToInt64Def(Val, -1);
          Break;
        end;
      end;
    finally
      Close(F);
    end;
  except end;
end;
{$ENDIF}

// Process-lifetime stream fixtures — created once in RegisterRoutes, freed after
// Listen returns.  Not allocated per request, so they never count as a per-request
// leak and are gone before the shutdown leak report runs.  Res.SendFile keeps a
// NON-owning reference (FCSContentStream) and the CrossSocket bridge sends it
// asynchronously (ACrossRes.Send(Stream) reads it after WriteBody returns), so
// the fixtures must outlive the request — freeing them only after Listen drains
// all in-flight sends is what makes that safe.
var
  GStreamSmall: TStringStream = nil;
  GStreamLarge: TStringStream = nil;

// ── Route registration ─────────────────────────────────────────────────────────

procedure RegisterRoutes;
begin
  // Build the stream-body fixtures once (Section H).
  GStreamSmall := TStringStream.Create(STREAM_SMALL_PAYLOAD, TEncoding.UTF8);
  GStreamLarge := TStringStream.Create(
                    BuildLargePayload(STREAM_LARGE_LEN), TEncoding.UTF8);

  // ── Health ────────────────────────────────────────────────────────────────────
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('text/plain').Send('pong');
    end
  );

  // ── Single-param routes ───────────────────────────────────────────────────────
  // Same param name (:id) across all HTTP methods.  The client tests that pool
  // recycling does not leak the value from request N into request N+1.

  THorse.Delete('/param/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"DELETE","id":"%s"}', [JE(Req.Params['id'])]));
    end
  );

  THorse.Put('/param/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"PUT","id":"%s"}', [JE(Req.Params['id'])]));
    end
  );

  THorse.Get('/param/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"GET","id":"%s"}', [JE(Req.Params['id'])]));
    end
  );

  THorse.Patch('/param/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"PATCH","id":"%s"}', [JE(Req.Params['id'])]));
    end
  );

  THorse.Post('/param/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"POST","id":"%s","body":"%s"}',
           [JE(Req.Params['id']), JE(Req.Body)]));
    end
  );

  // ── Two-param routes ──────────────────────────────────────────────────────────
  // Verifies that multiple named params are individually cleared on pool recycle.

  THorse.Delete('/multi/:a/:b',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"DELETE","a":"%s","b":"%s"}',
           [JE(Req.Params['a']), JE(Req.Params['b'])]));
    end
  );

  THorse.Put('/multi/:a/:b',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"PUT","a":"%s","b":"%s"}',
           [JE(Req.Params['a']), JE(Req.Params['b'])]));
    end
  );

  // ── Real-world URL pattern from the bug report ────────────────────────────────
  THorse.Delete('/product_category/uuid_product_category/:uuid',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"DELETE","uuid":"%s"}',
           [JE(Req.Params['uuid'])]));
    end
  );

  THorse.Put('/product_category/uuid_product_category/:uuid',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"method":"PUT","uuid":"%s"}',
           [JE(Req.Params['uuid'])]));
    end
  );

  // ── Memory diagnostics ────────────────────────────────────────────────────────
  //
  // GET /mem
  //   Returns the server process working-set in KB.  The client samples this
  //   before and after a 1 000-request stress run to compute growth per request.
  //   {"workingSetKB": <n>}   (n = -1 if measurement unavailable on this platform)
  //
  // GET /mem/pool
  //   Returns the THorseContextPool idle-context count and the compile-time
  //   pool constants.  Use to verify that contexts are being returned to the
  //   pool after every request (idleCount drop >= 1 per leaked context).
  //   {"idleCount": <n>, "warmupSize": 32, "maxSize": 512}

  THorse.Get('/mem',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"workingSetKB":%d}', [GetWorkingSetKB]));
    end
  );

  THorse.Get('/mem/pool',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"idleCount":%d,"warmupSize":%d,"maxSize":%d}',
           [THorseContextPool.IdleCount,
            POOL_WARMUP_SIZE,
            POOL_MAX_SIZE]));
    end
  );

  // ── Stream-body transfer (Section H) ──────────────────────────────────────────
  //
  // GET /stream
  //   Body served from a TStream via Res.SendFile.  Exercises the CrossSocket
  //   response bridge's stream path: TResponseBridge.WriteBody reads the shadow
  //   ContentStream and sends it via ACrossRes.Send(Stream).  The client asserts
  //   the body equals STREAM_SMALL_PAYLOAD.
  //
  // GET /stream/large
  //   Same path with a 64 KB body — guards against truncation / wrong
  //   Content-Length when a large stream is streamed out.

  THorse.Get('/stream',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      // Non-owning reference to the process-lifetime fixture; never freed here.
      Res.SendFile(GStreamSmall, 'stream-small.txt', 'text/plain; charset=utf-8');
    end
  );

  THorse.Get('/stream/large',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.SendFile(GStreamLarge, 'stream-large.bin', 'application/octet-stream');
    end
  );

  // ── multipart/form-data upload (Section I) ────────────────────────────────────
  //
  // POST /upload  (multipart/form-data)
  //   Reads two text fields and one file part from Req.ContentFields, which the
  //   provider's multipart parser populates during request setup:
  //     text field  → Req.ContentFields.Field(name).AsString
  //     file part   → Req.ContentFields.Field(name).AsStream  (AsString is '')
  //   Echoes them back as JSON so the client can verify each was parsed intact.

  THorse.Post('/upload',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LField1, LField2, LFileContent: string;
      LFileStream: TStream;
      LFileLen:    Int64;
      LBytes:      TBytes;
    begin
      LField1 := Req.ContentFields.Field('field1').AsString;
      LField2 := Req.ContentFields.Field('field2').AsString;

      LFileContent := '';
      LFileLen     := 0;
      LFileStream  := Req.ContentFields.Field('upload').AsStream;
      if Assigned(LFileStream) then
      begin
        LFileLen := LFileStream.Size;
        if LFileLen > 0 then
        begin
          LFileStream.Position := 0;
          SetLength(LBytes, LFileLen);
          LFileStream.ReadBuffer(LBytes[0], LFileLen);
          LFileContent := TEncoding.UTF8.GetString(LBytes);
        end;
      end;

      Res.ContentType('application/json; charset=utf-8')
         .Send(Format('{"field1":"%s","field2":"%s","fileLen":%d,"fileContent":"%s"}',
           [JE(LField1), JE(LField2), LFileLen, JE(LFileContent)]));
    end
  );

  // ── RFC 6265 cookies (Section K — PATCH-COOKIE-1) ─────────────────────────────
  // Sets TWO cookies with attributes via the new typed API.  Verifies the
  // response carries two distinct Set-Cookie lines (the header map could only
  // hold one before) with correct attribute syntax.
  THorse.Get('/cookies',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Cookie('sid', 'abc123').Path('/').HttpOnly(True).SameSite(ssLax);
      Res.Cookie('theme', 'dark').MaxAge(3600);
      Res.ContentType('text/plain').Send('cookies-set');
    end
  );

  // ── Wildcard catch-all + SendFile (Section J — verifies PATCH-SENDFILE-1) ─────
  //
  // GET '/*'  — Horse's catch-all: any path not matched by a registered route
  // falls through here (RouterTree '/*' fallback).  The handler serves a file
  // via SendFile, mirroring the user-reported pattern EXACTLY:
  //   open a stream → Res.SendFile(stream, ...) → FreeAndNil(stream) in finally.
  //
  // Before PATCH-SENDFILE-1 this was a use-after-free: SendFile kept a NON-owning
  // reference and CrossSocket's Send(TStream) reads the stream ASYNCHRONOUSLY on the
  // IO thread after the handler returns, so the FreeAndNil below destroyed it first
  // (AV/500).  PATCH-SENDFILE-1 makes SendFile COPY the source at call time and the
  // bridge drains it to bytes + Send(TBytes) (async-safe); the FreeAndNil is now
  // harmless and the file is delivered correctly.
  //
  // (Uses an in-handler TStringStream instead of a TFileStream so no file on disk
  // is needed; the ownership behaviour is identical.)
  THorse.Get('/*',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var
      LStream: TStringStream;
    begin
      try
        LStream := TStringStream.Create(WILDCARD_PAYLOAD);
        Res.SendFile(LStream, 'wildcard.bin', 'application/octet-stream').Status(200);
      finally
        try
          FreeAndNil(LStream);
        except on E: Exception do
        end;
      end;
    end
  );

end;

procedure FreeStreamFixtures;
begin
  FreeAndNil(GStreamSmall);
  FreeAndNil(GStreamLarge);
end;

// ── Ctrl+C handler (Windows only) ─────────────────────────────────────────────
//
// Without this, Ctrl+C calls ExitProcess directly.  THorseProviderCrossSocket.Stop
// is never called, so IOCP threads, the worker pool, and all context objects are
// never freed.  ReportMemoryLeaksOnShutdown then reports hundreds of false-positive
// leaks from objects that would have been cleaned up on a proper shutdown, making
// it impossible to spot real leaks.
//
// With this handler:
//   1. Stop() sets FRunning := False, stops the IOCP server (joins all IOCP
//      and worker threads), drains in-flight requests, then signals FStopEvent
//      — unblocking Listen's while-FRunning WaitFor loop.
//   2. The main thread exits Listen, reaches end., and the RTL runs unit
//      finalizations including FastMM's memory-leak report.
//   3. The leak report shows only allocations that were genuinely not freed.
//
// Returning True prevents the default handler from calling ExitProcess a second
// time.  CTRL_CLOSE_EVENT (window close) also routes here so the red X on the
// console window gives the same clean result.

{$IFDEF MSWINDOWS}
function ConsoleCtrlHandler(dwCtrlType: DWORD): BOOL; stdcall;
begin
  case dwCtrlType of
    CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT:
      begin
        THorseProviderCrossSocket.Stop;
        Result := True;
      end;
  else
    Result := False;
  end;
end;
{$ENDIF}

// ── Entry point ────────────────────────────────────────────────────────────────

begin
{$IF NOT DEFINED(FPC)}
{$WARN SYMBOL_PLATFORM OFF}
  // When running under the Delphi debugger, report leaked objects at exit so
  // developers can identify the source of a leak without installing FastMM.
  // Does nothing in non-interactive CI runs (DebugHook = 0 there).
  //ReportMemoryLeaksOnShutdown := DebugHook <> 0;
  ReportMemoryLeaksOnShutdown := TRUE;
{$WARN SYMBOL_PLATFORM ON}
{$ENDIF}
{$IFDEF MSWINDOWS}
  SetConsoleCtrlHandler(@ConsoleCtrlHandler, True);
{$ENDIF}
  try
    RegisterRoutes;
    Writeln(Format('[CSParamTest] Starting on http://127.0.0.1:%d', [TEST_PORT]));
    Writeln('[CSParamTest] Run HorseCSParamTestClient in a second terminal.');
    Writeln('[CSParamTest] Press Ctrl+C to stop cleanly (leak report will follow).');
    // Listen blocks the main thread (IsConsole=True) via FStopEvent.WaitFor(INFINITE)
    // until Stop() signals the event after joining all IOCP and worker threads.
    THorseProviderCrossSocket.Listen(TEST_PORT);
    Writeln('[CSParamTest] Server stopped.');
  except
    on E: Exception do
    begin
      Writeln('[CSParamTest] Fatal: ' + E.Message);
      ExitCode := 1;
    end;
  end;
  // Free the stream fixtures after Listen returns (Stop has drained all in-flight
  // requests and their async sends) so they never appear in the shutdown leak report.
  FreeStreamFixtures;
 Writeln('[MormotParamTest] CHECKPOINT: reached end. ReportMemoryLeaksOnShutdown=' +
    BoolToStr(ReportMemoryLeaksOnShutdown, True));
end.
