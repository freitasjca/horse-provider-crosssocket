program FireDACClient;

// ============================================================================
//  FireDACClient — FireDAC SQLite ↔ Horse + CrossSocket demo client
//
//  Demonstrates correct client-side patterns for sending and receiving
//  TFDMemTable binary streams to/from a Horse + CrossSocket server.
//
//  ── Why THTTPClient, not RestRequest4D ───────────────────────────────────
//  FireDAC's sfBinary format writes raw binary bytes including NUL characters
//  and arbitrary byte values.  RestRequest4D's IResponse.Content is a Delphi
//  UnicodeString: any byte sequence that is not valid UTF-8 (or the detected
//  charset) will be replaced or corrupted during the string conversion.
//
//  System.Net.HttpClient.THTTPClient.Get/Post work directly with TStream
//  and TBytes — no character-set conversion involved — and are the safe
//  choice for raw binary payloads.  For JSON-based REST APIs, RestRequest4D
//  is the natural and recommended choice.
//
//  ── The #1 root cause of 500 on POST ─────────────────────────────────────
//  TFDMemTable.SaveToStream leaves the stream position at Size (end-of-stream).
//  POSTing that stream without resetting Position := 0 sends zero bytes.
//  The server receives an empty body, fires a 400 (or 500 if unguarded),
//  and logs "empty body".
//
//  The fix is one line, placed immediately after SaveToStream:
//      LStream.Position := 0;   ← REQUIRED before every POST
//
//  ── Build ────────────────────────────────────────────────────────────────
//  Delphi IDE → Open → FireDACClient.dpr → Project → Build
//  No Boss dependencies — uses only RTL (THTTPClient) + FireDAC.
//
//  ── What this exercises ──────────────────────────────────────────────────
//  POST   /items         insert via sfBinary stream body
//  GET    /items         fetch via Res.SendFile   (Content-Disposition: inline)
//  PUT    /items         update by id via sfBinary stream body
//  GET    /items/export  fetch via Res.Download   (…: attachment) — the only
//                        observable difference from GET /items
//  DELETE /items         delete by id list, sfBinary stream body. Built with
//                        GetRequest + Execute because THTTPClient offers no
//                        Delete overload that takes a source stream.
//  DELETE /items/:id     conventional single-resource form — 204, no body
//
//  Step 2 matters for every step after it: the GET sync inserts the server's
//  id column EXPLICITLY, so local ids equal server ids and the later PUT and
//  DELETE can match rows.
//
//  Get that wrong — insert only (name, value) and let AUTOINCREMENT assign
//  ids — and nothing appears broken: every request still returns 200, the
//  local table still looks right, and the only symptom is that the server
//  reports "missing" for every row while the client shows fresh ids climbing
//  on each sync. It is worth reproducing once, because a synchronisation bug
//  that fails this quietly is easy to ship.
//
//  ── Run ──────────────────────────────────────────────────────────────────
//  1. Start FireDACServer.exe first.
//  2. Run this program.  It walks every endpoint and prints a summary.
// ============================================================================

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.Net.HttpClient,
  System.Net.URLClient,
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
  FireDAC.Stan.StorageBin;   { sfBinary persistence — must appear in uses }

const
  SERVER_URL = 'http://127.0.0.1:18080';
  DB_FILE    = 'client_items.db';

var
  GConn: TFDConnection;

// ─── Separator helpers ────────────────────────────────────────────────────────

procedure Banner(const ATitle: string);
begin
  WriteLn;
  WriteLn('══════════════════════════════════════════════════');
  WriteLn('  ', ATitle);
  WriteLn('══════════════════════════════════════════════════');
end;

procedure Step(const AMsg: string);
begin
  WriteLn('  → ', AMsg);
end;

// ─── Database setup ───────────────────────────────────────────────────────────

procedure SetupDB;
begin
  GConn := TFDConnection.Create(nil);
  GConn.DriverName := 'SQLite';
  GConn.Params.Add('Database=' + DB_FILE);
  GConn.Connected := True;

  GConn.ExecSQL(
    'CREATE TABLE IF NOT EXISTS items (' +
    '  id    INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  name  TEXT    NOT NULL,' +
    '  value REAL    NOT NULL DEFAULT 0.0)');

  { Seed the client DB with data the server does NOT have initially }
  GConn.ExecSQL('DELETE FROM items');
  GConn.ExecSQL('INSERT INTO items (name, value) VALUES (''Client Apple'',   1.50)');
  GConn.ExecSQL('INSERT INTO items (name, value) VALUES (''Client Banana'',  0.75)');
  GConn.ExecSQL('INSERT INTO items (name, value) VALUES (''Client Cherry'',  3.00)');
  GConn.ExecSQL('INSERT INTO items (name, value) VALUES (''Client Durian'', 12.00)');

  WriteLn('Client DB : ', DB_FILE, ' (4 rows seeded)');
end;

// ─── Show local DB ────────────────────────────────────────────────────────────

procedure ShowLocalDB(const ALabel: string);
var
  LQ: TFDQuery;
begin
  WriteLn;
  WriteLn('  Local DB (', ALabel, '):');
  LQ := TFDQuery.Create(nil);
  try
    LQ.Connection := GConn;
    LQ.SQL.Text   := 'SELECT id, name, value FROM items ORDER BY id';
    LQ.Open;
    if LQ.EOF then
      WriteLn('    (empty)')
    else
      while not LQ.EOF do
      begin
        WriteLn(Format('    id=%-3d  name=%-20s  value=%.2f',
          [LQ.FieldByName('id').AsInteger,
           LQ.FieldByName('name').AsString,
           LQ.FieldByName('value').AsFloat]));
        LQ.Next;
      end;
  finally
    LQ.Free;
  end;
end;

// ─── POST /items ──────────────────────────────────────────────────────────────
// Loads items from the local DB, serialises them as TFDMemTable sfBinary,
// and POSTs the stream to the server.
//
// THE CRITICAL FIX:
//   After SaveToStream, Position = Size (end of stream).
//   Without "LStream.Position := 0", THTTPClient sends 0 bytes.
//   The server receives an empty body and returns 400 (or 500 if unguarded).

procedure PostItemsToServer;
var
  LQ:      TFDQuery;
  LTable:  TFDMemTable;
  LStream: TMemoryStream;
  LClient: THTTPClient;
  LResp:   IHTTPResponse;
  LN:      Integer;
begin
  Banner('POST /items  — send local items to server');

  LQ      := TFDQuery.Create(nil);
  LTable  := TFDMemTable.Create(nil);
  LStream := TMemoryStream.Create;
  LClient := THTTPClient.Create;
  try
    { Load local rows into a memory table }
    LQ.Connection := GConn;
    LQ.SQL.Text   := 'SELECT name, value FROM items';
    LQ.Open;
    LTable.CopyDataSet(LQ, [coStructure, coRestart, coAppend]);
    LTable.First;
    LN := LTable.RecordCount;
    Step(Format('%d local row(s) loaded', [LN]));

    { Serialise to binary stream }
    LTable.SaveToStream(LStream, TFDStorageFormat.sfBinary);

    { ┌─────────────────────────────────────────────────────────────────────┐
      │  CRITICAL — reset stream position to 0 before every POST.          │
      │                                                                     │
      │  SaveToStream leaves Position = Size.  Posting without this line   │
      │  sends 0 bytes, the server receives an empty body, and returns 400. │
      └─────────────────────────────────────────────────────────────────────┘ }
    LStream.Position := 0;

    Step(Format('Serialised: %d bytes  (Position reset to 0)', [LStream.Size]));

    { POST the stream with the required Content-Type }
    LResp := LClient.Post(
      SERVER_URL + '/items',
      LStream,
      nil,   { response stream — nil: read via LResp.ContentAsString }
      [TNameValuePair.Create('Content-Type', 'application/octet-stream')]
    );

    if LResp.StatusCode = 200 then
      Step('Server replied: ' + IntToStr(LResp.StatusCode) +
           ' — ' + LResp.ContentAsString)
    else
    begin
      Step('Server replied: ' + IntToStr(LResp.StatusCode) +
           ' — ' + LResp.ContentAsString);
      WriteLn;
      WriteLn('  *** POST failed.  Check:');
      WriteLn('  ***   1. Content-Type: application/octet-stream is set above.');
      WriteLn('  ***   2. LStream.Position := 0 is executed before Post().');
      WriteLn('  ***   3. Server is running on ', SERVER_URL, '.');
    end;
  finally
    LClient.Free;
    LStream.Free;
    LQ.Free;
    LTable.Free;
  end;
end;

// ─── GET /items ───────────────────────────────────────────────────────────────
// Fetches TFDMemTable sfBinary from the server and syncs it into the local DB.
// The response body arrives as a TStream; its position is already 0 (THTTPClient
// writes into our stream starting at 0 — no manual reset needed here).

procedure GetItemsFromServer;
var
  LClient: THTTPClient;
  LStream: TMemoryStream;
  LResp:   IHTTPResponse;
  LTable:  TFDMemTable;
  LQ:      TFDQuery;
  LN:      Integer;
begin
  Banner('GET /items  — fetch server items into local DB');

  LClient := THTTPClient.Create;
  LStream := TMemoryStream.Create;
  LTable  := TFDMemTable.Create(nil);
  LQ      := TFDQuery.Create(nil);
  try
    { THTTPClient.Get with a response stream fills LStream starting at offset 0. }
    LResp := LClient.Get(SERVER_URL + '/items', LStream);

    Step(Format('HTTP %d  —  %d bytes received',
      [LResp.StatusCode, LStream.Size]));

    if LResp.StatusCode <> 200 then
    begin
      Step('GET failed — check server is running on ' + SERVER_URL);
      Exit;
    end;

    if LStream.Size = 0 then
    begin
      Step('Empty body — server returned 0 bytes');
      Exit;
    end;

    { Reset position before LoadFromStream.
      THTTPClient.Get fills from 0, so Position = Size after the call. }
    LStream.Position := 0;
    LTable.LoadFromStream(LStream, TFDStorageFormat.sfBinary);
    LN := LTable.RecordCount;
    Step(Format('Loaded %d row(s) from stream', [LN]));

    { Replace local DB contents with what the server sent.

      The id column is inserted EXPLICITLY, and that is the whole point of this
      step. Omitting it lets SQLite's AUTOINCREMENT mint fresh local ids, so the
      local rows would carry ids the server has never seen — and every later
      PUT or DELETE that matches on id would report "missing" for every row
      while looking, from the client side, perfectly correct.

      Sending an id column back is only meaningful because the server sends one:
      the sfBinary stream carries the full table structure, ids included. }
    LQ.Connection := GConn;
    LQ.SQL.Text   := 'DELETE FROM items';
    LQ.ExecSQL;

    LQ.SQL.Text :=
      'INSERT INTO items (id, name, value) VALUES (:id, :name, :value)';
    LTable.First;
    while not LTable.EOF do
    begin
      LQ.ParamByName('id').AsInteger  := LTable.FieldByName('id').AsInteger;
      LQ.ParamByName('name').AsString := LTable.FieldByName('name').AsString;
      LQ.ParamByName('value').AsFloat := LTable.FieldByName('value').AsFloat;
      LQ.ExecSQL;
      LTable.Next;
    end;
    Step(Format('Local DB updated — %d row(s), server ids preserved', [LN]));
  finally
    LQ.Free;
    LTable.Free;
    LStream.Free;
    LClient.Free;
  end;
end;

// ─── GET /items/count ─────────────────────────────────────────────────────────
// Retrieves the server's row count as plain text — quick health check.

procedure GetServerCount;
var
  LClient: THTTPClient;
  LResp:   IHTTPResponse;
begin
  Banner('GET /items/count  — server row count');
  LClient := THTTPClient.Create;
  try
    LResp := LClient.Get(SERVER_URL + '/items/count');
    if LResp.StatusCode = 200 then
      Step('Server reports ' + LResp.ContentAsString + ' row(s)')
    else
      Step('Failed: HTTP ' + IntToStr(LResp.StatusCode));
  finally
    LClient.Free;
  end;
end;

// ─── Helper: local rows → sfBinary stream ────────────────────────────────────
// Shared by PUT and DELETE. Caller owns the returned stream and must free it.
// Position is left at 0 — the reset that POST demonstrates the hard way.

function BuildStreamFromSQL(const ASQL: string; out ACount: Integer): TMemoryStream;
var
  LQ:     TFDQuery;
  LTable: TFDMemTable;
begin
  Result := TMemoryStream.Create;
  LQ     := TFDQuery.Create(nil);
  LTable := TFDMemTable.Create(nil);
  try
    LQ.Connection := GConn;
    LQ.SQL.Text   := ASQL;
    LQ.Open;
    LTable.CopyDataSet(LQ, [coStructure, coRestart, coAppend]);
    ACount := LTable.RecordCount;
    LTable.SaveToStream(Result, TFDStorageFormat.sfBinary);
    Result.Position := 0;             { REQUIRED — see PostItemsToServer }
  finally
    LTable.Free;
    LQ.Free;
  end;
end;

// ─── PUT /items ───────────────────────────────────────────────────────────────
// Renames every local row, then PUTs the table back. The server matches on id
// and UPDATEs, so this exercises the same Req.Body<TStream> path as POST while
// proving the id column survives the sfBinary round-trip.

procedure PutItemsToServer;
var
  LStream: TMemoryStream;
  LClient: THTTPClient;
  LResp:   IHTTPResponse;
  LQ:      TFDQuery;
  LN:      Integer;
begin
  Banner('PUT /items  — rename local rows, update server by id');

  LQ := TFDQuery.Create(nil);
  try
    LQ.Connection := GConn;
    LQ.SQL.Text   := 'UPDATE items SET name = ''Renamed '' || name';
    LQ.ExecSQL;
  finally
    LQ.Free;
  end;
  Step('Local rows renamed with a "Renamed " prefix');

  { Nested try/finally, not one flat block: BuildStreamFromSQL runs SQL and can
    raise, and LClient already exists by then. A single finally that frees both
    would never run, leaking the client. }
  LClient := THTTPClient.Create;
  try
    LStream := BuildStreamFromSQL('SELECT id, name, value FROM items ORDER BY id', LN);
    try
      Step(Format('Serialised %d row(s), %d bytes (Position 0)', [LN, LStream.Size]));
      LResp := LClient.Put(SERVER_URL + '/items', LStream, nil,
        [TNameValuePair.Create('Content-Type', 'application/octet-stream')]);
      Step(Format('Server replied: %d — %s',
        [LResp.StatusCode, LResp.ContentAsString]));
      if LResp.StatusCode <> 200 then
        Step('*** PUT failed — check the id column is present in the stream.');
    finally
      LStream.Free;
    end;
  finally
    LClient.Free;
  end;
end;

// ─── DELETE /items/:id ────────────────────────────────────────────────────────
// The conventional single-resource form: no body, no stream, 204 on success.

procedure DeleteOneFromServer;
var
  LClient: THTTPClient;
  LResp:   IHTTPResponse;
  LQ:      TFDQuery;
  LId:     Integer;
begin
  Banner('DELETE /items/:id  — single resource, no body');

  LId := -1;
  LQ  := TFDQuery.Create(nil);
  try
    LQ.Connection := GConn;
    LQ.SQL.Text   := 'SELECT MAX(id) AS n FROM items';
    LQ.Open;
    if not LQ.FieldByName('n').IsNull then
      LId := LQ.FieldByName('n').AsInteger;
  finally
    LQ.Free;
  end;

  if LId < 0 then
  begin
    Step('No local rows — nothing to delete');
    Exit;
  end;

  LClient := THTTPClient.Create;
  try
    LResp := LClient.Delete(SERVER_URL + '/items/' + IntToStr(LId));
    { 204 carries no body by definition — do not expect one. }
    if LResp.StatusCode = 204 then
      Step(Format('DELETE /items/%d → HTTP 204 (No Content, as expected)', [LId]))
    else
      Step(Format('DELETE /items/%d → HTTP %d — %s',
        [LId, LResp.StatusCode, LResp.ContentAsString]));
  finally
    LClient.Free;
  end;
end;

// ─── DELETE /items (stream body) ──────────────────────────────────────────────
// Sends a TFDMemTable sfBinary listing the ids to delete.
//
// A body on DELETE is legal but has no defined semantics (RFC 9110 §9.3.5), so
// proxies may drop it. Shown because the TStream request path is identical on
// DELETE — not because it is the right design for a public API.

procedure DeleteManyFromServer;
var
  LStream: TMemoryStream;
  LClient: THTTPClient;
  LReq:    IHTTPRequest;
  LResp:   IHTTPResponse;
  LN:      Integer;
begin
  Banner('DELETE /items  — delete by id list (sfBinary body)');

  LClient := THTTPClient.Create;
  try
    LStream := BuildStreamFromSQL(
      'SELECT id, name, value FROM items ORDER BY id LIMIT 2', LN);
    try
      if LN = 0 then
      begin
        Step('No local rows left — nothing to send');
        Exit;
      end;
      Step(Format('Serialised %d id(s), %d bytes', [LN, LStream.Size]));

      { THTTPClient.Delete takes no source stream — none of its convenience
        methods do, for DELETE. The request is therefore built by hand:
        GetRequest gives an IHTTPRequest whose SourceStream can be set, and
        Execute sends it. That awkwardness is the client library declining to
        encourage a body on DELETE, not a server limitation. }
      LReq := LClient.GetRequest('DELETE', SERVER_URL + '/items');
      LReq.SourceStream := LStream;
      LReq.AddHeader('Content-Type', 'application/octet-stream');
      LResp := LClient.Execute(LReq, nil);

      Step(Format('Server replied: %d — %s',
        [LResp.StatusCode, LResp.ContentAsString]));
    finally
      LStream.Free;
    end;
  finally
    LClient.Free;
  end;
end;

// ─── GET /items/export ────────────────────────────────────────────────────────
// Same bytes as GET /items, but sent with Res.Download — so the only observable
// difference is Content-Disposition: attachment instead of inline.

procedure GetExportFromServer;
var
  LClient: THTTPClient;
  LStream: TMemoryStream;
  LResp:   IHTTPResponse;
  LDisp:   string;
begin
  Banner('GET /items/export  — Res.Download (attachment)');

  LClient := THTTPClient.Create;
  LStream := TMemoryStream.Create;
  try
    LResp := LClient.Get(SERVER_URL + '/items/export', LStream);
    LDisp := LResp.HeaderValue['Content-Disposition'];
    Step(Format('HTTP %d — %d bytes', [LResp.StatusCode, LStream.Size]));
    Step('Content-Disposition: ' + LDisp);
    if Pos('attachment', LowerCase(LDisp)) > 0 then
      Step('attachment → Res.Download confirmed (GET /items sends inline)')
    else
      Step('*** expected "attachment" — Res.Download may not have been used');
  finally
    LStream.Free;
    LClient.Free;
  end;
end;

// ─── Main ─────────────────────────────────────────────────────────────────────

begin
  try
    WriteLn('FireDAC SQLite Demo — Client');
    WriteLn('Server : ', SERVER_URL);
    WriteLn;

    SetupDB;
    ShowLocalDB('after seed');

    { 1. POST — push local items to the server (Req.Body<TStream>, insert) }
    PostItemsToServer;
    GetServerCount;

    { 2. GET — pull the server dataset back (Res.SendFile, inline).
         The local DB now mirrors the server, so local ids ARE server ids —
         which is what makes the id-matching in steps 3 and 5 work. }
    GetItemsFromServer;
    ShowLocalDB('after GET sync');

    { 3. PUT — rename locally, update the server by id (Req.Body<TStream>) }
    PutItemsToServer;
    GetItemsFromServer;
    ShowLocalDB('after PUT — names should carry the "Renamed " prefix');

    { 4. GET /items/export — same bytes via Res.Download (attachment) }
    GetExportFromServer;

    { 5. DELETE with a stream body — removes the first two ids }
    DeleteManyFromServer;
    GetServerCount;

    { 6. DELETE /items/:id — the conventional single-resource form, 204 }
    DeleteOneFromServer;
    GetServerCount;

    { 7. Final state }
    GetItemsFromServer;
    ShowLocalDB('final — after both DELETE forms');

    GConn.Free;
    WriteLn;
    WriteLn('Done. Press Enter...');
    ReadLn;
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, '[FATAL] ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
