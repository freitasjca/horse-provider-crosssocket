@echo off
setlocal enabledelayedexpansion

REM ============================================================================
REM  bench-concurrency-sweep.bat
REM  Characterizes the ONSET of the header-middleware + keep-alive 5xx defect
REM  (bench-analysis-report.md 5.13). Runs ONE isolated header-middleware server
REM  and sweeps bombardier concurrency, reporting the 5xx rate at each level.
REM
REM  Expectation: ~0% at low concurrency, rising to ~60% as c increases -- the
REM  curve shows where the race turns on.
REM
REM  Each level uses a fixed DURATION (not a fixed count) so low-concurrency
REM  levels do not take disproportionately long. 5xx rate = 5xx / (2xx + 5xx).
REM
REM  Uses --headers-only (SecurityHeaders, the isolated culprit). Use a Release
REM  build. Usage: bench-concurrency-sweep.bat [indy|crosssocket|mormot]
REM ============================================================================

set BOMB=c:\tools\bombardier\bombardier.exe
set BASE_URL=http://127.0.0.1
set ROUTE=/ping
set DURATION=20s
set LEVELS=1 5 10 20 40 60 80 100
set MODE_ARG=--headers-only
set TMP_OUT=%TEMP%\bench_sweep_out.txt

set PROVIDER=%~1
if "%PROVIDER%"=="" set PROVIDER=indy

if /I "%PROVIDER%"=="indy" (
    set EXE=HorseBenchIndy.exe
    set MW_PORT=9011
) else if /I "%PROVIDER%"=="crosssocket" (
    set EXE=HorseBenchCrossSocket.exe
    set MW_PORT=9012
) else if /I "%PROVIDER%"=="mormot" (
    set EXE=HorseBenchMormot.exe
    set MW_PORT=9013
) else (
    echo ERROR: unknown provider "%PROVIDER%". Use: indy, crosssocket, or mormot.
    exit /b 1
)

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

echo.
echo ================================================================================
echo  Concurrency sweep  -  %PROVIDER%  %MODE_ARG%  port !MW_PORT!
echo  duration=%DURATION% per level   levels: %LEVELS%
echo ================================================================================

REM -- Isolate: kill all bench servers, start the one under test ------------------
echo.
echo Killing other bench servers and starting !EXE! %MODE_ARG% ...
for %%E in (HorseBenchIndy.exe HorseBenchCrossSocket.exe HorseBenchMormot.exe HorseBenchRawCrossSocket.exe HorseBenchRawMormot.exe) do (
    taskkill /F /IM %%E >nul 2>&1
)
timeout /t 1 /nobreak >nul
start /min "" "!SERVERS_DIR!\!EXE!" %MODE_ARG%

set _TRIES=0
:WAIT
    timeout /t 1 /nobreak >nul
    netstat -ano 2>nul | findstr ":!MW_PORT! " | findstr /I "LISTENING" >nul 2>&1
    if not errorlevel 1 goto :UP
    set /a _TRIES+=1
    if !_TRIES! lss 8 goto :WAIT
echo ERROR: server did not listen on !MW_PORT! within 8s.
exit /b 1
:UP
echo   [OK] listening.

echo.
echo   c     2xx        5xx        5xx%%
echo   ----  ---------  ---------  -----
for %%C in (%LEVELS%) do call :LEVEL %%C

echo.
echo ================================================================================
echo  Sweep complete. Look for the concurrency at which 5xx%% jumps from ~0 to high.
echo ================================================================================
echo.

taskkill /F /IM !EXE! >nul 2>&1
del "%TMP_OUT%" >nul 2>&1
endlocal
goto :eof

REM ============================================================================
REM  :LEVEL <concurrency>  -  one bombardier run, parse + print a table row
REM ============================================================================
:LEVEL
    set _C=%~1
    "%BOMB%" -c %_C% -d %DURATION% --http1 %BASE_URL%:!MW_PORT!%ROUTE% > "%TMP_OUT%" 2>&1
    set _2XX=0
    set _5XX=0
    for /f "tokens=2 delims=," %%a in ('findstr /C:"5xx -" "%TMP_OUT%"') do for /f "tokens=3 delims= " %%b in ("%%a") do set _2XX=%%b
    for /f "tokens=5 delims=," %%a in ('findstr /C:"5xx -" "%TMP_OUT%"') do for /f "tokens=3 delims= " %%b in ("%%a") do set _5XX=%%b
    if "!_2XX!"=="" set _2XX=0
    if "!_5XX!"=="" set _5XX=0
    set /a _TOT=!_2XX!+!_5XX!
    if !_TOT! LSS 1 set _TOT=1
    set /a _PCT=!_5XX!*100/!_TOT!
    REM right-pad-ish columns
    set "_cP=%_C%   "
    set "_2P=!_2XX!          "
    set "_5P=!_5XX!          "
    echo   !_cP:~0,4!  !_2P:~0,9!  !_5P:~0,9!  !_PCT!%%
goto :eof
