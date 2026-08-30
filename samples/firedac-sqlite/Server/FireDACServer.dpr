program FireDACServer;

// ============================================================================
//  FireDACServer — Horse + CrossSocket CRUD demo with SQLite
//
//  Demonstrates correct server-side patterns for receiving and sending
//  TFDMemTable binary streams over horse-provider-crosssocket.
//
//  ── Endpoints ────────────────────────────────────────────────────────────
//  GET  /items         → all rows as TFDMemTable sfBinary stream
//  GET  /items/:id     → single row as JSON  {id, name, value}
//  POST /items         → accepts TFDMemTable sfBinary, inserts rows
//  GET  /items/count   → plain-text row count (for health checks)
//
//  ── Key patterns encoded here ────────────────────────────────────────────
//  • Req.Body<TStream> is a NON-OWNING reference into CrossSocket's socket
//    buffer.  Do not free it; do not forward to a worker thread.
//    (See: CLAUDE.md "Known ownership trap")
//  • Req.Body<TStream>.Position is 0 on entry when using
//    horse-provider-crosssocket v1.0.18+ (FIX-REQ-BODY-POS-1).
//  • Stream passed to Res.Send<TStream>(S) transfers ownership to Horse.
//    Horse frees S after the async send; do NOT free it yourself.
//  • CrossSocket IOCP/epoll worker threads have no COM apartment.
//    FireDAC sfXML uses MSXML (COM) — call CoInitialize/CoUninitialize
//    inside any handler that uses sfXML.  sfBinary and sfJSON use pure
//    Delphi code and do not need COM.  This demo uses sfBinary only.
//  • TFDConnection is NOT thread-safe.  All database operations are
//    serialised here via GLock (TCriticalSection).  For production use
//    TFDManager to maintain a per-thread connection pool.
//
//  ── Port choice ──────────────────────────────────────────────────────────
//  Port 18080. The range 9000-9100 is avoided because NahimicService.exe
//  and several OEM audio-vendor services silently bind ports in that range
//  on laptops and return "301 → about:blank" for every request, which
//  looks identical to a broken Horse route.  Pick an uncommon private port.
//
//  ── Build ─────────────────────────────────────────────────────────────────
//  Delphi IDE → Open → FireDACServer.dpr → Project → Build
//  Requires: Horse >=3.3.0, horse-provider-crosssocket >=1.0.19 (boss install)
//
//  ── Run ──────────────────────────────────────────────────────────────────
//  ./FireDACServer.exe
//  Then run ./FireDACClient.exe from the Client/ folder.
// ============================================================================

{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_CROSSSOCKET}

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.JSON,
  Data.DB,
  FireDAC.Stan.Intf,
  FireDAC.Stan.Option,
  FireDAC.Stan.Param,
  FireDAC.Stan.Error,
  FireDAC.Phys,
  FireDAC.Phys.SQLite,
  FireDAC.Phys.SQLiteDef,
  FireDAC.Stan.ExprFuncs,
  FireDAC.DApt,
  FireDAC.Comp.Client,
  FireDAC.Comp.DataSet,
  FireDAC.Stan.StorageBin,     { sfBinary persistence — must appear in uses }
  Horse,
  Horse.Provider.CrossSocket;

const
  DEMO_PORT = 18080;
  DB_FILE   = 'server_items.db';

var
  GConn: TFDConnection;
  GLock: TCriticalSection;

// ─── Database setup ──────────────────────────────────────────────────────────

procedure SetupDB;
begin
  GConn := TFDConnection.Create(nil);
  GConn.DriverName := 'SQLite';
  GConn.Params.Add('Database=' + DB_FILE);
  GConn.Params.Add('LockingMode=Normal');
  GConn.Params.Add('JournalMode=WAL');  { WAL: concurrent reads + one writer }
  GConn.Connected := True;

  GConn.ExecSQL(
    'CREATE TABLE IF NOT EXISTS items (' +
    '  id    INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  name  TEXT    NOT NULL,' +
    '  value REAL    NOT NULL DEFAULT 0.0)');

  { Seed with server-side reference data }
  GConn.ExecSQL('DELETE FROM items');
  GConn.ExecSQL('INSERT INTO items (name, value) VALUES (''Server Apple'',   2.50)');
  GConn.ExecSQL('INSERT INTO items (name, value) VALUES (''Server Banana'',  1.25)');
  GConn.ExecSQL('INSERT INTO items (name, value) VALUES (''Server Cherry'',  4.00)');

  WriteLn('Database : ', DB_FILE, ' (3 rows seeded)');
end;

// ─── Helper: query → TFDMemTable ─────────────────────────────────────────────

function QueryToMemTable(const ASQL: string): TFDMemTable;
var
  LQ: TFDQuery;
begin
  Result := TFDMemTable.Create(nil);
  LQ     := TFDQuery.Create(nil);
  try
    GLock.Acquire;
    try
      LQ.Connection := GConn;
      LQ.SQL.Text   := ASQL;
      LQ.Open;
      Result.CopyDataSet(LQ, [coStructure, coRestart, coAppend]);
      Result.First;
    finally
      GLock.Release;
    end;
  finally
    LQ.Free;
  end;
end;

// ─── GET /items ──────────────────────────────────────────────────────────────
// Returns all items as a TFDMemTable sfBinary stream.
// Ownership of the stream transfers to Horse on Res.Send<TStream> — do NOT free it.

procedure RouteGetItems(Req: THorseRequest; Res: THorseResponse);
var
  LTable: TFDMemTable;
  LStream: TMemoryStream;
  LRowCount, LSize: Integer;
begin
  LTable  := nil;
  LStream := nil;
  try
    LTable  := QueryToMemTable('SELECT id, name, value FROM items ORDER BY id');
    LStream := TMemoryStream.Create;
    LTable.SaveToStream(LStream, TFDStorageFormat.sfBinary);
    LStream.Position := 0;
    LRowCount := LTable.RecordCount;
    LSize     := LStream.Size;
  except
    on E: Exception do
    begin
      FreeAndNil(LTable);
      FreeAndNil(LStream);
      WriteLn('[GET /items] Error: ', E.Message);
      Res.Send('Error: ' + E.Message).Status(500);
      Exit;
    end;
  end;
  FreeAndNil(LTable);  { LTable is done; LStream ownership goes to Horse below }

  WriteLn('[GET /items] ', LRowCount, ' row(s), ', LSize, ' bytes');
  Res.ContentType('application/octet-stream');
  Res.Send<TStream>(LStream);  { Horse frees LStream after async send }
end;

// ─── GET /items/:id ──────────────────────────────────────────────────────────
// Returns one item as JSON: {"id":1,"name":"Apple","value":2.5}

procedure RouteGetItem(Req: THorseRequest; Res: THorseResponse);
var
  LId: Integer;
  LQ:  TFDQuery;
  LObj: TJSONObject;
begin
  if not TryStrToInt(Req.Params['id'], LId) then
  begin
    Res.Send('Bad id — must be an integer').Status(400);
    Exit;
  end;

  LQ   := TFDQuery.Create(nil);
  LObj := nil;
  try
    GLock.Acquire;
    try
      LQ.Connection := GConn;
      LQ.SQL.Text   := 'SELECT id, name, value FROM items WHERE id = :id';
      LQ.ParamByName('id').AsInteger := LId;
      LQ.Open;
    finally
      GLock.Release;
    end;
    if LQ.EOF then
    begin
      Res.Send('Not found').Status(404);
      Exit;
    end;
    LObj := TJSONObject.Create;
    LObj.AddPair('id',    TJSONNumber.Create(LQ.FieldByName('id').AsInteger));
    LObj.AddPair('name',  LQ.FieldByName('name').AsString);
    LObj.AddPair('value', TJSONNumber.Create(LQ.FieldByName('value').AsFloat));
    WriteLn('[GET /items/', LId, '] found');
    Res.Send(LObj);  { Horse serialises TJSONObject and frees it }
  except
    on E: Exception do
    begin
      FreeAndNil(LObj);
      Res.Send('Error: ' + E.Message).Status(500);
    end;
  end;
  LQ.Free;
end;

// ─── GET /items/count ────────────────────────────────────────────────────────
// Returns plain-text row count. Useful as a health check.

procedure RouteGetCount(Req: THorseRequest; Res: THorseResponse);
var
  LQ: TFDQuery;
  LN: Integer;
begin
  LQ := TFDQuery.Create(nil);
  try
    GLock.Acquire;
    try
      LQ.Connection := GConn;
      LQ.SQL.Text   := 'SELECT COUNT(*) AS n FROM items';
      LQ.Open;
      LN := LQ.FieldByName('n').AsInteger;
    finally
      GLock.Release;
    end;
    Res.ContentType('text/plain');
    Res.Send(IntToStr(LN));
    WriteLn('[GET /items/count] ', LN);
  finally
    LQ.Free;
  end;
end;

// ─── POST /items ─────────────────────────────────────────────────────────────
// Accepts a TFDMemTable sfBinary body, inserts every row into the database.
//
// Client MUST:
//   1. Set Content-Type: application/octet-stream
//   2. Reset LStream.Position := 0 after SaveToStream and before POST.
//      Without the reset the stream position is at Size → 0 bytes are sent
//      → Body.Size = 0 → this handler returns 400.
//
// Server rules:
//   • Req.Body<TStream> position is already 0 on entry (v1.0.18+).
//   • NEVER call LBody.Free — non-owning reference into CrossSocket's buffer.

procedure RoutePostItems(Req: THorseRequest; Res: THorseResponse);
var
  LBody:  TStream;
  LTable: TFDMemTable;
  LQ:     TFDQuery;
  LN:     Integer;
begin
  LBody := Req.Body<TStream>;

  { nil  → wrong or absent Content-Type header
    Size = 0 → client sent empty body — almost certainly a missing
               LStream.Position := 0 on the client side after SaveToStream }
  if not Assigned(LBody) or (LBody.Size = 0) then
  begin
    WriteLn('[POST /items] Rejected — empty body. ' +
      'Check: Content-Type: application/octet-stream ' +
      'and LStream.Position := 0 before POST.');
    Res.Send(
      'Empty body.' + #10 +
      'Required: Content-Type: application/octet-stream' + #10 +
      'Common cause on client: LStream.Position not reset to 0 after SaveToStream.'
    ).Status(400);
    Exit;
  end;

  { LBody.Position is already 0 — no Seek needed (v1.0.18+ guarantee).
    Do NOT free LBody here or anywhere else in this handler. }

  LTable := TFDMemTable.Create(nil);
  LQ     := TFDQuery.Create(nil);
  try
    try
      LTable.LoadFromStream(LBody, TFDStorageFormat.sfBinary);
      LN := LTable.RecordCount;

      GLock.Acquire;
      try
        LQ.Connection := GConn;
        LQ.SQL.Text   :=
          'INSERT INTO items (name, value) VALUES (:name, :value)';
        LTable.First;
        while not LTable.EOF do
        begin
          LQ.ParamByName('name').AsString := LTable.FieldByName('name').AsString;
          LQ.ParamByName('value').AsFloat := LTable.FieldByName('value').AsFloat;
          LQ.ExecSQL;
          LTable.Next;
        end;
      finally
        GLock.Release;
      end;

      WriteLn('[POST /items] Inserted ', LN, ' row(s)');
      Res.Send('Inserted ' + IntToStr(LN) + ' row(s)').Status(200);
    except
      on E: Exception do
      begin
        WriteLn('[POST /items] Error: ', E.Message);
        Res.Send('Error: ' + E.Message).Status(500);
      end;
    end;
  finally
    LQ.Free;
    LTable.Free;
  end;
end;

// ─── Main ─────────────────────────────────────────────────────────────────────

begin
  try
    GLock := TCriticalSection.Create;
    try
      SetupDB;

      WriteLn('FireDAC SQLite Demo — Horse + CrossSocket');
      WriteLn('Port      : ', DEMO_PORT);
      WriteLn;
      WriteLn('Endpoints:');
      WriteLn('  GET  http://127.0.0.1:', DEMO_PORT, '/items         → TFDMemTable sfBinary');
      WriteLn('  GET  http://127.0.0.1:', DEMO_PORT, '/items/:id     → JSON');
      WriteLn('  GET  http://127.0.0.1:', DEMO_PORT, '/items/count   → plain-text count');
      WriteLn('  POST http://127.0.0.1:', DEMO_PORT, '/items         ← TFDMemTable sfBinary');
      WriteLn;
      WriteLn('Run FireDACClient.exe to exercise all endpoints.');
      WriteLn('Ctrl-C to stop.');
      WriteLn;

      { Note: register /items/count BEFORE /items/:id, otherwise ":id" captures "count". }
      THorse.Get('/items/count', RouteGetCount);
      THorse.Get('/items/:id',   RouteGetItem);
      THorse.Get('/items',       RouteGetItems);
      THorse.Post('/items',      RoutePostItems);

      THorse.Listen(DEMO_PORT);
    finally
      GLock.Free;
      GConn.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, '[FATAL] ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
