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
//  ── Run ──────────────────────────────────────────────────────────────────
//  1. Start FireDACServer.exe first.
//  2. Run this program.  It will POST, GET, and print a summary.
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

    { Replace local DB contents with what the server sent }
    LQ.Connection := GConn;
    LQ.SQL.Text   := 'DELETE FROM items';
    LQ.ExecSQL;

    LQ.SQL.Text :=
      'INSERT INTO items (name, value) VALUES (:name, :value)';
    LTable.First;
    while not LTable.EOF do
    begin
      LQ.ParamByName('name').AsString := LTable.FieldByName('name').AsString;
      LQ.ParamByName('value').AsFloat := LTable.FieldByName('value').AsFloat;
      LQ.ExecSQL;
      LTable.Next;
    end;
    Step(Format('Local DB updated — %d row(s)', [LN]));
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

// ─── Main ─────────────────────────────────────────────────────────────────────

begin
  try
    WriteLn('FireDAC SQLite Demo — Client');
    WriteLn('Server : ', SERVER_URL);
    WriteLn;

    SetupDB;
    ShowLocalDB('after seed');

    { 1. POST — push local items to the server }
    PostItemsToServer;

    { 2. Count — verify server received them }
    GetServerCount;

    { 3. GET — pull the full server dataset back into local DB }
    GetItemsFromServer;
    ShowLocalDB('after GET sync');

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
