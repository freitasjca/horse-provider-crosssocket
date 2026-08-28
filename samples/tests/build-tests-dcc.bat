@echo off
setlocal enabledelayedexpansion
REM ===========================================================================
REM  build-tests-dcc.bat — build the port-9100 test pair with dcc64 directly.
REM
REM  THIS IS THE FALLBACK. Use scripts\build.bat first.
REM
REM  build.bat drives msbuild over the .dproj files, which stay the source of
REM  truth for search paths, defines and platform config. Prefer it.
REM
REM  This script exists for when msbuild cannot be used. The failure it was
REM  written for was:
REM
REM    warning MSB6002: The command-line for the "DCC" task is too long
REM    error   MSB6003: The specified task executable "dcc" could not be run.
REM                     The filename or extension is too long
REM
REM  msbuild expands $(DCC_UnitSearchPath) from the machine-wide IDE settings,
REM  so the DCC command line grows to include every library registered in the
REM  IDE -- ACBr, ZXing, LockBox, Python4Delphi, the lot -- and blows past
REM  Windows' ~32K limit. It reads like a broken toolchain and is really just
REM  path bloat.
REM
REM  build.bat now passes /p:DCC_UseMSBuildExternally=true, which routes the
REM  DCC arguments through a .cmds response file and removes that limit, so
REM  the original reason for this script is GONE. Kept because a direct dcc64
REM  call is still the quickest way to isolate a build problem from the IDE
REM  configuration, and because it needs no .dproj at all.
REM
REM  COST OF KEEPING IT: the paths below duplicate DCC_UnitSearchPath from
REM  HorseCSTestServer.dproj. If you change the .dproj, change them here too,
REM  or this script silently compiles against a different set of units than
REM  build.bat does. Same approach as tests\build-tls-tests.bat, which does
REM  NOT have that problem -- the TLS pair has no .dproj to drift from.
REM
REM  Search paths below are the DCC_UnitSearchPath from HorseCSTestServer.dproj,
REM  so the two stay in step. The .dproj remains the source of truth for IDE
REM  builds; this is for the command line.
REM
REM  Usage:
REM    cd samples\tests
REM    build-tests-dcc.bat
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

REM -- Include paths (-I) — NOT the same as unit paths ------------------------
REM   zLib.inc    at the DCS repo root  -- every DCS unit opens {$I zLib.inc}
REM   CnPack.inc  in CnPack\Common      -- every CnPack unit opens {$I CnPack.inc}
REM Having CnPack on -U is not enough; the failure is
REM   F1026 File not found: 'CnPack.inc'
set "IP=..\..\..\Delphi-Cross-Socket"
set "IP=!IP!;..\..\..\Delphi-Cross-Socket\CnPack\Common"

set "NS=System;Xml;Data;Datasnap;Web;Soap;Winapi;System.Win;Data.Win;Web.Win;Xml.Win"

echo dcc64:  !DCC!
echo Horse:  ..\..\..\horse\src
echo DCS:    ..\..\..\Delphi-Cross-Socket
echo.

set "PROG=HorseCSTestServer"
call :build

set "PROG=HorseCSTestClient"
call :build

echo.
echo ===========================================================================
if "!FAILED!"=="0" goto :all_ok
echo  FAILED  - !FAILED! program^(s^) did not build
exit /b !FAILED!

:all_ok
echo  BUILT   HorseCSTestServer.exe + HorseCSTestClient.exe  ^(in this folder^)
echo.
echo  Run in two terminals from HERE:
echo.
echo    HorseCSTestServer          terminal 1  ^(listens on 127.0.0.1:9100^)
echo    HorseCSTestClient          terminal 2  ^(105 checks^)
echo.
echo  Client exit code = number of failed checks; 0 means all passed.
echo  Watch checks 07, 14, 18 and 29 -- those are the stale keep-alive ones
echo  that PATCH-CSHTTP-3 exists to fix.
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
:no_dcc
echo ERROR: dcc64.exe not found.
echo        set DELPHI_ROOT=C:\Program Files ^(x86^)\Embarcadero\Studio\23.0
echo        or run this from a shell where rsvars.bat has been called.
exit /b 2
