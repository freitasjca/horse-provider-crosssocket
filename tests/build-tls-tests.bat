@echo off
setlocal enabledelayedexpansion
REM ===========================================================================
REM  build-tls-tests.bat — build the TLS / mutual-TLS test pair with dcc64.
REM
REM  scripts\build.bat covers only the port-9100 pair (HorseCSTestServer /
REM  Client), which have .dproj files. The TLS pair has none -- just .dpr -- so
REM  TLS-TESTS.md's "set HORSE_PROVIDER_CROSSSOCKET in the project's Conditional
REM  Defines" has no project to set it in. This supplies the define and the
REM  search paths on the command line instead.
REM
REM  Search paths and the define are copied from HorseCSParamTestServer.dproj,
REM  the sibling in this folder that does have a project file, so they stay in
REM  step with how the param tests are known to build.
REM
REM  Usage:
REM    cd tests
REM    build-tls-tests.bat
REM
REM  Override Delphi discovery:
REM    set DELPHI_ROOT=C:\Program Files ^(x86^)\Embarcadero\Studio\23.0
REM
REM  Exit code: number of programs that failed to build. 0 = both built.
REM
REM  ---------------------------------------------------------------------
REM  NO PARENTHESISED BLOCKS ANYWHERE IN THIS FILE.
REM
REM  Delphi lives under "C:\Program Files (x86)\...". cmd matches parens BEFORE
REM  expanding variables, so any %VAR% holding that path closes an ( ) block
REM  early and the script fails in a way that looks nothing like its cause. It
REM  is the variable's VALUE that breaks it, not its name. Every branch here
REM  uses goto, and path variables are read with delayed expansion !VAR!.
REM
REM  -B on every compile, deliberately. A .dcu built with different defines is
REM  NOT invalidated by changing them -- dcc compares timestamps, not the
REM  define set -- and the failure is silent: you test the wrong provider with
REM  no diagnostic.
REM ===========================================================================

set "FAILED=0"

REM -- Locate dcc64 ----------------------------------------------------------
set "DCC="
if not "%DELPHI_ROOT%"=="" if exist "%DELPHI_ROOT%\bin\dcc64.exe" set "DCC=%DELPHI_ROOT%\bin\dcc64.exe"
if not "%BDS%"=="" if exist "%BDS%\bin\dcc64.exe" set "DCC=%BDS%\bin\dcc64.exe"
if not defined DCC for /f "delims=" %%I in ('where dcc64.exe 2^>nul') do if not defined DCC set "DCC=%%I"
if not defined DCC goto :no_dcc

REM -- Search paths, from HorseCSParamTestServer.dproj ------------------------
set "UP=..\src"
set "UP=!UP!;..\..\horse\src"
set "UP=!UP!;..\..\Delphi-Cross-Socket"
set "UP=!UP!;..\..\Delphi-Cross-Socket\Net"
set "UP=!UP!;..\..\Delphi-Cross-Socket\Utils"
set "UP=!UP!;..\..\Delphi-Cross-Socket\CnPack\Common"
set "UP=!UP!;..\..\Delphi-Cross-Socket\CnPack\Crypto"
set "UP=!UP!;..\..\Delphi-Cross-Socket\DelphiToFPC"

REM Include paths (-I), which are NOT the same as unit paths (-U). Two are
REM needed and each fails as "File not found" naming only the .inc:
REM   zLib.inc     at the DCS repo root -- every DCS unit opens with {$I zLib.inc}
REM   CnPack.inc   in CnPack\Common     -- every CnPack unit opens with {$I CnPack.inc}
REM Having CnPack on -U is not enough. The client builds without this because it
REM never reaches CnPack; the server does, via the provider -> Utils.Hash -> CnMD5.
set "IP=..\..\Delphi-Cross-Socket"
set "IP=!IP!;..\..\Delphi-Cross-Socket\CnPack\Common"

set "NS=System;Xml;Data;Datasnap;Web;Soap;Winapi;System.Win;Data.Win;Web.Win;Xml.Win"

echo dcc64:  !DCC!
echo Horse:  ..\..\horse\src
echo DCS:    ..\..\Delphi-Cross-Socket
echo.

set "PROG=HorseCSTLSTestServer"
call :build

set "PROG=HorseCSTLSTestClient"
call :build

echo.
echo ===========================================================================
if "!FAILED!"=="0" goto :all_ok
echo  FAILED  - !FAILED! program^(s^) did not build
exit /b !FAILED!

:all_ok
echo  BUILT   HorseCSTLSTestServer.exe + HorseCSTLSTestClient.exe
echo.
echo  Certificates are already beside them in certs\ -- both programs find it
echo  via FindCertDir. Run from THIS folder, in two terminals:
echo.
echo    one-way TLS:   HorseCSTLSTestServer          then  HorseCSTLSTestClient
echo    mutual TLS:    HorseCSTLSTestServer mtls     then  HorseCSTLSTestClient mtls
echo.
echo  The client's exit code is the number of failed assertions; 0 means pass.
echo  Pass 'mtls' to BOTH ends or the handshake result is meaningless.
exit /b 0

REM ===========================================================================
:build
echo -- !PROG! ----------------------------------------------------------------
if not exist "!PROG!.dpr" goto :b_missing

"!DCC!" -B -DHORSE_PROVIDER_CROSSSOCKET -U"!UP!" -I"!IP!" -NS"!NS!" "!PROG!.dpr" > "!PROG!.buildlog" 2>&1
if errorlevel 1 goto :b_fail
if not exist "!PROG!.exe" goto :b_fail
echo    ok
goto :eof

:b_fail
echo    FAILED
findstr /C:"Error" /C:"Fatal" "!PROG!.buildlog"
echo.
echo    If that says "Can't find unit Net.CrossSslSocket..." the DCS path is
echo    wrong -- these paths assume the repos are siblings, e.g.
echo    C:\lang\Repo\horse-provider-crosssocket and C:\lang\Repo\Delphi-Cross-Socket.
echo.
echo    If it says F1026 "File not found: CnPack.inc" or "zLib.inc", the -I
echo    list is short. A unit path ^(-U^) does not satisfy an include.
echo.
echo    If it says F2039 "Could not create output file", the compile SUCCEEDED
echo    and only the write failed: the exe is still running.
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
