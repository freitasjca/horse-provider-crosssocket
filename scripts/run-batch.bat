@echo off
setlocal EnableDelayedExpansion

REM ============================================================================
REM  run-batch.bat  -  run the integration suite N times against ONE server
REM
REM  Usage:
REM    scripts\run-batch.bat [RUNS] [BIN_DIR]
REM
REM  Defaults: RUNS=10, BIN_DIR=repo-parent\bin\Win64\Release
REM
REM  Why: the worker-pool AV is intermittent, about 4 runs in 10, so a single
REM  run proves nothing either way - a rate needs a batch. At the old rate the
REM  chance of 10 green runs in a row is 0.6 to the power 10, about 0.6 percent.
REM
REM  Model:
REM    - ONE server instance for the whole batch, which is how the AV was
REM      reproduced. Client tests 00 and 40 assert a per-run DELTA of the
REM      server's cumulative failure counter, so runs stay independent.
REM    - A healthy server already listening on the port is REUSED. If it is an
REM      old build without the diag routes, test 00 fails on every run.
REM    - The server runs in its OWN console window, not redirected. The
REM      "[HorseWorkerPool] Task #N raised ..." lines that NAME each failure
REM      print there. They go to ErrOutput, and whether a redirected ErrOutput
REM      is flushed per line before the process ends is unverified, so this
REM      script does not rely on a log file for them.
REM    - The client reads stdin from NUL: it ends on "Press ENTER to exit..."
REM      and would otherwise park the batch after run 1.
REM    - Each run's full client output goes to BIN_DIR\batch-logs\STAMP\run-NN.log
REM      (outside the repo, next to the binaries).
REM
REM  Exit code: number of RED runs. 0 means every run was green.
REM
REM  NOTE: this file must keep CRLF line endings - cmd.exe mis-resolves
REM  positions in LF-only batch files.
REM ============================================================================

set "RUNS=%~1"
if "%RUNS%"=="" set "RUNS=10"
set "BIN_DIR=%~2"
if "%BIN_DIR%"=="" set "BIN_DIR=%~dp0..\..\bin\Win64\Release"

set "SERVER_EXE=%BIN_DIR%\HorseCSTestServer.exe"
set "CLIENT_EXE=%BIN_DIR%\HorseCSTestClient.exe"
set "TEST_PORT=9010"
set "HEALTH_URL=http://127.0.0.1:%TEST_PORT%/ping"

if not exist "%SERVER_EXE%" (
    echo [ERROR] Server executable not found: %SERVER_EXE%
    exit /b 255
)
if not exist "%CLIENT_EXE%" (
    echo [ERROR] Client executable not found: %CLIENT_EXE%
    exit /b 255
)

for /f %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "STAMP=%%T"
set "LOG_DIR=%BIN_DIR%\batch-logs\%STAMP%"
mkdir "%LOG_DIR%" >nul 2>&1

echo.
echo ============================================================
echo  Batch: %RUNS% client runs against one server
echo  Binaries: %BIN_DIR%
echo  Logs:     %LOG_DIR%
echo ============================================================

REM -- Server: reuse a healthy one, otherwise start one in its own window ------

set READY=0
powershell -NoProfile -Command ^
    "try { $r=(Invoke-WebRequest -Uri '%HEALTH_URL%' -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop); if($r.StatusCode -eq 200){exit 0}else{exit 1} } catch { exit 1 }" ^
    >nul 2>&1
if not errorlevel 1 (
    set READY=1
    echo [batch] Server already running and healthy - reusing it.
)

if "!READY!"=="0" (
    echo [batch] Starting server in its own window...
    start "HorseCSTestServer - batch %STAMP%" "%SERVER_EXE%"
    for /L %%W in (1,1,10) do (
        if "!READY!"=="0" (
            powershell -NoProfile -Command ^
                "try { $r=(Invoke-WebRequest -Uri '%HEALTH_URL%' -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop); if($r.StatusCode -eq 200){exit 0}else{exit 1} } catch { exit 1 }" ^
                >nul 2>&1
            if not errorlevel 1 (
                set READY=1
                echo [batch] Server ready after %%W attempt^(s^).
            ) else (
                timeout /t 1 /nobreak >nul
            )
        )
    )
)

if "!READY!"=="0" (
    echo [ERROR] Server did not answer GET /ping within 10 seconds.
    exit /b 255
)

REM -- Runs --------------------------------------------------------------------

set /a GREEN=0
set /a RED=0
echo.
for /L %%I in (1,1,%RUNS%) do (
    set "NN=0%%I"
    set "NN=!NN:~-2!"
    set "LOG=%LOG_DIR%\run-!NN!.log"

    "%CLIENT_EXE%" < nul > "!LOG!" 2>&1
    set "RC=!ERRORLEVEL!"

    set "SUMMARY=no summary line - client did not finish"
    for /f "tokens=2,*" %%A in ('findstr /C:"passed," "!LOG!"') do set "SUMMARY=%%A %%B"

    if "!RC!"=="0" (
        set /a GREEN+=1
        echo [batch] run !NN!  GREEN  !SUMMARY!
    ) else (
        set /a RED+=1
        echo [batch] run !NN!  RED    !SUMMARY!
        findstr /L /C:"  FAIL  " /C:"Unexpected exception" /C:"[PATCH-CSHTTP-3]" "!LOG!"
        tasklist /FI "IMAGENAME eq HorseCSTestServer.exe" 2>nul | find /I "HorseCSTestServer.exe" >nul
        if errorlevel 1 echo [batch] WARNING: server process is GONE - the remaining runs are meaningless
    )
)

REM -- Summary -----------------------------------------------------------------

echo.
echo ============================================================
echo  %RUNS% runs:  GREEN !GREEN!   RED !RED!
echo ============================================================
if !RED! GTR 0 echo  RED runs: the failing check names the test; the server window has a matching "Task #N raised" line naming the exception. Copy those lines before stopping the server.
if !RED! EQU 0 echo  No red runs. At the old 4-in-10 rate, 10 green in a row is about 0.6 percent likely - check what changed. First suspect: the onRequest hook from PR #12 now routes every request through THorseLifecycleExecutor. Control: rebuild without it and rerun the batch.
echo.
echo  The server is still running in its own window. Press ENTER there to stop it.
echo  Per-run logs: %LOG_DIR%

exit /b !RED!
