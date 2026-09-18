@echo off
setlocal enabledelayedexpansion
REM ===========================================================================
REM  build-diag-dcc.bat — build the port-18080 DIAGNOSTIC pair with dcc64.
REM
REM  Separate from build-tests-dcc.bat on purpose: that script builds the
REM  permanent 9010 suite and is validated. This pair is a throwaway probe for
REM  a reported defect (PUT response fails ContentAsString(TEncoding.UTF8)),
REM  so it gets its own script rather than editing a working one.
REM
REM  Builds:
REM    HorseCSDiagServer.dpr   listens on 127.0.0.1:18080
REM    HorseCSDiagClient.dpr   RTL-only probe client
REM
REM  Usage:
REM    cd samples\tests
REM    build-diag-dcc.bat
REM
REM  Then, in two terminals from HERE:
REM    HorseCSDiagServer                 compression OFF (the Horse default)
REM    HorseCSDiagServer --compress      compression ON  (the A/B control arm)
REM    HorseCSDiagClient                 runs the matrix against 18080
REM
REM  Override Delphi discovery:
REM    set DELPHI_ROOT=C:\Program Files ^(x86^)\Embarcadero\Studio\23.0
REM
REM  Exit code: number of programs that failed to build.
REM
REM  ---------------------------------------------------------------------
REM  NO PARENTHESISED BLOCKS. Delphi lives under "C:\Program Files (x86)\...";
REM  cmd matches parens BEFORE expanding variables, so a %VAR% holding that
REM  path closes an ( ) block early. Every branch uses goto and every path
REM  variable is read with delayed expansion !VAR!.
REM
REM  -B on every compile: a .dcu built with different defines is NOT
REM  invalidated by changing them -- dcc compares timestamps, not defines.
REM  That matters more here than anywhere else, because this pair exists to
REM  compare the CrossSocket path against the Indy path.
REM
REM  -DHORSE_PROVIDER_CROSSSOCKET is the canonical PATCH-HORSE-2 name. The
REM  server aliases it to the legacy HORSE_CROSSSOCKET at the top of its .dpr.
REM  To build the INDY control arm instead, drop the -D: see :build_indy below.
REM
REM  Paths mirror build-tests-dcc.bat, which takes them from
REM  HorseCSTestServer.dproj. If those change, change them in BOTH scripts.
REM ===========================================================================

set "FAILED=0"

REM -- Locate dcc64 ----------------------------------------------------------
set "DCC="
if not "%DELPHI_ROOT%"=="" if exist "%DELPHI_ROOT%\bin\dcc64.exe" set "DCC=%DELPHI_ROOT%\bin\dcc64.exe"
if not "%BDS%"=="" if exist "%BDS%\bin\dcc64.exe" set "DCC=%BDS%\bin\dcc64.exe"
if not defined DCC for /f "delims=" %%I in ('where dcc64.exe 2^>nul') do if not defined DCC set "DCC=%%I"
if not defined DCC goto :no_dcc

REM -- Unit paths, from HorseCSTestServer.dproj -------------------------------
set "UP=..\..\..\Delphi-Cross-Socket"
set "UP=!UP!;..\..\..\Delphi-Cross-Socket\Net"
set "UP=!UP!;..\..\..\Delphi-Cross-Socket\Utils"
set "UP=!UP!;..\..\..\Delphi-Cross-Socket\CnPack\Common"
set "UP=!UP!;..\..\..\Delphi-Cross-Socket\CnPack\Crypto"
set "UP=!UP!;..\..\..\Delphi-Cross-Socket\DelphiToFPC"
set "UP=!UP!;..\..\src"
set "UP=!UP!;..\..\..\horse\src"
set "UP=!UP!;..\..\..\horse\tests\src\modules\jhonson\src"

REM -- Include paths (-I) — NOT the same as unit paths ------------------------
REM   zLib.inc    at the DCS repo root  -- every DCS unit opens {$I zLib.inc}
REM   CnPack.inc  in CnPack\Common      -- every CnPack unit opens {$I CnPack.inc}
REM A unit path does NOT satisfy an include; the failure is
REM   F1026 File not found: 'CnPack.inc'
set "IP=..\..\..\Delphi-Cross-Socket"
set "IP=!IP!;..\..\..\Delphi-Cross-Socket\CnPack\Common"

set "NS=System;Xml;Data;Datasnap;Web;Soap;Winapi;System.Win;Data.Win;Web.Win;Xml.Win"

echo dcc64:  !DCC!
echo Horse:  ..\..\..\horse\src
echo DCS:    ..\..\..\Delphi-Cross-Socket
echo.

set "PROG=HorseCSDiagServer"
call :build

set "PROG=HorseCSDiagClient"
call :build

echo.
echo ===========================================================================
if "!FAILED!"=="0" goto :all_ok
echo  FAILED  - !FAILED! program^(s^) did not build
exit /b !FAILED!

:all_ok
echo  BUILT   HorseCSDiagServer.exe + HorseCSDiagClient.exe  ^(in this folder^)
echo.
echo  Run in two terminals from HERE:
echo.
echo    HorseCSDiagServer              terminal 1  ^(listens on 127.0.0.1:18080^)
echo    HorseCSDiagClient              terminal 2  ^(18-case matrix^)
echo.
echo  Then repeat with the control arm:
echo.
echo    HorseCSDiagServer --compress   terminal 1
echo    HorseCSDiagClient              terminal 2
echo.
echo  Watch the server's [SLOTS] line. If it shows every slot empty on every
echo  request, Indy served it and the CrossSocket define did not take effect.
exit /b 0

REM ===========================================================================
:build
echo -- !PROG! ----------------------------------------------------------------
if not exist "!PROG!.dpr" goto :b_missing

"!DCC!" -B -DHORSE_PROVIDER_CROSSSOCKET -U"!UP!" -I"!IP!" -NS"!NS!" -E. "!PROG!.dpr" > "!PROG!.buildlog" 2>&1
if errorlevel 1 goto :b_fail
if not exist "!PROG!.exe" goto :b_fail
echo    ok
goto :eof

:b_fail
echo    FAILED
findstr /C:"Error" /C:"Fatal" "!PROG!.buildlog"
echo.
echo    F1026 "File not found: CnPack.inc" / "zLib.inc" -- the -I list is short.
echo    A unit path ^(-U^) does not satisfy an include.
echo.
echo    "Can't find unit Net.CrossSslSocket..." -- the DCS path is wrong. These
echo    paths assume sibling repos, e.g. C:\lang\Repo\horse-provider-crosssocket
echo    and C:\lang\Repo\Delphi-Cross-Socket.
echo.
echo    E2003 "Undeclared identifier: BodyText" -- your Horse build does not
echo    expose the PATCH-RES-4 shadow properties. Comment out the
echo    {$DEFINE DIAG_SLOTS} line at the top of HorseCSDiagServer.dpr; you lose
echo    only the [SLOTS] diagnostic.
echo.
echo    F2039 "Could not create output file" -- the compile SUCCEEDED and only
echo    the write failed: the exe is still running.
echo        taskkill /IM !PROG!.exe /F
echo.
echo    Full log: !PROG!.buildlog
set /a FAILED+=1
goto :eof

:b_missing
echo    SKIP  !PROG!.dpr not present
goto :eof

REM ===========================================================================
REM :build_indy — the control arm. Not called by default.
REM   To build the Indy comparison, copy the dcc64 line from :build and remove
REM   -DHORSE_PROVIDER_CROSSSOCKET, sending output somewhere else so the two
REM   exes do not overwrite each other:
REM
REM   "!DCC!" -B -U"!UP!" -I"!IP!" -NS"!NS!" -E.\indy "HorseCSDiagServer.dpr"
REM ===========================================================================

REM ===========================================================================
:no_dcc
echo ERROR: dcc64.exe not found.
echo        set DELPHI_ROOT=C:\Program Files ^(x86^)\Embarcadero\Studio\23.0
echo        or run this from a shell where rsvars.bat has been called.
exit /b 2
