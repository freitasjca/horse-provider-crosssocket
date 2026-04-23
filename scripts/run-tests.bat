@echo off
setlocal EnableDelayedExpansion

REM ============================================================================
REM  run-tests.bat  —  Integration test runner for horse-provider-crosssocket
REM
REM  Usage:
REM    run-tests.bat [Win32|Win64] [Release|Debug]
REM
REM  Defaults: Win64 Release
REM
REM  Test model:
REM    HorseCSTestServer listens on 127.0.0.1:9100.
REM    HorseCSTestClient runs 14 integration tests and exits with:
REM      0  = all tests passed
REM      N  = number of failed tests
REM
REM  This script:
REM    1. Starts the server in the background
REM    2. Waits for it to accept connections (health-check GET /ping)
REM    3. Runs the client; captures its exit code
REM    4. Always kills the server on exit (success or failure)
REM    5. Exits with the client's exit code
REM ============================================================================

set PLATFORM=%~1
set CONFIG=%~2
if "%PLATFORM%"=="" set PLATFORM=Win64
if "%CONFIG%"==""   set CONFIG=Release

set SERVER_EXE=samples\tests\%PLATFORM%\%CONFIG%\HorseCSTestServer.exe
set CLIENT_EXE=samples\tests\%PLATFORM%\%CONFIG%\HorseCSTestClient.exe
set TEST_PORT=9100
set HEALTH_URL=http://127.0.0.1:%TEST_PORT%/ping

echo.
echo ============================================================
echo  Integration tests  (%CONFIG% %PLATFORM%)
echo ============================================================

REM -- Verify executables exist ------------------------------------------------

if not exist "%SERVER_EXE%" (
    echo [ERROR] Server executable not found: %SERVER_EXE%
    echo         Run scripts\build.bat first.
    exit /b 1
)
if not exist "%CLIENT_EXE%" (
    echo [ERROR] Client executable not found: %CLIENT_EXE%
    echo         Run scripts\build.bat first.
    exit /b 1
)

REM -- Kill any leftover server from a previous run ----------------------------

tasklist /FI "IMAGENAME eq HorseCSTestServer.exe" 2>nul | find /I "HorseCSTestServer.exe" >nul
if not errorlevel 1 (
    echo [test] Killing leftover HorseCSTestServer.exe...
    taskkill /F /IM HorseCSTestServer.exe /T >nul 2>&1
    timeout /t 1 /nobreak >nul
)

REM -- Start server in background ----------------------------------------------

echo [test] Starting server on port %TEST_PORT%...
start "HorseCSTestServer" /B "%SERVER_EXE%"

REM -- Wait for server to be ready (health-check with curl or PowerShell) ------
REM
REM  Tries GET /ping up to 10 times with 500 ms intervals (5 s total timeout).

set READY=0
for /L %%I in (1,1,10) do (
    if "!READY!"=="0" (
        powershell -NoProfile -Command ^
            "try { $r=(Invoke-WebRequest -Uri '%HEALTH_URL%' -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop); if($r.StatusCode -eq 200){exit 0}else{exit 1} } catch { exit 1 }" ^
            >nul 2>&1
        if not errorlevel 1 (
            set READY=1
            echo [test] Server ready after %%I attempt(s^).
        ) else (
            timeout /t 1 /nobreak >nul
        )
    )
)

if "!READY!"=="0" (
    echo [ERROR] Server did not start within 10 seconds.
    taskkill /F /IM HorseCSTestServer.exe /T >nul 2>&1
    exit /b 1
)

REM -- Run client --------------------------------------------------------------

echo [test] Running client test suite...
echo.
"%CLIENT_EXE%"
set TEST_EXIT=%ERRORLEVEL%

REM -- Shutdown server ---------------------------------------------------------

echo.
echo [test] Stopping server...
taskkill /F /IM HorseCSTestServer.exe /T >nul 2>&1

REM -- Report ------------------------------------------------------------------

echo.
if "%TEST_EXIT%"=="0" (
    echo ============================================================
    echo  All tests PASSED
    echo ============================================================
) else (
    echo ============================================================
    echo  %TEST_EXIT% test(s^) FAILED
    echo ============================================================
)

exit /b %TEST_EXIT%
