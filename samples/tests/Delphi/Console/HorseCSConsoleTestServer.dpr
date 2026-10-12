program HorseCSConsoleTestServer;

{
  Horse + CrossSocket — Integration Test Server (Delphi · Console shape)
  ======================================================================

  Conditional defines (Project → Options → Conditional Defines):
    HORSE_PROVIDER_CROSSSOCKET     (PATCH-HORSE-2; legacy HORSE_CROSSSOCKET works too)

  Project type: Console Application.

  This is the simplest of the seven shapes exercised under samples/tests/.
  CrossSocket's Listen blocks the main thread because IsConsole = True;
  SetConsoleCtrlHandler unblocks it on Ctrl-C / Ctrl-Break / SCM stop.

  Routes: see Common\Horse.CrossSocket.TestRoutes.pas — same 32 surfaces the
  shared HorseCSTestClient.dpr exercises. All per-shape servers in this tree
  register exactly the same routes so the client is interchangeable.

  Run sequence:
    1. Start this server.
    2. Run HorseCSTestClient.exe (from the parent folder).
    3. Expect "88 passed, 1 failed" — the single failure is the documented
       multi-value Set-Cookie limitation (FCustomHeaders TDictionary<>).
}

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  Horse,
{$IF DEFINED(HORSE_PROVIDER_CROSSSOCKET) or DEFINED(HORSE_CROSSSOCKET)}
  Horse.Provider.CrossSocket,
  Horse.Provider.CrossSocket.WorkerPool,
{$IFEND}
  Horse.CrossSocket.TestRoutes in '..\..\Common\Horse.CrossSocket.TestRoutes.pas';

function CtrlHandler(dwCtrlType: DWORD): BOOL; stdcall;
begin
  case dwCtrlType of
    CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT,
    CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT:
      begin
        THorse.StopListen;     // drains in-flight requests via SEC-30
        Result := True;
      end;
  else
    Result := False;
  end;
end;

begin
  SetConsoleCtrlHandler(@CtrlHandler, True);

  RegisterTestRoutes;

  WriteLn(Format('[HorseCSTest · Delphi/Console] Listening on http://127.0.0.1:%d',
    [TEST_PORT]));
  WriteLn('Press Ctrl-C to stop.');

  THorse.Listen(TEST_PORT);

  WriteLn('[HorseCSTest · Delphi/Console] Stopped cleanly.');
end.
