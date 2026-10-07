@echo off
setlocal enabledelayedexpansion
REM ===========================================================================
REM  build-repro-dcc.bat
REM  Build HorseCSUserReproTest by invoking dcc64 DIRECTLY.
REM
REM  Plain HTTP on port 9252 - no certs, no OpenSSL. Separate from
REM  build-tls-tests.bat so a TLS toolchain is not a prerequisite for a question
REM  that has nothing to do with TLS.
REM
REM  -I needs BOTH the DCS root and CnPack\Common: every DCS unit opens with
REM  {$I zLib.inc} and every CnPack unit with {$I CnPack.inc}, and a unit path
REM  (-U) does not satisfy an include. Same list build-tls-tests.bat documents.
REM
REM  No parenthesised blocks - same cmd quirk the sibling scripts document.
REM
REM  Usage:  build-repro-dcc.bat [Release^|Debug]      (default Release)
REM  Win64 only. Run from this tests\ folder.
REM ===========================================================================

set "TGTCONFIG=%~1"
if "!TGTCONFIG!"=="" set "TGTCONFIG=Release"
if /I "!TGTCONFIG!"=="Release" goto :cfg_ok
if /I "!TGTCONFIG!"=="Debug"   goto :cfg_ok
echo ERROR: config must be Release or Debug, got "!TGTCONFIG!".
exit /b 2
:cfg_ok

cd /d "%~dp0"

if not "%DELPHI_ROOT%"=="" if exist "%DELPHI_ROOT%\bin\dcc64.exe" set "DCC=%DELPHI_ROOT%\bin\dcc64.exe"
if not "%BDS%"=="" if exist "%BDS%\bin\dcc64.exe" set "DCC=%BDS%\bin\dcc64.exe"
if not defined DCC for %%V in (23.0 22.0 21.0 20.0 19.0) do call :try_version %%V
if not defined DCC for /f "delims=" %%I in ('where dcc64.exe 2^>nul') do if not defined DCC set "DCC=%%I"
if not defined DCC goto :no_dcc

for %%I in ("!DCC!") do set "DCCDIR=%%~dpI"
for %%I in ("!DCCDIR!..") do set "BDSROOT=%%~fI"
set "RTL=!BDSROOT!\lib\Win64\release"
if /I "!TGTCONFIG!"=="Debug" set "RTL=!BDSROOT!\lib\Win64\debug"
if not exist "!RTL!" goto :no_rtl

for %%I in ("%~dp0..") do set "PROV=%%~fI"
for %%I in ("!PROV!\..") do set "ROOT=%%~fI"
set "DCS=!ROOT!\Delphi-Cross-Socket"

if not exist "!PROV!\src\Horse.Provider.CrossSocket.pas" goto :no_prov
if not exist "!DCS!\Net"                                 goto :no_dcs

set "UPATH=!RTL!;!PROV!\src;!ROOT!\horse\src"
set "UPATH=!UPATH!;!DCS!;!DCS!\Net;!DCS!\Utils;!DCS!\DelphiToFPC"
set "UPATH=!UPATH!;!DCS!\CnPack\Common;!DCS!\CnPack\Crypto"

set "IPATH=!DCS!;!DCS!\CnPack\Common"

set "NS=Winapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win;System;Xml;Data;Datasnap;Web;Soap"
set "ALIAS=Generics.Collections=System.Generics.Collections;Generics.Defaults=System.Generics.Defaults;WinTypes=Winapi.Windows;WinProcs=Winapi.Windows;DbiTypes=BDE;DbiProcs=BDE;DbiErrs=BDE"
set "DEFS=!TGTCONFIG!;HORSE_PROVIDER_CROSSSOCKET"
set "OPTS=--no-config -B -Q -TX.exe"
if /I "!TGTCONFIG!"=="Release" set "OPTS=!OPTS! -$D0 -$L- -$Y-"

set "EXEDIR=%~dp0bin"
set "DCUDIR=%~dp0temp"
if not exist "!EXEDIR!" mkdir "!EXEDIR!" 2>nul
if not exist "!DCUDIR!" mkdir "!DCUDIR!" 2>nul

echo dcc64:  !DCC!
echo config: !TGTCONFIG!
echo DCS:    !DCS!
echo out:    !EXEDIR!
echo.

set "NAME=HorseCSUserReproTest"
if not exist "%~dp0!NAME!.dpr" goto :no_src
echo -- !NAME! -----------------------------------------------------------
"!DCC!" !OPTS! -A!ALIAS! -D!DEFS! -NS!NS! ^
  -U"!UPATH!" -I"!IPATH!" -R"!UPATH!" -O"!UPATH!" ^
  -E"!EXEDIR!" -N0"!DCUDIR!" -NU"!DCUDIR!" ^
  "!NAME!.dpr"
if errorlevel 1 goto :build_err
echo    OK
echo.
echo ===========================================================================
echo  BUILD OK
echo.
echo  Run it directly - it starts and stops its own server on port 9252:
echo    bin\HorseCSUserReproTest.exe
echo.
echo  Exit code 0 = a pre-encoded body passed through untouched AND a plain
echo  reply, N = that many assertions failed, 2 = VOID ^(nothing measured^).
echo.
echo  BISECT TOOL. All seven middlewares are OFF by default - that run is the
echo  provider-only baseline. Enable them ONE AT A TIME at the top of the .dpr,
echo  in the reporter's order, and rebuild:
echo.
echo     USE_CORS  USE_HANDLEEXCEPTION  USE_COMPRESSION  USE_JHONSON
echo     USE_JWT   USE_OCTETSTREAM      USE_LOGGER
echo.
echo  The first run whose T1 fails names the culprit. A define is only real if
echo  the banner line prints its name - that is the check that it registered.
echo.
echo  Drop the real Put_Body.json beside the exe to use the actual payload;
echo  otherwise an embedded fallback with the same trigger is used.
echo.
echo  Add the argument "tls" for HTTPS ^(needs certs\server.crt + .key^).
echo ===========================================================================
exit /b 0

:build_err
echo    FAILED - a real compiler error, look for [dcc64 Error] above
echo    "Can't find unit Net.CrossSslSocket..." means the DCS path is wrong;
echo    F1026 "File not found: CnPack.inc" or "zLib.inc" means the -I list is short.
exit /b 1

:try_version
set "CAND=%ProgramFiles(x86)%\Embarcadero\Studio\%~1\bin\dcc64.exe"
if exist "!CAND!" if not defined DCC set "DCC=!CAND!"
exit /b 0

:no_dcc
echo ERROR: dcc64.exe not found. Set DELPHI_ROOT, e.g.
echo        set "DELPHI_ROOT=C:\Program Files (x86)\Embarcadero\Studio\23.0"
exit /b 2
:no_rtl
echo ERROR: Win64 RTL not found at !RTL!
exit /b 2
:no_prov
echo ERROR: provider source not found at !PROV!\src
exit /b 2
:no_dcs
echo ERROR: Delphi-Cross-Socket not found at !DCS!
echo        These paths assume sibling checkouts, e.g. C:\lang\Repo\...
exit /b 2
:no_src
echo ERROR: !NAME!.dpr not found in %~dp0
exit /b 2
