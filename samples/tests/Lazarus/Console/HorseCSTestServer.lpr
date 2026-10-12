program HorseCSTestServer;

{
  Horse + CrossSocket — Integration Test Server (Lazarus · Console shape)
  =======================================================================

  Conditional defines (Project → Project Options → Custom Options):
    -dHORSE_PROVIDER_CROSSSOCKET

  Project type: Lazarus console program (Application class: Console).

  CrossSocket runs as the self-hosted Provider, replacing the FPC default
  fphttpserver. On a console FPC binary IsConsole = True so Listen blocks
  the main thread; the POSIX signal handler unblocks it on SIGTERM / SIGINT.

  Routes: see Common\Horse.CrossSocket.TestRoutes.pas — same 32 surfaces
  the shared HorseCSTestClient exercises.

  Run sequence:
    1. lazbuild HorseCSTestServer.lpi  (or compile in the IDE)
    2. ./HorseCSTestServer
    3. From a Delphi or Lazarus host, run the test client.
}

{$MODE DELPHI}{$H+}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  SysUtils,
  Horse,
  Horse.Provider.CrossSocket,
  Horse.CrossSocket.TestRoutes;

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

  RegisterTestRoutes;

  WriteLn(Format('[HorseCSTest · Lazarus/Console] Listening on http://127.0.0.1:%d',
    [TEST_PORT]));
  WriteLn('Press Ctrl-C to stop.');

  THorse.Listen(TEST_PORT);

  WriteLn('[HorseCSTest · Lazarus/Console] Stopped cleanly.');
end.
