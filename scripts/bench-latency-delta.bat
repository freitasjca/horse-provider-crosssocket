@echo off
setlocal enabledelayedexpansion

REM ============================================================================
REM  bench-latency-delta.bat
REM  Measures the per-request latency cost of the middleware by comparing a
REM  bare server vs a middleware server at c=1 (no queueing, no failures).
REM
REM  This script now manages the servers itself: it kills any running bench
REM  servers, launches exactly the bare + middleware pair for the chosen
REM  provider (so nothing else competes), runs the measurement, then stops them.
REM
REM  Method (see bench-analysis-report.md 5.10):
REM    - c=1 isolates per-request server time; everything else (loopback, client
REM      cost, connection setup) is common-mode and cancels in the delta.
REM    - n=100000 gives a stable median. Compare P50, not Avg.
REM    - delta = P50(middleware) - P50(bare) = added per-request time.
REM    - Run on an IDLE box (pause ESET); at c=1 you measure microseconds.
REM
REM  Usage:  bench-latency-delta.bat [indy|crosssocket|mormot]   (default indy)
REM ============================================================================

set BOMB=c:\tools\bombardier\bombardier.exe
set BASE_URL=http://127.0.0.1
set ROUTE=/ping
set CONCURRENCY=1
set REQUESTS=100000
set WARMUP=5000
set RUNS=3

REM -- Provider selection --------------------------------------------------------
set PROVIDER=%~1
if "%PROVIDER%"=="" set PROVIDER=indy

if /I "%PROVIDER%"=="indy" (
    set EXE=HorseBenchIndy.exe
    set BARE_PORT=9001
    set MW_PORT=9011
) else if /I "%PROVIDER%"=="crosssocket" (
    set EXE=HorseBenchCrossSocket.exe
    set BARE_PORT=9002
    set MW_PORT=9012
) else if /I "%PROVIDER%"=="mormot" (
    set EXE=HorseBenchMormot.exe
    set BARE_PORT=9003
    set MW_PORT=9013
) else (
    echo ERROR: unknown provider "%PROVIDER%". Use: indy, crosssocket, or mormot.
    exit /b 1
)

REM -- Auto-detect binary directory ----------------------------------------------
set SERVERS_DIR=
if exist "%~dp0!EXE!"                                              set SERVERS_DIR=%~dp0
if "!SERVERS_DIR!"=="" if exist "%~dp0..\samples\bench\Win64\Release\!EXE!" set SERVERS_DIR=%~dp0..\samples\bench\Win64\Release
if "!SERVERS_DIR!"=="" if exist "%~dp0..\Win64\Release\!EXE!"      set SERVERS_DIR=%~dp0..\Win64\Release
if "!SERVERS_DIR!"=="" (
    echo ERROR: !EXE! not found near this script.
    exit /b 1
)
if not exist "%BOMB%" (
    echo ERROR: bombardier not found at %BOMB%
    exit /b 1
)

set OPTS=-c %CONCURRENCY% --latencies --http1

echo.
echo ================================================================================
echo  Latency delta  -  %PROVIDER%   bare !BARE_PORT!  vs  middleware !MW_PORT!
echo  c=%CONCURRENCY%  n=%REQUESTS%  runs=%RUNS% each
echo  Read P50 only. delta = P50(middleware) - P50(bare) = added per-request time.
echo  Run on an idle box (pause ESET) -- at c=1 you are measuring microseconds.
echo ================================================================================

REM -- Kill any running bench servers, launch only this pair ----------------------
echo.
echo Killing any running bench servers...
for %%E in (HorseBenchIndy.exe HorseBenchCrossSocket.exe HorseBenchMormot.exe HorseBenchRawCrossSocket.exe HorseBenchRawMormot.exe) do (
    taskkill /F /IM %%E >nul 2>&1
)
timeout /t 1 /nobreak >nul

call :LAUNCH !BARE_PORT! ""             bare
call :LAUNCH !MW_PORT!   "--middleware"  middleware

REM -- Warmup (discarded) ---------------------------------------------------------
echo.
echo -- Warmup (discarded) --------------------------------------------------------
"%BOMB%" -c %CONCURRENCY% -n %WARMUP% --http1 %BASE_URL%:!BARE_PORT!%ROUTE% >nul 2>&1
"%BOMB%" -c %CONCURRENCY% -n %WARMUP% --http1 %BASE_URL%:!MW_PORT!%ROUTE%   >nul 2>&1
echo done.

REM -- Measured runs --------------------------------------------------------------
for /L %%R in (1,1,%RUNS%) do (
    echo.
    echo ==================== RUN %%R of %RUNS% ====================
    echo.
    echo -- BARE  port !BARE_PORT! ----------------------------------------------------
    "%BOMB%" %OPTS% -n %REQUESTS% %BASE_URL%:!BARE_PORT!%ROUTE%
    echo.
    echo -- MIDDLEWARE  port !MW_PORT! ------------------------------------------------
    "%BOMB%" %OPTS% -n %REQUESTS% %BASE_URL%:!MW_PORT!%ROUTE%
)

echo.
echo ================================================================================
echo  Done. For each run, subtract: P50(middleware) - P50(bare).
echo  Deltas should be consistent across the %RUNS% runs; if they jump around, the
echo  box was not idle -- stop background load and re-measure.
echo ================================================================================
echo.

REM -- Clean up the two servers ---------------------------------------------------
taskkill /F /IM !EXE! >nul 2>&1

endlocal
goto :eof

REM ============================================================================
REM  :LAUNCH <port> "<args>" <label>  -  start one server, wait for the port
REM ============================================================================
:LAUNCH
    set _PORT=%~1
    set _ARGS=%~2
    set _LABEL=%~3
    echo Launching !_LABEL! on !_PORT! ...
    start /min "" "!SERVERS_DIR!\!EXE!" !_ARGS!
    set _TRIES=0
    :LWAIT
        timeout /t 1 /nobreak >nul
        netstat -ano 2>nul | findstr ":!_PORT! " | findstr /I "LISTENING" >nul 2>&1
        if not errorlevel 1 goto :LUP
        set /a _TRIES+=1
        if !_TRIES! lss 8 goto :LWAIT
    echo   [WARN] !_LABEL! may not have started on !_PORT! -- continuing
    goto :eof
    :LUP
    echo   [OK] !_LABEL! listening on !_PORT!
goto :eof
