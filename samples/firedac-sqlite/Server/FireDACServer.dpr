program FireDACServer;

// ============================================================================
//  FireDACServer — Horse + CrossSocket CRUD demo with SQLite
//
//  Demonstrates correct server-side patterns for receiving and sending
//  TFDMemTable binary streams over horse-provider-crosssocket.
//
//  ── Endpoints ────────────────────────────────────────────────────────────
//  GET    /items         → all rows as TFDMemTable sfBinary (Res.SendFile)
//  GET    /items/export  → same bytes as an attachment      (Res.Download)
//  GET    /items/:id     → single row as JSON  {id, name, value}
//  GET    /items/count   → plain-text row count (for health checks)
//  POST   /items         ← TFDMemTable sfBinary, inserts rows
//  PUT    /items         ← TFDMemTable sfBinary, updates rows by id
//  DELETE /items         ← TFDMemTable sfBinary, deletes rows by id
//  DELETE /items/:id     → 204 No Content (conventional single-resource form)
//
//  ── The complete TStream surface on this provider ────────────────────────
//
//  RECEIVING — one API, used by POST, PUT and DELETE here:
//    Req.Body<TStream>   non-owning reference into CrossSocket's socket buffer.
//                        Position is 0 on entry (v1.0.18+). NEVER free it, and
//                        never hand it to a worker thread — it dies with the
//                        request. Copy first if you need it to outlive the
//                        handler.
//    Req.Body (string)   a *text* accessor. The provider decodes the body once
//                        per request; for a genuinely binary payload it yields
//                        '' rather than raising (FIX-BINBODY-1, v1.0.21).
//
//  SENDING — three that work, one that does not:
//    Res.SendFile(S,N,C) COPIES S into a response-owned buffer, sends inline.
//                        Caller keeps ownership and MUST free S afterwards.
//    Res.Download(S,N,C) identical, but Content-Disposition: attachment.
//                        Same ownership rule — caller frees.
//    Res.Render(S,N)     identical, inline, content type inferred from N.
//    Res.Send<TStream>   DOES NOT WORK on any released Horse. It stores the
//                        stream in FContent, which no provider bridge reads, so
//                        the client receives Content-Length: 0 and no error.
//                        The fix (DoSendStream) is merged to HashLoad/horse
//                        master as PR #540 but is in no released tag, and Boss
//                        installs by tag. Use SendFile/Download until a release
//                        ships it. Note the ownership contracts are opposite:
//                        Send<TStream> takes ownership, SendFile does not.
//
//  ── Key patterns encoded here ────────────────────────────────────────────
//  • Req.Body<TStream> is a NON-OWNING reference into CrossSocket's socket
//    buffer.  Do not free it; do not forward to a worker thread.
//    (See: CLAUDE.md "Known ownership trap")
//  • Req.Body<TStream>.Position is 0 on entry when using
//    horse-provider-crosssocket v1.0.18+ (FIX-REQ-BODY-POS-1).
//  • Use Res.SendFile(S, '', ContentType) to send binary streams.  SendFile
//    copies S into an owned internal buffer and sets Content-Type.  The caller
//    retains ownership of S and MUST free it after SendFile returns.
//    Res.Send<TStream> is not used here: Horse <=3.3.0 (what Boss installs)
//    stores it in FContent, invisible to the CrossSocket bridge → empty body.
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
//  Requires: Horse >=3.3.0, horse-provider-crosssocket >=1.0.21 (boss install)
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
  FireDAC.Stan.Def,
  FireDAC.Stan.Async,
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
// SendFile copies LStream into an owned buffer; caller must FreeAndNil(LStream) after.

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
  FreeAndNil(LTable);

  WriteLn('[GET /items] ', LRowCount, ' row(s), ', LSize, ' bytes');
  { SendFile copies LStream into an owned FCSContentStream and sets Content-Type.
    The caller retains ownership of LStream and MUST free it — unlike Send<TStream>
    which transfers ownership but requires Horse > 3.3.0 (DoSendStream). }
  Res.SendFile(LStream, '', 'application/octet-stream');
  FreeAndNil(LStream);
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
    { Send<T> in Horse <=3.3.0 stores in FContent (not visible to the bridge).
      Serialize here so Res.Send(string) sets FCSBody — the bridge always sees it. }
    Res.ContentType('application/json');
    Res.Send(LObj.ToJSON);
    FreeAndNil(LObj);
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

// ─── PUT /items ──────────────────────────────────────────────────────────────
// Accepts a TFDMemTable sfBinary body and UPDATEs existing rows by id.
//
// Same request-stream contract as POST — Req.Body<TStream> is a non-owning
// reference into CrossSocket's socket buffer, already at position 0.
//
// The difference worth studying is the id column: POST ignores it (the database
// assigns one), PUT requires it. A row whose id is absent from the table is
// reported in "missing" rather than silently inserted — a PUT that quietly
// creates rows is indistinguishable from a POST with a typo.

procedure RoutePutItems(Req: THorseRequest; Res: THorseResponse);
var
  LBody:    TStream;
  LTable:   TFDMemTable;
  LQ:       TFDQuery;
  LUpdated: Integer;
  LMissing: Integer;
  LId:      Integer;
begin
  LBody := Req.Body<TStream>;
  if not Assigned(LBody) or (LBody.Size = 0) then
  begin
    WriteLn('[PUT /items] Rejected — empty body.');
    Res.Send('Empty body. Send a TFDMemTable sfBinary stream with an id column.')
       .Status(400);
    Exit;
  end;

  LUpdated := 0;
  LMissing := 0;
  LTable   := TFDMemTable.Create(nil);
  LQ       := TFDQuery.Create(nil);
  try
    try
      LTable.LoadFromStream(LBody, TFDStorageFormat.sfBinary);

      { The client must include id — without it there is nothing to match on. }
      if LTable.FindField('id') = nil then
      begin
        WriteLn('[PUT /items] Rejected — stream has no id column.');
        Res.Send('Stream has no "id" column — PUT updates by id.').Status(400);
        Exit;
      end;

      GLock.Acquire;
      try
        LQ.Connection := GConn;
        LQ.SQL.Text   :=
          'UPDATE items SET name = :name, value = :value WHERE id = :id';
        LTable.First;
        while not LTable.EOF do
        begin
          LId := LTable.FieldByName('id').AsInteger;
          LQ.ParamByName('id').AsInteger    := LId;
          LQ.ParamByName('name').AsString   := LTable.FieldByName('name').AsString;
          LQ.ParamByName('value').AsFloat   := LTable.FieldByName('value').AsFloat;
          LQ.ExecSQL;
          { RowsAffected is 0 when no row carries that id. }
          if LQ.RowsAffected > 0 then
            Inc(LUpdated)
          else
            Inc(LMissing);
          LTable.Next;
        end;
      finally
        GLock.Release;
      end;

      WriteLn('[PUT /items] Updated ', LUpdated, ', missing ', LMissing);
      Res.ContentType('application/json')
         .Send(Format('{"updated":%d,"missing":%d}', [LUpdated, LMissing]));
    except
      on E: Exception do
      begin
        WriteLn('[PUT /items] Error: ', E.Message);
        Res.Send('Error: ' + E.Message).Status(500);
      end;
    end;
  finally
    LQ.Free;
    LTable.Free;
  end;
end;

// ─── DELETE /items ───────────────────────────────────────────────────────────
// Accepts a TFDMemTable sfBinary body listing the ids to delete.
//
// A request body on DELETE is legal (RFC 9110 §9.3.5) but has no defined
// semantics, so intermediaries may drop it — this route exists to show that the
// TStream request path is identical on DELETE, not as a recommendation. For a
// public API prefer DELETE /items/:id, registered below.

procedure RouteDeleteItems(Req: THorseRequest; Res: THorseResponse);
var
  LBody:    TStream;
  LTable:   TFDMemTable;
  LQ:       TFDQuery;
  LDeleted: Integer;
  LMissing: Integer;
begin
  LBody := Req.Body<TStream>;
  if not Assigned(LBody) or (LBody.Size = 0) then
  begin
    WriteLn('[DELETE /items] Rejected — empty body.');
    Res.Send('Empty body. Send a TFDMemTable sfBinary stream with an id column.')
       .Status(400);
    Exit;
  end;

  LDeleted := 0;
  LMissing := 0;
  LTable   := TFDMemTable.Create(nil);
  LQ       := TFDQuery.Create(nil);
  try
    try
      LTable.LoadFromStream(LBody, TFDStorageFormat.sfBinary);
      if LTable.FindField('id') = nil then
      begin
        Res.Send('Stream has no "id" column.').Status(400);
        Exit;
      end;

      GLock.Acquire;
      try
        LQ.Connection := GConn;
        LQ.SQL.Text   := 'DELETE FROM items WHERE id = :id';
        LTable.First;
        while not LTable.EOF do
        begin
          LQ.ParamByName('id').AsInteger := LTable.FieldByName('id').AsInteger;
          LQ.ExecSQL;
          if LQ.RowsAffected > 0 then Inc(LDeleted) else Inc(LMissing);
          LTable.Next;
        end;
      finally
        GLock.Release;
      end;

      WriteLn('[DELETE /items] Deleted ', LDeleted, ', missing ', LMissing);
      Res.ContentType('application/json')
         .Send(Format('{"deleted":%d,"missing":%d}', [LDeleted, LMissing]));
    except
      on E: Exception do
      begin
        WriteLn('[DELETE /items] Error: ', E.Message);
        Res.Send('Error: ' + E.Message).Status(500);
      end;
    end;
  finally
    LQ.Free;
    LTable.Free;
  end;
end;

// ─── DELETE /items/:id ───────────────────────────────────────────────────────
// The conventional single-resource delete — no body, no stream.
// Included so the demo shows the idiomatic form beside the stream-bodied one.

procedure RouteDeleteItem(Req: THorseRequest; Res: THorseResponse);
var
  LQ: TFDQuery;
  LId: Integer;
begin
  if not TryStrToInt(Req.Params['id'], LId) then
  begin
    Res.Send('Bad id — must be an integer').Status(400);
    Exit;
  end;

  LQ := TFDQuery.Create(nil);
  try
    try
      GLock.Acquire;
      try
        LQ.Connection := GConn;
        LQ.SQL.Text   := 'DELETE FROM items WHERE id = :id';
        LQ.ParamByName('id').AsInteger := LId;
        LQ.ExecSQL;
      finally
        GLock.Release;
      end;

      if LQ.RowsAffected = 0 then
      begin
        WriteLn('[DELETE /items/', LId, '] not found');
        Res.Send('Not found').Status(404);
      end
      else
      begin
        WriteLn('[DELETE /items/', LId, '] deleted');
        Res.Status(204);   { 204 No Content — nothing to send }
      end;
    except
      on E: Exception do
      begin
        WriteLn('[DELETE /items/', LId, '] Error: ', E.Message);
        Res.Send('Error: ' + E.Message).Status(500);
      end;
    end;
  finally
    LQ.Free;
  end;
end;

// ─── GET /items/export ───────────────────────────────────────────────────────
// Same bytes as GET /items, sent with Res.Download instead of Res.SendFile.
//
// The two differ only in Content-Disposition — Download says `attachment`
// (browsers save it), SendFile says `inline`. Ownership is identical: both COPY
// the source into a response-owned buffer at call time, so the caller still has
// to free its own stream. That is the opposite of Res.Send<TStream>, which
// takes ownership — and which does not work at all on released Horse; see the
// header note.

procedure RouteExportItems(Req: THorseRequest; Res: THorseResponse);
var
  LTable:  TFDMemTable;
  LStream: TMemoryStream;
begin
  LTable  := nil;
  LStream := nil;
  try
    LTable  := QueryToMemTable('SELECT id, name, value FROM items ORDER BY id');
    LStream := TMemoryStream.Create;
    LTable.SaveToStream(LStream, TFDStorageFormat.sfBinary);
    LStream.Position := 0;
    WriteLn('[GET /items/export] ', LTable.RecordCount, ' row(s), ',
      LStream.Size, ' bytes (attachment)');
    Res.Download(LStream, 'items.fdbin', 'application/octet-stream');
  except
    on E: Exception do
    begin
      WriteLn('[GET /items/export] Error: ', E.Message);
      Res.Send('Error: ' + E.Message).Status(500);
    end;
  end;
  FreeAndNil(LTable);
  FreeAndNil(LStream);   { Download copied it — freeing here is required }
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
      WriteLn('  GET    /items          → sfBinary via Res.SendFile   (inline)');
      WriteLn('  GET    /items/export   → sfBinary via Res.Download   (attachment)');
      WriteLn('  GET    /items/:id      → JSON');
      WriteLn('  GET    /items/count    → plain-text count');
      WriteLn('  POST   /items          ← sfBinary via Req.Body<TStream>  (insert)');
      WriteLn('  PUT    /items          ← sfBinary via Req.Body<TStream>  (update by id)');
      WriteLn('  DELETE /items          ← sfBinary via Req.Body<TStream>  (delete by id)');
      WriteLn('  DELETE /items/:id      → 204, no body');
      WriteLn('  (base http://127.0.0.1:', DEMO_PORT, ')');
      WriteLn;
      WriteLn('Run FireDACClient.exe to exercise all endpoints.');
      WriteLn('Ctrl-C to stop.');
      WriteLn;

      { Note: register /items/count BEFORE /items/:id, otherwise ":id" captures "count". }
      THorse.Get('/items/count',   RouteGetCount);
      THorse.Get('/items/export',  RouteExportItems);
      THorse.Get('/items/:id',     RouteGetItem);
      THorse.Get('/items',         RouteGetItems);
      THorse.Post('/items',        RoutePostItems);
      THorse.Put('/items',         RoutePutItems);
      THorse.Delete('/items/:id',  RouteDeleteItem);
      THorse.Delete('/items',      RouteDeleteItems);

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
