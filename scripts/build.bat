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
set TARGETPLAT=%~2
set CLEAN_FLAG=%~3
if "%CONFIG%"==""   set CONFIG=Release
if "%TARGETPLAT%"=="" set TARGETPLAT=Win64

set DO_CLEAN=0
if /I "%CLEAN_FLAG%"=="clean" set DO_CLEAN=1

echo.
echo ============================================================
echo  horse-provider-crosssocket build
echo  Config=%CONFIG%  Platform=%TARGETPLAT%
if "%DO_CLEAN%"=="1" echo  (clean build)
echo ============================================================

REM ── Step 1: Environment check ────────────────────────────────────────────────

call "%~dp0check-env.bat" %CONFIG% %TARGETPLAT%
if errorlevel 1 (
    echo.
    echo [build] Environment check failed — aborting.
    exit /b 1
)

REM ── Step 2: Load Delphi environment ──────────────────────────────────────────

REM  Delphi's rsvars.bat CLEARS the environment variable `Platform` -- that is
REM  what CodeGear.Common.Targets means by "If PLATFORM is defined by your
REM  system's environment". So a script that stores its target in %PLATFORM%
REM  and then calls rsvars silently loses it, and msbuild fails with
REM  `Invalid PLATFORM variable ""`. We keep ours in TARGETPLAT, which rsvars
REM  does not touch; only the msbuild property is still named Platform.
REM
REM  check-env.bat already verified that rsvars.bat exists; re-locate and call it.

if defined DELPHI_ROOT (
    set RSVARS="!DELPHI_ROOT!\bin\rsvars.bat"
    goto :load_rsvars
)
for %%V in (23.0 22.0 21.0) do (
    set "CANDIDATE=C:\Program Files (x86)\Embarcadero\Studio\%%V\bin\rsvars.bat"
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

REM  DCC_UseMSBuildExternally makes CodeGear.Delphi.Targets write the DCC
REM  arguments to a .cmds RESPONSE FILE instead of putting the whole compiler
REM  invocation on MSBuild's process command line. Essential on any machine
REM  with a large IDE Library Path: Delphi's targets expand that global path
REM  into the DCC task command line and blow past Windows' ~32K limit before
REM  dcc64.exe even starts, failing as
REM    warning MSB6002: The command-line for the "DCC" task is too long
REM    error   MSB6003: The specified task executable "dcc" could not be run.
REM                     The filename or extension is too long
REM  which reads like a broken toolchain and is really just path bloat.
REM
REM  It does NOT change the compiler search path or the IDE configuration --
REM  only how the DCC task transports its arguments to dcc64.
REM
REM  Borrowed from horse-provider-nghttp2\scripts\build-msbuild-fixed.bat,
REM  which documents it at length. Keep the two in step.
set "BUILDARGS=/p:DCC_UseMSBuildExternally=true"

REM ── Step 4: Clean (optional) ─────────────────────────────────────────────────

if "%DO_CLEAN%"=="1" (
    echo.
    echo [build] Cleaning previous output...
    msbuild "samples\tests\HorseCSTestServer.dproj" /t:Clean /p:Config=%CONFIG% /p:Platform=%TARGETPLAT% %BUILDARGS% /nologo
    msbuild "samples\tests\HorseCSTestClient.dproj" /t:Clean /p:Config=%CONFIG% /p:Platform=%TARGETPLAT% %BUILDARGS% /nologo
)

REM ── Step 5: Build HorseCSTestServer ──────────────────────────────────────────
REM
REM  The .dproj sets HORSE_CROSSSOCKET in DCC_Define and has all search paths.
REM  Output: samples\tests\$(Platform)\$(Config)\HorseCSTestServer.exe

echo.
echo [build] Building HorseCSTestServer (%CONFIG% %TARGETPLAT%)...
msbuild "samples\tests\HorseCSTestServer.dproj" ^
    /t:Build ^
    /p:Config=%CONFIG% ^
    /p:Platform=%TARGETPLAT% ^
    %BUILDARGS% ^
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
echo [build] Building HorseCSTestClient (%CONFIG% %TARGETPLAT%)...
msbuild "samples\tests\HorseCSTestClient.dproj" ^
    /t:Build ^
    /p:Config=%CONFIG% ^
    /p:Platform=%TARGETPLAT% ^
    %BUILDARGS% ^
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
echo    samples\tests\%TARGETPLAT%\%CONFIG%\HorseCSTestServer.exe
echo    samples\tests\%TARGETPLAT%\%CONFIG%\HorseCSTestClient.exe
echo ============================================================
exit /b 0
