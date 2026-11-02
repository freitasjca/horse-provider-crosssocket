@echo off
setlocal enabledelayedexpansion

REM ============================================================================
REM  bench-h2.bat
REM  The ONE load generator for both protocols. h2load speaks HTTP/1.1 (--h1)
REM  AND h2/h2c, so client-side cost is held constant and only the server
REM  protocol varies -- which is the whole point, because bombardier-vs-h2load
REM  would make the CLIENT the variable (see plans/bench-plan-all-providers.md).
REM
REM    nghttp2        -> HTTP/2 cleartext (h2c), driven natively      (port 9041)
REM    Indy/CrossSocket/mORMot/ICS -> HTTP/1.1, driven with --h1      (9001/9002/9003/9009)
REM
REM  Two scenarios, both from the plan:
REM    S1  Floor        -c 10  -m 1     one request in flight per connection.
REM                                     Like-for-like with HTTP/1.1 keep-alive.
REM                                     HTTP/2 is EXPECTED to lose here (framing,
REM                                     HPACK, per-stream state) -- that is protocol
REM                                     cost, not a defect.
REM    S4  Multiplexing h2: -c 10 -m 100 (1000 in flight over 10 sockets)
REM                     h1: -c 1000      (1000 in flight over 1000 sockets)
REM                                     SAME 1000 requests in flight, different
REM                                     transport shapes. The scenario HTTP/2
REM                                     exists for.
REM
REM  NEVER collapse these to a single "winner". The report is a winner PER
REM  workload class. A trivial-route req/s ranking measures the wrong thing.
REM
REM  Usage:  bench-h2.bat [n] [scenario]
REM            n         requests per cell        (default 200000)
REM            scenario  s1 | s4 | all            (default all)
REM
REM  Prereqs: RELEASE builds of HorseBenchIndy/CrossSocket/mORMot/ICS/Nghttp2;
REM           h2load on PATH or at %H2LOAD%; libnghttp2 runtime for the nghttp2
REM           server (nghttp2.dll on PATH). Idle box, High Performance power plan.
REM           Pin the nghttp2 dispatch pool for a published run: set WORKERS=N
REM           below (auto-sizing means comparing different configurations).
REM ============================================================================

set H2LOAD=c:\tools\h2load\h2load.exe
set BASE_URL=http://127.0.0.1
set ROUTE=/ping
set REQUESTS=200000
set SCENARIO=all
set WORKERS=0
if not "%~1"=="" set REQUESTS=%~1
if not "%~2"=="" set SCENARIO=%~2

REM nghttp2 dispatch: WORKERS>0 pins the pool; 0 = auto (warned). --inline is the
REM no-pool mode for an A/B, add it to NGHTTP2_ARGS if you want it.
set NGHTTP2_ARGS=
if %WORKERS% GTR 0 set NGHTTP2_ARGS=--workers=%WORKERS%

REM -- locate the servers directory (same probing as the other bench scripts) --
set SERVERS_DIR=
if exist "%~dp0HorseBenchNghttp2.exe"                                           set SERVERS_DIR=%~dp0
if "!SERVERS_DIR!"=="" if exist "%~dp0..\samples\bench\Win64\Release\HorseBenchNghttp2.exe" set SERVERS_DIR=%~dp0..\samples\bench\Win64\Release
if "!SERVERS_DIR!"=="" if exist "%~dp0..\Win64\Release\HorseBenchNghttp2.exe"    set SERVERS_DIR=%~dp0..\Win64\Release
if "!SERVERS_DIR!"=="" if exist "%~dp0..\..\bin\Win64\Release\HorseBenchNghttp2.exe" set SERVERS_DIR=%~dp0..\..\bin\Win64\Release
if "!SERVERS_DIR!"=="" (
    echo ERROR: HorseBenchNghttp2.exe not found near this script. Build the bench
    echo        servers Release ^(scripts\build.bat^) and the new Nghttp2 server first.
    exit /b 1
)
if not exist "%H2LOAD%" (
    where h2load >nul 2>&1 && set H2LOAD=h2load
)
if not exist "%H2LOAD%" if /I not "%H2LOAD%"=="h2load" (
    echo ERROR: h2load not found at %H2LOAD% and not on PATH.
    echo        h2load ships with nghttp2 ^(https://github.com/nghttp2/nghttp2^).
    exit /b 1
)

set RESULTS=%~dp0bench-h2-result.txt
set TMP_OUT=%TEMP%\bench_h2_out.txt
> "%RESULTS%" echo Horse HTTP/2-vs-HTTP/1.1 bench (h2load)   n=%REQUESTS%  scenario=%SCENARIO%
>>"%RESULTS%" echo Generated %DATE% %TIME%
>>"%RESULTS%" echo nghttp2 speaks HTTP/2 (h2c); all others HTTP/1.1 (--h1). NOT a single ranking.

echo.
echo ================================================================================
echo  bench-h2   n=%REQUESTS%   scenario=%SCENARIO%
echo  h2load drives everything; nghttp2=h2c, others=--h1. One server at a time.
echo ================================================================================

if /I "%SCENARIO%"=="s1"  goto :S1
if /I "%SCENARIO%"=="s4"  goto :S4
if /I "%SCENARIO%"=="all" goto :S1
echo ERROR: scenario must be s1, s4, or all.
exit /b 1

:S1
echo.
echo -- S1 Floor  (-c 10 -m 1)  one request in flight per connection --------------
>>"%RESULTS%" echo.
>>"%RESULTS%" echo == S1 Floor  -c 10 -m 1  n=%REQUESTS% ==
call :CELL HorseBenchIndy.exe        9001 h1 ""              "-c 10"           "Indy"
call :CELL HorseBenchCrossSocket.exe 9002 h1 ""              "-c 10"           "CrossSocket"
call :CELL HorseBenchMormot.exe      9003 h1 ""              "-c 10"           "mORMot"
call :CELL HorseBenchICS.exe         9009 h1 ""              "-c 10"           "ICS"
call :CELL HorseBenchNghttp2.exe     9041 h2 "%NGHTTP2_ARGS%" "-c 10 -m 1"     "nghttp2"
if /I "%SCENARIO%"=="s1" goto :DONE

:S4
echo.
echo -- S4 Multiplexing  (1000 in flight: h2 10x100, h1 1000x1) -------------------
>>"%RESULTS%" echo.
>>"%RESULTS%" echo == S4 Multiplexing  1000 in flight  n=%REQUESTS% ==
call :CELL HorseBenchIndy.exe        9001 h1 ""              "-c 1000"         "Indy"
call :CELL HorseBenchCrossSocket.exe 9002 h1 ""              "-c 1000"         "CrossSocket"
call :CELL HorseBenchMormot.exe      9003 h1 ""              "-c 1000"         "mORMot"
call :CELL HorseBenchICS.exe         9009 h1 ""              "-c 1000"         "ICS"
call :CELL HorseBenchNghttp2.exe     9041 h2 "%NGHTTP2_ARGS%" "-c 10 -m 100"   "nghttp2"

:DONE
echo.
echo ================================================================================
echo  Done. Full h2load output per cell saved to: %RESULTS%
echo  Read it PER SCENARIO. nghttp2 is HTTP/2; the rest are HTTP/1.1. S1 favours
echo  HTTP/1.1 by construction; S4 is where multiplexing is allowed to pay.
echo ================================================================================
del "%TMP_OUT%" >nul 2>&1
endlocal
goto :eof

REM ============================================================================
REM  :CELL <exe> <port> <h1|h2> "<server-args>" "<h2load-conn-args>" <label>
REM  Kills all bench servers, starts <exe>, waits for <port>, runs h2load
REM  (adding --h1 for the h1 cells), prints + logs the key summary lines.
REM ============================================================================
:CELL
    set _EXE=%~1
    set _PORT=%~2
    set _PROTO=%~3
    set _SRVARGS=%~4
    set _LOADARGS=%~5
    set _LABEL=%~6

    for %%E in (HorseBenchIndy.exe HorseBenchCrossSocket.exe HorseBenchMormot.exe HorseBenchICS.exe HorseBenchNghttp2.exe) do (
        taskkill /F /IM %%E >nul 2>&1
    )
    timeout /t 1 /nobreak >nul

    if not exist "!SERVERS_DIR!\!_EXE!" (
        echo   [ERR]  %_LABEL% (%_PROTO%)  binary not found: !SERVERS_DIR!\!_EXE!
        >>"%RESULTS%" echo [ERR] %_LABEL% (%_PROTO%) binary not found
        goto :eof
    )
    start /min "" "!SERVERS_DIR!\!_EXE!" !_SRVARGS!

    set _TRIES=0
    :H2WAIT
        timeout /t 1 /nobreak >nul
        netstat -ano 2>nul | findstr ":!_PORT! " | findstr /I "LISTENING" >nul 2>&1
        if not errorlevel 1 goto :H2UP
        set /a _TRIES+=1
        if !_TRIES! lss 10 goto :H2WAIT
    echo   [ERR]  %_LABEL% (%_PROTO%)  port !_PORT! never came up
    >>"%RESULTS%" echo [ERR] %_LABEL% (%_PROTO%) port !_PORT! never came up
    goto :eof
    :H2UP

    set _H1=
    if /I "%_PROTO%"=="h1" set _H1=--h1

    echo.
    echo   -- %_LABEL%  proto=%_PROTO%  port !_PORT!  (%_LOADARGS% -n %REQUESTS%) --
    >>"%RESULTS%" echo.
    >>"%RESULTS%" echo -- %_LABEL%  proto=%_PROTO%  port !_PORT!  !_H1! %_LOADARGS% -n %REQUESTS% --
    "%H2LOAD%" !_H1! %_LOADARGS% -n %REQUESTS% %BASE_URL%:!_PORT!%ROUTE% > "%TMP_OUT%" 2>&1

    REM Echo the lines that matter; append the FULL output to the results file.
    for /f "delims=" %%L in ('findstr /C:"finished in" /C:"requests:" /C:"status codes:" /C:"time for request" "%TMP_OUT%"') do echo       %%L
    type "%TMP_OUT%" >> "%RESULTS%"

    taskkill /F /IM !_EXE! >nul 2>&1
goto :eof
