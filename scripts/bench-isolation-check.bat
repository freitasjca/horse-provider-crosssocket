@echo off
setlocal enabledelayedexpansion

REM ============================================================================
REM  bench-isolation-check.bat
REM  A/B control for bench-analysis-report.md Issue 1.
REM
REM  Runs the SAME provider twice, each fully isolated (all other bench servers
REM  killed), at c=100 n=200000:
REM    Phase 1: BARE       server  (no middleware)
REM    Phase 2: MIDDLEWARE server  (RequestGuard + SecurityHeaders)
REM  then compares the 5xx counts. The DIFFERENCE is the decisive signal:
REM    bare ~ mw (both high)  -> box/build problem (NOT middleware)
REM    bare low, mw high      -> middleware genuinely triggers the shedding
REM    both low               -> healthy; earlier high 5xx was contention
REM
REM  NOTE: if these are Win64\Debug binaries, range/overflow checks are ON and
REM  results are not representative. Re-run with a Release build before drawing
REM  final conclusions.
REM
REM  Usage:  bench-isolation-check.bat [indy|crosssocket|mormot]   (default indy)
REM ============================================================================

set BOMB=c:\tools\bombardier\bombardier.exe
set BASE_URL=http://127.0.0.1
set ROUTE=/ping
set CONCURRENCY=100
set REQUESTS=200000
set TMP_OUT=%TEMP%\bench_iso_out.txt

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
echo  Isolation A/B  -  %PROVIDER%   bare !BARE_PORT!  vs  middleware !MW_PORT!
echo  c=%CONCURRENCY%  n=%REQUESTS%   (one server at a time, all others killed)
echo ================================================================================

REM -- Phase 1: BARE --------------------------------------------------------------
call :PHASE !BARE_PORT! "" BARE
set BARE_2XX=!PHASE_2XX!
set BARE_5XX=!PHASE_5XX!
set BARE_OTH=!PHASE_OTH!

REM -- Phase 2: MIDDLEWARE --------------------------------------------------------
call :PHASE !MW_PORT! "--middleware" MIDDLEWARE
set MW_2XX=!PHASE_2XX!
set MW_5XX=!PHASE_5XX!
set MW_OTH=!PHASE_OTH!

REM -- Compare --------------------------------------------------------------------
set /a BPCT=!BARE_5XX!*100/%REQUESTS%
set /a MPCT=!MW_5XX!*100/%REQUESTS%

echo.
echo ================================================================================
echo  RESULT  -  %PROVIDER% isolated, c=%CONCURRENCY%
echo    BARE       5xx : !BARE_5XX!  (~!BPCT!%%)   2xx !BARE_2XX!  refused !BARE_OTH!
echo    MIDDLEWARE 5xx : !MW_5XX!  (~!MPCT!%%)   2xx !MW_2XX!  refused !MW_OTH!
echo --------------------------------------------------------------------------------
if !BPCT! GEQ 20 (
    echo  VERDICT: BARE also sheds heavily in isolation. NOT a middleware problem --
    echo           the box/build saturates a single server at c=100. Suspect the
    echo           Debug build first; re-run with Release.
) else if !MPCT! GEQ 20 (
    echo  VERDICT: BARE is fine but MIDDLEWARE sheds heavily, even isolated.
    echo           Middleware genuinely triggers pre-pipeline shedding. Run the
    echo           _diag build to capture where, and confirm on a Release build.
) else (
    echo  VERDICT: both bare and middleware healthy in isolation. Earlier high 5xx
    echo           was multi-server contention after all.
)
echo ================================================================================
echo.

del "%TMP_OUT%" >nul 2>&1
endlocal
goto :eof

REM ============================================================================
REM  :PHASE <port> "<extra-args>" <label>
REM  Kills all bench servers, starts EXE with extra-args, loads it, parses
REM  2xx/5xx/others into PHASE_2XX / PHASE_5XX / PHASE_OTH.
REM ============================================================================
:PHASE
    set _PORT=%~1
    set _ARGS=%~2
    set _LABEL=%~3
    set PHASE_2XX=0
    set PHASE_5XX=0
    set PHASE_OTH=0

    echo.
    echo -- Phase: !_LABEL!  port !_PORT! ---------------------------------------------
    for %%E in (HorseBenchIndy.exe HorseBenchCrossSocket.exe HorseBenchMormot.exe HorseBenchRawCrossSocket.exe HorseBenchRawMormot.exe) do (
        taskkill /F /IM %%E >nul 2>&1
    )
    timeout /t 1 /nobreak >nul

    start /min "" "!SERVERS_DIR!\!EXE!" !_ARGS!

    set _TRIES=0
    :PWAIT
        timeout /t 1 /nobreak >nul
        netstat -ano 2>nul | findstr ":!_PORT! " | findstr /I "LISTENING" >nul 2>&1
        if not errorlevel 1 goto :PUP
        set /a _TRIES+=1
        if !_TRIES! lss 8 goto :PWAIT
    echo   ERROR: server did not listen on !_PORT! within 8s.
    goto :eof
    :PUP
    echo   [OK] listening; loading...

    "%BOMB%" -c %CONCURRENCY% -n %REQUESTS% --http1 %BASE_URL%:!_PORT!%ROUTE% > "%TMP_OUT%" 2>&1

    for /f "tokens=2 delims=," %%a in ('findstr /C:"5xx -" "%TMP_OUT%"') do for /f "tokens=3 delims= " %%b in ("%%a") do set PHASE_2XX=%%b
    for /f "tokens=5 delims=," %%a in ('findstr /C:"5xx -" "%TMP_OUT%"') do for /f "tokens=3 delims= " %%b in ("%%a") do set PHASE_5XX=%%b
    for /f "tokens=3 delims= " %%a in ('findstr /C:"others -" "%TMP_OUT%"') do set PHASE_OTH=%%a
    if "!PHASE_2XX!"==""  set PHASE_2XX=0
    if "!PHASE_5XX!"==""  set PHASE_5XX=0
    if "!PHASE_OTH!"==""  set PHASE_OTH=0

    echo   done: 2xx=!PHASE_2XX!  5xx=!PHASE_5XX!  refused=!PHASE_OTH!
    taskkill /F /IM !EXE! >nul 2>&1
goto :eof
