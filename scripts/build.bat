@echo off
setlocal EnableDelayedExpansion

REM ============================================================================
REM  build.bat  —  Build script for horse-provider-crosssocket
REM
REM  Usage:
REM    build.bat [Release|Debug] [Win32|Win64] [clean]
REM
REM  Examples:
REM    build.bat                      Release Win64 incremental
REM    build.bat Release Win64        same as above
REM    build.bat Debug Win32          Debug Win32 incremental
REM    build.bat Release Win64 clean  Release Win64, clean first
REM
REM  Steps:
REM    1. Verify prerequisites (check-env.bat)
REM    2. Load Delphi environment (rsvars.bat)
REM    3. boss install — pull patched Horse + CrossSocket forks into modules/
REM    4. Optional: msbuild /t:Clean
REM    5. msbuild HorseCSTestServer.dproj  (HORSE_CROSSSOCKET defined in .dproj)
REM    6. msbuild HorseCSTestClient.dproj
REM ============================================================================

set CONFIG=%~1
set PLATFORM=%~2
set CLEAN_FLAG=%~3
if "%CONFIG%"==""   set CONFIG=Release
if "%PLATFORM%"=="" set PLATFORM=Win64

set DO_CLEAN=0
if /I "%CLEAN_FLAG%"=="clean" set DO_CLEAN=1

echo.
echo ============================================================
echo  horse-provider-crosssocket build
echo  Config=%CONFIG%  Platform=%PLATFORM%
if "%DO_CLEAN%"=="1" echo  (clean build)
echo ============================================================

REM ── Step 1: Environment check ────────────────────────────────────────────────

call "%~dp0check-env.bat" %CONFIG% %PLATFORM%
if errorlevel 1 (
    echo.
    echo [build] Environment check failed — aborting.
    exit /b 1
)

REM ── Step 2: Load Delphi environment ──────────────────────────────────────────
REM
REM  check-env.bat already verified that rsvars.bat exists; re-locate and call it.

if defined DELPHI_ROOT (
    set RSVARS="%DELPHI_ROOT%\bin\rsvars.bat"
    goto :load_rsvars
)
for %%V in (23.0 22.0 21.0) do (
    set CANDIDATE=C:\Program Files (x86)\Embarcadero\Studio\%%V\bin\rsvars.bat
    if exist "!CANDIDATE!" (
        set RSVARS="!CANDIDATE!"
        goto :load_rsvars
    )
)

:load_rsvars
echo.
echo [build] Loading Delphi environment...
call %RSVARS%

REM ── Step 3: boss install ──────────────────────────────────────────────────────
REM
REM  Resolves boss.json dependencies into modules/:
REM    github.com/freitasjca/horse               → modules\horse\
REM    github.com/freitasjca/Delphi-Cross-Socket → modules\Delphi-Cross-Socket\
REM
REM  Both forks carry all required patches.  No separate patch-apply step.

echo.
echo [build] Installing dependencies (boss install)...
boss install
if errorlevel 1 (
    echo [ERROR] boss install failed.
    echo         Ensure boss is in PATH and you have internet access.
    exit /b 1
)

REM ── Step 4: Clean (optional) ─────────────────────────────────────────────────

if "%DO_CLEAN%"=="1" (
    echo.
    echo [build] Cleaning previous output...
    msbuild "samples\tests\HorseCSTestServer.dproj" /t:Clean /p:Config=%CONFIG% /p:Platform=%PLATFORM% /nologo
    msbuild "samples\tests\HorseCSTestClient.dproj" /t:Clean /p:Config=%CONFIG% /p:Platform=%PLATFORM% /nologo
)

REM ── Step 5: Build HorseCSTestServer ──────────────────────────────────────────
REM
REM  The .dproj sets HORSE_CROSSSOCKET in DCC_Define and has all search paths.
REM  Output: samples\tests\$(Platform)\$(Config)\HorseCSTestServer.exe

echo.
echo [build] Building HorseCSTestServer (%CONFIG% %PLATFORM%)...
msbuild "samples\tests\HorseCSTestServer.dproj" ^
    /t:Build ^
    /p:Config=%CONFIG% ^
    /p:Platform=%PLATFORM% ^
    /m ^
    /nologo ^
    /consoleloggerparameters:Summary

if errorlevel 1 (
    echo.
    echo [ERROR] HorseCSTestServer build failed.
    echo         Common causes:
    echo           - modules\ missing: run "boss install" manually
    echo           - Missing unit: check DCC_UnitSearchPath in the .dproj
    echo           - Compiler error: see output above for file:line details
    exit /b 1
)

REM ── Step 6: Build HorseCSTestClient ──────────────────────────────────────────
REM
REM  No HORSE_CROSSSOCKET define needed — client uses TCrossHttpClient directly.
REM  Output: samples\tests\$(Platform)\$(Config)\HorseCSTestClient.exe

echo.
echo [build] Building HorseCSTestClient (%CONFIG% %PLATFORM%)...
msbuild "samples\tests\HorseCSTestClient.dproj" ^
    /t:Build ^
    /p:Config=%CONFIG% ^
    /p:Platform=%PLATFORM% ^
    /m ^
    /nologo ^
    /consoleloggerparameters:Summary

if errorlevel 1 (
    echo.
    echo [ERROR] HorseCSTestClient build failed.
    exit /b 1
)

REM ── Done ─────────────────────────────────────────────────────────────────────

echo.
echo ============================================================
echo  Build SUCCESS
echo  Artifacts:
echo    samples\tests\%PLATFORM%\%CONFIG%\HorseCSTestServer.exe
echo    samples\tests\%PLATFORM%\%CONFIG%\HorseCSTestClient.exe
echo ============================================================
exit /b 0
