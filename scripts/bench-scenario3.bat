@echo off
setlocal enabledelayedexpansion

REM -- Scenario 3: GET /ping  |  c=500  |  n=500000 -----------------------------
REM bench-plan.md Sec.Scenarios row 3
REM
REM NOTE: c=500 is a high-concurrency stress run. Indy will open 500 OS threads
REM       per connection - expect latency spikes and potential timeouts on the
REM       Indy ports (9001/9011). This is intentional: it exposes where the
REM       thread-per-connection model breaks down vs IOCP/epoll providers.

REM -- Configuration -------------------------------------------------------------
set BOMB=c:\tools\bombardier\bombardier.exe

REM -- Auto-detect binary directory ----------------------------------------------
REM Tries, in order: same folder as this script, then two common msbuild layouts.
set SERVERS_DIR=
if exist "%~dp0HorseBenchIndy.exe"                                                        set SERVERS_DIR=%~dp0
if "!SERVERS_DIR!"=="" if exist "%~dp0..\samples\bench\Win64\Release\HorseBenchIndy.exe"  set SERVERS_DIR=%~dp0..\samples\bench\Win64\Release
if "!SERVERS_DIR!"=="" if exist "%~dp0..\Win64\Release\HorseBenchIndy.exe"                set SERVERS_DIR=%~dp0..\Win64\Release
if "!SERVERS_DIR!"=="" (
    echo [ERROR] Bench server binaries not found. Looked in:
    echo           %~dp0
    echo           %~dp0..\samples\bench\Win64\Release
    echo           %~dp0..\Win64\Release
    echo         Run scripts\build.bat first, or copy binaries to one of those folders.
    exit /b 1
)
echo [info]  Binaries: !SERVERS_DIR!

set BASE_URL=http://127.0.0.1
set ROUTE=/ping
set CONCURRENCY=500
set REQUESTS=500000
set OPTS=--print r --latencies --http1

REM -- Pre-flight -----------------------------------------------------------------
if not exist "%BOMB%" (
    echo ERROR: bombardier not found at %BOMB%
    exit /b 1
)

echo.
echo ================================================================================
echo  Scenario 3 - GET /ping   c=%CONCURRENCY%   n=%REQUESTS%
echo  WARNING: c=500 stresses the thread-per-connection model (Indy ports).
echo ================================================================================

REM -- Ensure all 8 server ports are listening ------------------------------------
echo.
echo Killing any running bench servers for a clean state...
for %%E in (HorseBenchIndy.exe HorseBenchCrossSocket.exe HorseBenchMormot.exe HorseBenchRawCrossSocket.exe HorseBenchRawMormot.exe) do (
    taskkill /F /IM %%E >/dev/null 2>&1
)
timeout /t 1 /nobreak >nul
echo Launching the servers this scenario needs...
call :CHECK_PORT 9001 HorseBenchIndy.exe
call :CHECK_PORT 9002 HorseBenchCrossSocket.exe
call :CHECK_PORT 9003 HorseBenchMormot.exe
call :CHECK_PORT 9004 HorseBenchRawCrossSocket.exe
call :CHECK_PORT 9005 HorseBenchRawMormot.exe
call :CHECK_PORT 9011 HorseBenchIndy.exe --middleware
call :CHECK_PORT 9012 HorseBenchCrossSocket.exe --middleware
call :CHECK_PORT 9013 HorseBenchMormot.exe --middleware

REM -- Benchmark runs -------------------------------------------------------------
echo.
echo -- [1/8] Horse + Indy  (bare)  port 9001 ------------------------------------
"%BOMB%" -c %CONCURRENCY% -n %REQUESTS% %OPTS% %BASE_URL%:9001%ROUTE%

echo.
echo -- [2/8] Horse + CrossSocket  (bare)  port 9002 -----------------------------
"%BOMB%" -c %CONCURRENCY% -n %REQUESTS% %OPTS% %BASE_URL%:9002%ROUTE%

echo.
echo -- [3/8] Horse + mORMot  (bare)  port 9003 ----------------------------------
"%BOMB%" -c %CONCURRENCY% -n %REQUESTS% %OPTS% %BASE_URL%:9003%ROUTE%

echo.
echo -- [4/8] Raw CrossSocket  (no Horse)  port 9004 -----------------------------
"%BOMB%" -c %CONCURRENCY% -n %REQUESTS% %OPTS% %BASE_URL%:9004%ROUTE%

echo.
echo -- [5/8] Raw mORMot  (no Horse)  port 9005 ----------------------------------
"%BOMB%" -c %CONCURRENCY% -n %REQUESTS% %OPTS% %BASE_URL%:9005%ROUTE%

echo.
echo -- [6/8] Horse + Indy  (middleware)  port 9011 ------------------------------
"%BOMB%" -c %CONCURRENCY% -n %REQUESTS% %OPTS% %BASE_URL%:9011%ROUTE%

echo.
echo -- [7/8] Horse + CrossSocket  (middleware)  port 9012 -----------------------
"%BOMB%" -c %CONCURRENCY% -n %REQUESTS% %OPTS% %BASE_URL%:9012%ROUTE%

echo.
echo -- [8/8] Horse + mORMot  (middleware)  port 9013 ----------------------------
"%BOMB%" -c %CONCURRENCY% -n %REQUESTS% %OPTS% %BASE_URL%:9013%ROUTE%

echo.
echo ================================================================================
echo  Scenario 3 complete.
echo ================================================================================
echo.

endlocal
goto :eof

REM -- Subroutine: CHECK_PORT ----------------------------------------------------
:CHECK_PORT
    set _PORT=%~1
    set _EXE=%~2
    set _ARGS=%~3
    netstat -ano 2>nul | findstr ":%_PORT% " | findstr /I "LISTENING" >nul 2>&1
    if not errorlevel 1 (
        echo   [OK]   port %_PORT%  %_EXE% %_ARGS%  -- already listening
        goto :eof
    )
    if not exist "%SERVERS_DIR%\%_EXE%" (
        echo   [ERR]  port %_PORT%  binary not found: %SERVERS_DIR%\%_EXE%
        goto :eof
    )
    echo   [--]   port %_PORT%  launching %_EXE% %_ARGS%
    start /min "" "%SERVERS_DIR%\%_EXE%" %_ARGS%
    set _TRIES=0
    :WAIT_LOOP
        timeout /t 1 /nobreak >nul
        netstat -ano 2>nul | findstr ":%_PORT% " | findstr /I "LISTENING" >nul 2>&1
        if not errorlevel 1 goto :PORT_UP
        set /a _TRIES+=1
        if %_TRIES% lss 5 goto :WAIT_LOOP
    echo   [WARN] port %_PORT%  %_EXE% may not have started -- continuing anyway
    goto :eof
    :PORT_UP
    echo   [OK]   port %_PORT%  %_EXE% %_ARGS%  -- now listening
goto :eof
