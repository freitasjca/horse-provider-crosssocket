program HorseCSParamTestServer;

{
  Horse + CrossSocket  —  Param isolation + memory-leak + stream + multipart
  test server  (Lazarus / FPC · Console shape)
  ===========================================================================
  FPC port of HorseCSParamTestServer.dpr.  Same routes and port (9100) as the
  Delphi version, so the FPC client (HorseCSParamTestClient.lpr) — or the
  Delphi client — exercises an identical surface.

  Conditional defines (Project → Project Options → Compiler Options →
  Custom Options):
    -dHORSE_PROVIDER_CROSSSOCKET      (or legacy -dHORSE_CROSSSOCKET)

  Route handlers are plain unit-scope procedures (NOT anonymous procedures) so
  the project compiles on stock FPC without HORSE_FPC_FUNCTIONREFERENCES — the
  same pattern as Horse.BenchRoutes.pas.  Register with no '@' so FPC's
  {$MODE DELPHI} promotes the procedure to THorseCallbackRequestResponse.

  Leak detection on FPC is done with heaptrc (compile with -gh), not with
  ReportMemoryLeaksOnShutdown (which is Delphi-only).

  Run sequence:
    1. lazbuild HorseCSParamTestServer.lpi   (or compile in the IDE)
    2. ./HorseCSParamTestServer
    3. run HorseCSParamTestClient in another terminal
    4. Ctrl-C / SIGTERM for a clean shutdown (drains, then frees fixtures)
}

{$MODE DELPHI}{$H+}
{$APPTYPE CONSOLE}

{$IFNDEF HORSE_PROVIDER_CROSSSOCKET}
  {$IFNDEF HORSE_CROSSSOCKET}
    {$MESSAGE FATAL 'Set -dHORSE_PROVIDER_CROSSSOCKET (or -dHORSE_CROSSSOCKET) in Project Options -> Custom Options'}
  {$ENDIF}
{$ENDIF}

uses
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  SysUtils,
  Classes,
  Horse,
  Horse.Commons,
  Horse.Core.Param,
  Horse.Core.Param.Field,
  Horse.Provider.CrossSocket,
  Horse.Provider.CrossSocket.Pool;

const
  TEST_PORT = 9100;

  // Stream-body fixtures (Section H).  Must match HorseCSParamTestClient.
  STREAM_SMALL_PAYLOAD =
    'stream-body-OK-0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  STREAM_LARGE_LEN = 65536;

var
  GStreamSmall: TStringStream = nil;
  GStreamLarge: TStringStream = nil;

// ── Helpers ────────────────────────────────────────────────────────────────────

{ Minimal JSON string escaping for inline Format() calls. }
function JE(const S: string): string;
begin
  Result := StringReplace(S,      '\', '\\', [rfReplaceAll]);
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

{ Current process working-set / RSS in KB.
  UNIX: VmRSS from /proc/self/status (already in kB).
  Other: -1 (measurement not implemented here). }
function GetWorkingSetKB: Int64;
{$IFDEF UNIX}
var
  F:    Text;
  S:    string;
  ColP: Integer;
  Val:  string;
begin
  Result := -1;
  try
    AssignFile(F, '/proc/self/status');
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
      CloseFile(F);
    end;
  except
  end;
end;
{$ELSE}
begin
  Result := -1;
end;
{$ENDIF}

// ── Route handlers (plain unit-scope procedures) ────────────────────────────────

procedure RoutePing(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('text/plain').Send('pong');
end;

procedure RouteParamDelete(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"method":"DELETE","id":"%s"}', [JE(Req.Params['id'])]));
end;

procedure RouteParamPut(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"method":"PUT","id":"%s"}', [JE(Req.Params['id'])]));
end;

procedure RouteParamGet(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"method":"GET","id":"%s"}', [JE(Req.Params['id'])]));
end;

procedure RouteParamPatch(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"method":"PATCH","id":"%s"}', [JE(Req.Params['id'])]));
end;

procedure RouteParamPost(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"method":"POST","id":"%s","body":"%s"}',
       [JE(Req.Params['id']), JE(Req.Body)]));
end;

procedure RouteMultiDelete(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"method":"DELETE","a":"%s","b":"%s"}',
       [JE(Req.Params['a']), JE(Req.Params['b'])]));
end;

procedure RouteMultiPut(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"method":"PUT","a":"%s","b":"%s"}',
       [JE(Req.Params['a']), JE(Req.Params['b'])]));
end;

procedure RouteProdCatDelete(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"method":"DELETE","uuid":"%s"}', [JE(Req.Params['uuid'])]));
end;

procedure RouteProdCatPut(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"method":"PUT","uuid":"%s"}', [JE(Req.Params['uuid'])]));
end;

procedure RouteMem(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"workingSetKB":%d}', [GetWorkingSetKB]));
end;

procedure RouteMemPool(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('application/json; charset=utf-8')
     .Send(Format('{"idleCount":%d,"warmupSize":%d,"maxSize":%d}',
       [THorseContextPool.IdleCount, POOL_WARMUP_SIZE, POOL_MAX_SIZE]));
end;

procedure RouteStream(Req: THorseRequest; Res: THorseResponse);
begin
  // Non-owning reference to the process-lifetime fixture; never freed here.
  Res.SendFile(GStreamSmall, 'stream-small.txt', 'text/plain; charset=utf-8');
end;

procedure RouteStreamLarge(Req: THorseRequest; Res: THorseResponse);
begin
  Res.SendFile(GStreamLarge, 'stream-large.bin', 'application/octet-stream');
end;

procedure RouteUpload(Req: THorseRequest; Res: THorseResponse);
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
end;

// ── Registration ────────────────────────────────────────────────────────────────

procedure RegisterRoutes;
begin
  // Build the stream-body fixtures once (Section H).
  GStreamSmall := TStringStream.Create(STREAM_SMALL_PAYLOAD);
  GStreamLarge := TStringStream.Create(BuildLargePayload(STREAM_LARGE_LEN));

  THorse.Get('/ping', RoutePing);

  THorse.Delete('/param/:id', RouteParamDelete);
  THorse.Put('/param/:id',    RouteParamPut);
  THorse.Get('/param/:id',    RouteParamGet);
  THorse.Patch('/param/:id',  RouteParamPatch);
  THorse.Post('/param/:id',   RouteParamPost);

  THorse.Delete('/multi/:a/:b', RouteMultiDelete);
  THorse.Put('/multi/:a/:b',    RouteMultiPut);

  THorse.Delete('/product_category/uuid_product_category/:uuid', RouteProdCatDelete);
  THorse.Put('/product_category/uuid_product_category/:uuid',    RouteProdCatPut);

  THorse.Get('/mem',      RouteMem);
  THorse.Get('/mem/pool', RouteMemPool);

  THorse.Get('/stream',       RouteStream);
  THorse.Get('/stream/large', RouteStreamLarge);

  THorse.Post('/upload', RouteUpload);
end;

procedure FreeStreamFixtures;
begin
  FreeAndNil(GStreamSmall);
  FreeAndNil(GStreamLarge);
end;

{$IFDEF UNIX}
procedure HandleStopSignal(ASignal: cint); cdecl;
begin
  THorse.StopListen;
end;
{$ENDIF}

begin
  {$IFDEF UNIX}
  fpSignal(SIGTERM, @HandleStopSignal);
  fpSignal(SIGINT,  @HandleStopSignal);
  {$ENDIF}

  RegisterRoutes;

  WriteLn(Format('[CSParamTest · Lazarus/Console] Listening on http://127.0.0.1:%d',
    [TEST_PORT]));
  WriteLn('[CSParamTest] Run HorseCSParamTestClient in a second terminal.');
  WriteLn('[CSParamTest] Press Ctrl-C / SIGTERM to stop cleanly.');

  THorse.Listen(TEST_PORT);

  // Listen has returned (StopListen drained all in-flight requests + async
  // sends), so the stream fixtures are safe to free.
  FreeStreamFixtures;
  WriteLn('[CSParamTest] Server stopped.');
end.
