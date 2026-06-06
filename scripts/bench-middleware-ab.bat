@echo off
setlocal enabledelayedexpansion

REM ============================================================================
REM  bench-middleware-ab.bat
REM  Localizes which middleware drives the ~60% pre-pipeline 5xx (Issue 1).
REM
REM  Sweeps the SAME provider through five modes, each fully isolated (all other
REM  bench servers killed), at c=100 n=200000, and tabulates the 5xx:
REM    1. bare          (no middleware)
REM    2. guard-only    (RequestGuard only)             --guard-only
REM    3. headers-only  (SecurityHeaders, AddHeader)    --headers-only
REM    4. cors          (Horse.CORS, SetCustomHeader)   --cors
REM    5. both          (RequestGuard + SecurityHeaders) --middleware
REM
REM  Requires the rebuilt bench servers that understand --guard-only /
REM  --headers-only / --cors. All middleware modes listen on the same middleware
REM  port (bare+10); only one server runs at a time, so the shared port is fine.
REM
REM  Verdict logic (>=20% 5xx = "high"):
REM    guard high, headers low   -> RequestGuard is the cause
REM    headers high, guard low   -> SecurityHeaders is the cause
REM    both high individually    -> each contributes independently
REM    only "both" high          -> interaction effect between the two
REM    headers high AND cors high-> whole response-header path (both AddHeader
REM                                 and SetCustomHeader), not one API
REM
REM  Use a RELEASE build. Usage: bench-middleware-ab.bat [indy|crosssocket|mormot]
REM ============================================================================

set BOMB=c:\tools\bombardier\bombardier.exe
set BASE_URL=http://127.0.0.1
set ROUTE=/ping
set CONCURRENCY=100
set REQUESTS=200000
set TMP_OUT=%TEMP%\bench_mwab_out.txt

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
echo  Middleware A/B  -  %PROVIDER%   c=%CONCURRENCY%  n=%REQUESTS%
echo  one server at a time, all others killed -- use a Release build
echo ================================================================================

call :PHASE !BARE_PORT! ""              bare
set S_BARE=!PHASE_5XX!
call :PHASE !MW_PORT!   "--guard-only"   guard-only
set S_GUARD=!PHASE_5XX!
call :PHASE !MW_PORT!   "--headers-only" headers-only
set S_HEAD=!PHASE_5XX!
call :PHASE !MW_PORT!   "--cors"         cors
set S_CORS=!PHASE_5XX!
call :PHASE !MW_PORT!   "--middleware"   both
set S_BOTH=!PHASE_5XX!

set /a P_BARE=!S_BARE!*100/%REQUESTS%
set /a P_GUARD=!S_GUARD!*100/%REQUESTS%
set /a P_HEAD=!S_HEAD!*100/%REQUESTS%
set /a P_CORS=!S_CORS!*100/%REQUESTS%
set /a P_BOTH=!S_BOTH!*100/%REQUESTS%

echo.
echo ================================================================================
echo  RESULT  -  %PROVIDER% isolated, 5xx by mode
echo    bare          : !S_BARE!  (~!P_BARE!%%)
echo    guard-only    : !S_GUARD!  (~!P_GUARD!%%)
echo    headers-only  : !S_HEAD!  (~!P_HEAD!%%)
echo    cors          : !S_CORS!  (~!P_CORS!%%)
echo    both          : !S_BOTH!  (~!P_BOTH!%%)
echo --------------------------------------------------------------------------------
if !P_GUARD! GEQ 20 if !P_HEAD! LSS 20 echo  VERDICT: RequestGuard is the cause ^(guard-only high, headers-only low^).
if !P_HEAD! GEQ 20 if !P_GUARD! LSS 20 echo  VERDICT: SecurityHeaders is the cause ^(headers-only high, guard-only low^).
if !P_GUARD! GEQ 20 if !P_HEAD! GEQ 20 echo  VERDICT: BOTH contribute independently ^(each high on its own^).
if !P_GUARD! LSS 20 if !P_HEAD! LSS 20 if !P_BOTH! GEQ 20 echo  VERDICT: INTERACTION effect ^(neither alone, only the pair triggers it^).
if !P_GUARD! LSS 20 if !P_HEAD! LSS 20 if !P_BOTH! LSS 20 if !P_CORS! LSS 20 echo  VERDICT: no mode sheds heavily -- could not reproduce this run.
if !P_HEAD! GEQ 20 if !P_CORS! GEQ 20 echo  NOTE: headers-only ^(AddHeader^) AND cors ^(SetCustomHeader^) both high -> whole response-header path, not one API.
echo ================================================================================
echo.

del "%TMP_OUT%" >nul 2>&1
endlocal
goto :eof

REM ============================================================================
REM  :PHASE <port> "<args>" <label>  ->  sets PHASE_5XX (and prints 2xx/5xx)
REM ============================================================================
:PHASE
    set _PORT=%~1
    set _ARGS=%~2
    set _LABEL=%~3
    set PHASE_2XX=0
    set PHASE_5XX=0

    echo.
    echo -- Phase: !_LABEL!  port !_PORT!  args "!_ARGS!" -----------------------------
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
    if "!PHASE_2XX!"==""  set PHASE_2XX=0
    if "!PHASE_5XX!"==""  set PHASE_5XX=0

    echo   done: 2xx=!PHASE_2XX!  5xx=!PHASE_5XX!
    taskkill /F /IM !EXE! >nul 2>&1
goto :eof
