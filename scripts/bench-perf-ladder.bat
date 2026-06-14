@echo off
setlocal enabledelayedexpansion

REM ============================================================================
REM  bench-perf-ladder.bat
REM  Establishes the performance cost by layer in ONE pass, cleanly:
REM    raw transport (no Horse)  ->  Horse bare  ->  Horse + header middleware
REM  across all three providers, at c=100, with ZERO 500s.
REM
REM  Why this script exists: a naive RPS comparison is misleading because, on
REM  Indy, header middleware + keep-alive + c>=40 sheds ~60% as instant HTTP 500
REM  (EWebBrokerException, the WebBroker MaxConnections=32 cap). Those fast
REM  failures INFLATE RPS and invalidate the comparison. This script passes
REM  --maxconn 256 to every Horse server so the cap is lifted and every request
REM  does real work (0 5xx) -- the RPS then reflects true throughput.
REM
REM  Tiers measured (one server at a time, all others killed), RUNS averaged:
REM    raw-mormot     bare / +headers / (async ×2) / (httpapi ×2)  (HorseBenchRawMormot, 9005)
REM      NOTE: the (httpapi) rows use Windows http.sys and need this script run as
REM      Administrator, OR a one-time per-port urlacl, e.g.:
REM        netsh http add urlacl url=http://+:9003/ user=Everyone
REM        netsh http add urlacl url=http://+:9005/ user=Everyone
REM        netsh http add urlacl url=http://+:9013/ user=Everyone
REM      Without it the (httpapi) cells report ERR/noListen and can be ignored.
REM    raw-crosssock  bare / +headers          (HorseBenchRawCrossSocket, 9004)
REM    Horse+Indy        bare / +headers / +cors   (9001 / 9011)
REM    Horse+CrossSocket bare / +headers / +cors   (9002 / 9012)
REM    Horse+mORMot      bare / +headers / +cors   (9003 / 9013)
REM    Horse+mORMot      bare / +headers (async)   (THttpAsyncServer via --async)
REM    Horse+mORMot      bare / +headers (httpapi) (http.sys via --httpapi; see urlacl note)
REM
REM  Output: a table (console + bench-perf-ladder-result.txt) with, per tier,
REM  the averaged Reqs/sec plus the last run's 2xx / 5xx / others and the full
REM  latency distribution P50 / P75 / P90 / P95 / P99.
REM
REM  Read it: take "raw-mormot bare" as the ceiling. row_RPS / ceiling = fraction
REM  retained; (ceiling - row) / ceiling = loss introduced up to that layer.
REM
REM  PREREQS: RELEASE builds rebuilt with the --maxconn flag; bombardier present;
REM  idle box; High Performance power plan. Use correctly-built CrossSocket /
REM  mORMot binaries (verify "Active provider class" at startup is NOT Indy).
REM
REM  Usage: bench-perf-ladder.bat [c] [n] [runs] [maxconn] [listenqueue]
REM           c           concurrent connections    (default 100)
REM           n           total requests per cell   (default 200000)
REM           runs        runs averaged per cell    (default 3)
REM           maxconn     THorse.MaxConnections      (default = max(256, 2*c))
REM           listenqueue THorse.ListenQueue (Indy)  (default = max(200, 2*c))
REM         maxconn AND listenqueue AUTO-SCALE from c so high-c runs stay clean on Indy
REM         (Indy needs MaxConnections >= c, ListenQueue >= c). Pass args 4/5 only to
REM         override. Each run writes its own file: bench-perf-ladder-c<c>-n<n>.txt
REM
REM  Examples:
REM    bench-perf-ladder.bat                 :: c=100  n=200000 (maxconn 256, queue 200)
REM    bench-perf-ladder.bat 200             :: c=200           (maxconn 400, queue 400)
REM    bench-perf-ladder.bat 500             :: c=500           (maxconn 1000, queue 1000)
REM    bench-perf-ladder.bat 200 500000      :: c=200  n=500000
REM    bench-perf-ladder.bat 100 200000 3 256 200  :: explicit maxconn/listenqueue
REM  Sweep several concurrencies (from the cmd prompt, one ladder each):
REM    for %c in (10 28 56 100 200 500) do bench-perf-ladder.bat %c
REM    (inside a .bat file double the percent: for %%c in (...) do ...)
REM ============================================================================

set BOMB=c:\tools\bombardier\bombardier.exe
set BASE_URL=http://127.0.0.1
set ROUTE=/ping
REM -- defaults; override via positional args:  bench-perf-ladder.bat [c] [n] [runs] [maxconn]
set CONCURRENCY=100
set REQUESTS=200000
set RUNS=3
if not "%~1"=="" set CONCURRENCY=%~1
if not "%~2"=="" set REQUESTS=%~2
if not "%~3"=="" set RUNS=%~3

REM Basic numeric guard (init to 0 first so a non-numeric arg can't leave it empty).
set _CCHK=0
set _NCHK=0
set /a _CCHK=CONCURRENCY 2>nul
set /a _NCHK=REQUESTS 2>nul
if !_CCHK! LSS 1 ( echo ERROR: c must be a positive integer ^(got "%~1"^). & exit /b 1 )
if !_NCHK! LSS 1 ( echo ERROR: n must be a positive integer ^(got "%~2"^). & exit /b 1 )

REM Caps AUTO-SCALE from c (so high-c runs stay clean) unless overridden by args 4/5:
REM   MaxConnections = 2*c  (floor 256)   -> must be >= c, else Indy HTTP 500
REM   ListenQueue    = 2*c  (floor 200)   -> must be >= c burst, else Indy "others" refusals
set /a MAXCONN=2*CONCURRENCY
if !MAXCONN! LSS 256 set MAXCONN=256
set /a LISTENQ=2*CONCURRENCY
if !LISTENQ! LSS 200 set LISTENQ=200
if not "%~4"=="" set MAXCONN=%~4
if not "%~5"=="" set LISTENQ=%~5

REM Warm-up size (discarded run before the measured runs) = 10*c, floor 2000.
REM Warms the accept loop / thread pool so the first measured burst at c lands on a
REM ready server -- removes the intermittent connection-refusal artifact at high c
REM (notably mORMot, whose listen backlog is not raised by --listenqueue).
set /a WARMUP_N=10*CONCURRENCY
if !WARMUP_N! LSS 2000 set WARMUP_N=2000

set TMP_OUT=%TEMP%\bench_ladder_out.txt
REM Per-parameterisation result file, so sweeps (different c/n) do not clobber each other.
set RESULTS=%~dp0bench-perf-ladder-c%CONCURRENCY%-n%REQUESTS%.txt

REM -- locate the servers directory (same probing as the other bench scripts) --
set SERVERS_DIR=
if exist "%~dp0HorseBenchIndy.exe"                                          set SERVERS_DIR=%~dp0
if "!SERVERS_DIR!"=="" if exist "%~dp0..\samples\bench\Win64\Release\HorseBenchIndy.exe" set SERVERS_DIR=%~dp0..\samples\bench\Win64\Release
if "!SERVERS_DIR!"=="" if exist "%~dp0..\Win64\Release\HorseBenchIndy.exe"   set SERVERS_DIR=%~dp0..\Win64\Release
if "!SERVERS_DIR!"=="" (
    echo ERROR: HorseBench servers not found near this script.
    exit /b 1
)
if not exist "%BOMB%" (
    echo ERROR: bombardier not found at %BOMB%
    exit /b 1
)

> "%RESULTS%" echo Horse performance ladder   c=%CONCURRENCY%  n=%REQUESTS%  runs=%RUNS%  maxconn=%MAXCONN%  listenqueue=%LISTENQ%
>>"%RESULTS%" echo Generated %DATE% %TIME%

echo.
echo ================================================================================
echo  Performance ladder   c=%CONCURRENCY%  n=%REQUESTS%  runs=%RUNS%  maxconn=%MAXCONN%  listenqueue=%LISTENQ%
echo  One server at a time. Horse servers get --maxconn %MAXCONN% --listenqueue %LISTENQ% (Indy clean).
echo  Each cell: 1 discarded warm-up (-n %WARMUP_N%) then %RUNS% measured runs averaged.
echo  Use RELEASE builds, an idle box, and the High Performance power plan.
echo ================================================================================
echo.
call :HEADERROW

call :CELL HorseBenchRawMormot.exe       9005 ""                                   "raw-mormot bare"
call :CELL HorseBenchRawMormot.exe       9005 "--headers"                          "raw-mormot +headers"
REM raw-mormot async backend (THttpAsyncServer) -- transport baseline for the async A/B
call :CELL HorseBenchRawMormot.exe       9005 "--async"                            "raw-mormot bare (async)"
call :CELL HorseBenchRawMormot.exe       9005 "--async --headers"                  "raw-mormot +headers (async)"
REM raw-mormot http.sys backend (THttpApiServer) -- needs admin OR a urlacl for :9005
REM   netsh http add urlacl url=http://+:9005/ user=Everyone
call :CELL HorseBenchRawMormot.exe       9005 "--httpapi"                          "raw-mormot bare (httpapi)"
call :CELL HorseBenchRawMormot.exe       9005 "--httpapi --headers"                "raw-mormot +headers (httpapi)"
call :CELL HorseBenchRawCrossSocket.exe  9004 ""                                   "raw-crosssock bare"
call :CELL HorseBenchRawCrossSocket.exe  9004 "--headers"                          "raw-crosssock +headers"
call :CELL HorseBenchRawIndy.exe         9006 "--listenqueue %LISTENQ%"            "raw-indy bare"
call :CELL HorseBenchRawIndy.exe         9006 "--headers --listenqueue %LISTENQ%"  "raw-indy +headers"
call :CELL HorseBenchIndy.exe            9001 "--maxconn %MAXCONN% --listenqueue %LISTENQ%"                 "Horse+Indy bare"
call :CELL HorseBenchIndy.exe            9011 "--headers-only --maxconn %MAXCONN% --listenqueue %LISTENQ%"  "Horse+Indy +headers"
call :CELL HorseBenchIndy.exe            9011 "--cors --maxconn %MAXCONN% --listenqueue %LISTENQ%"          "Horse+Indy +cors"
call :CELL HorseBenchCrossSocket.exe     9002 "--maxconn %MAXCONN% --listenqueue %LISTENQ%"                 "Horse+CrossSock bare"
call :CELL HorseBenchCrossSocket.exe     9012 "--headers-only --maxconn %MAXCONN% --listenqueue %LISTENQ%" "Horse+CrossSock +headers"
call :CELL HorseBenchCrossSocket.exe     9012 "--cors --maxconn %MAXCONN% --listenqueue %LISTENQ%"         "Horse+CrossSock +cors"
call :CELL HorseBenchMormot.exe          9003 "--maxconn %MAXCONN% --listenqueue %LISTENQ%"                 "Horse+mORMot bare"
call :CELL HorseBenchMormot.exe          9013 "--headers-only --maxconn %MAXCONN% --listenqueue %LISTENQ%" "Horse+mORMot +headers"
call :CELL HorseBenchMormot.exe          9013 "--cors --maxconn %MAXCONN% --listenqueue %LISTENQ%"          "Horse+mORMot +cors"
REM mORMot async backend (THttpAsyncServer) -- A/B vs the thread-pool rows above
call :CELL HorseBenchMormot.exe          9003 "--async --maxconn %MAXCONN%"                                 "Horse+mORMot bare (async)"
call :CELL HorseBenchMormot.exe          9013 "--async --headers-only --maxconn %MAXCONN%"                 "Horse+mORMot +headers (async)"
REM mORMot http.sys backend (THttpApiServer) -- needs admin OR urlacl for :9003 and :9013
REM   netsh http add urlacl url=http://+:9003/ user=Everyone  (and :9013)
call :CELL HorseBenchMormot.exe          9003 "--httpapi --maxconn %MAXCONN%"                               "Horse+mORMot bare (httpapi)"
call :CELL HorseBenchMormot.exe          9013 "--httpapi --headers-only --maxconn %MAXCONN%"               "Horse+mORMot +headers (httpapi)"

echo.
echo ================================================================================
echo  Done. Table saved to: %RESULTS%
echo  Read: take "raw-mormot bare" RPS as the ceiling.
echo    fraction retained = row_RPS / ceiling ;  loss = (ceiling - row_RPS) / ceiling
echo  Non-zero 5xx = mis-built server or maxconn ^< c.  Non-zero "others" on Indy =
echo  listenqueue ^< c burst.  Both auto-scale from c here, so either points to a build issue.
echo ================================================================================
del "%TMP_OUT%" >nul 2>&1
endlocal
goto :eof

REM ============================================================================
:HEADERROW
REM Header + separator routed through :PRINTROW (which reads the _* vars) so the
REM columns always line up with the data rows. One "set" per line avoids the
REM trailing-space-before-"&" trap.
set _LABEL=LABEL
set _AVG=RPSavg
set _2XX=2xx
set _5XX=5xx
set _OTH=others
set _P50=P50
set _P75=P75
set _P90=P90
set _P95=P95
set _P99=P99
call :PRINTROW
set _LABEL=---------------------------
set _AVG=--------
set _2XX=---------
set _5XX=-------
set _OTH=-------
set _P50=--------
set _P75=--------
set _P90=--------
set _P95=--------
set _P99=--------
call :PRINTROW
goto :eof

REM ============================================================================
REM  :CELL <exe> <port> "<args>" <label>
REM  Kills all servers, starts <exe> <args>, waits for <port>, runs bombardier
REM  RUNS times (averaging RPS), captures last-run 2xx/5xx/others + P50..P99, prints a row.
REM ============================================================================
:CELL
    set _EXE=%~1
    set _PORT=%~2
    set _ARGS=%~3
    set _LABEL=%~4
    set _SUM=0
    set _2XX=0
    set _5XX=0
    set _OTH=0
    set _P50=n/a
    set _P75=n/a
    set _P90=n/a
    set _P95=n/a
    set _P99=n/a

    for %%E in (HorseBenchIndy.exe HorseBenchCrossSocket.exe HorseBenchMormot.exe HorseBenchRawIndy.exe HorseBenchRawCrossSocket.exe HorseBenchRawMormot.exe) do (
        taskkill /F /IM %%E >nul 2>&1
    )
    timeout /t 1 /nobreak >nul

    start /min "" "!SERVERS_DIR!\!_EXE!" !_ARGS!

    set _TRIES=0
    :LWAIT
        timeout /t 1 /nobreak >nul
        netstat -ano 2>nul | findstr ":!_PORT! " | findstr /I "LISTENING" >nul 2>&1
        if not errorlevel 1 goto :LUP
        set /a _TRIES+=1
        if !_TRIES! lss 10 goto :LWAIT
    set _AVG=ERR
    set _2XX=noListen
    set _5XX=-
    set _OTH=-
    set _P50=-
    set _P75=-
    set _P90=-
    set _P95=-
    set _P99=-
    call :PRINTROW
    REM http.sys (--httpapi) cells fail to listen when the URL ACL is missing —
    REM point the operator straight at the fix instead of a bare "noListen".
    echo !_ARGS! | findstr /I "httpapi" >nul 2>&1
    if not errorlevel 1 echo        NOTE: http.sys needs a URL ACL. Run this script elevated, or once: netsh http add urlacl url=http://+:!_PORT!/ user=%USERDOMAIN%\%USERNAME%  (see bench-perf-ladder-windows.md section 3)
    goto :eof
    :LUP

    REM -- warm-up (DISCARDED): prime the accept loop / thread pool at the test
    REM    concurrency so the first measured burst at c=%CONCURRENCY% lands on a
    REM    ready server. Stabilises high-c runs (removes the intermittent mORMot
    REM    connection-refusal artifact). Output thrown away.
    "%BOMB%" -c %CONCURRENCY% -n %WARMUP_N% --http1 %BASE_URL%:!_PORT!%ROUTE% >nul 2>&1

    for /L %%r in (1,1,%RUNS%) do (
        "%BOMB%" -c %CONCURRENCY% -n %REQUESTS% --latencies --http1 %BASE_URL%:!_PORT!%ROUTE% > "%TMP_OUT%" 2>&1
        set _RPS=0
        for /f "tokens=2" %%x in ('findstr /C:"Reqs/sec" "%TMP_OUT%"') do set _RPS=%%x
        for /f "tokens=1 delims=." %%i in ("!_RPS!") do set _RPSI=%%i
        if "!_RPSI!"=="" set _RPSI=0
        set /a _SUM+=_RPSI
        for /f "tokens=2 delims=," %%a in ('findstr /C:"5xx -" "%TMP_OUT%"') do for /f "tokens=3 delims= " %%b in ("%%a") do set _2XX=%%b
        for /f "tokens=5 delims=," %%a in ('findstr /C:"5xx -" "%TMP_OUT%"') do for /f "tokens=3 delims= " %%b in ("%%a") do set _5XX=%%b
        REM "others" = requests with no HTTP response (connection refused/reset/timeout);
        REM line "    others - 479" -> token3 is the count. 2xx + 5xx + others = n.
        for /f "tokens=3" %%x in ('findstr /C:"others -" "%TMP_OUT%"') do set _OTH=%%x
        REM All percentiles from the "--latencies" distribution block, e.g.
        REM   "     50%%     1.06ms" / "75%%" / "90%%" / "95%%" / "99%%".
        REM token1 is exactly "NN%%" on those lines; the progress-bar line also has a
        REM "%%" but its token1 is a number, so the "if token1==" guards reject it.
        REM (No pipe / no "findstr /V" -- findstr mis-parses "/" -> Bad command line.)
        for /f "tokens=1,2" %%p in ('findstr /C:"%%" "%TMP_OUT%"') do (
            if "%%p"=="50%%" set _P50=%%q
            if "%%p"=="75%%" set _P75=%%q
            if "%%p"=="90%%" set _P90=%%q
            if "%%p"=="95%%" set _P95=%%q
            if "%%p"=="99%%" set _P99=%%q
        )
    )
    set /a _AVG=_SUM/%RUNS%
    if "!_2XX!"=="" set _2XX=0
    if "!_5XX!"=="" set _5XX=0
    if "!_OTH!"=="" set _OTH=0

    call :PRINTROW
    taskkill /F /IM !_EXE! >nul 2>&1
goto :eof

REM ============================================================================
REM  :PRINTROW  (no args -- reads the _* cell vars)  -> console + RESULTS file
REM  Columns: LABEL RPSavg 2xx 5xx others P50 P75 P90 P95 P99.
REM  Pad-and-truncate each field to a fixed width for a readable table.
REM  Note: 2xx + 5xx + others = n. A non-zero "others" = connection-level failures
REM  (refused/reset/timeout), NOT HTTP 500s -- e.g. Indy's thread-per-connection
REM  accept backlog filling during the connection ramp at c=100.
REM ============================================================================
:PRINTROW
    set "f1=!_LABEL!                            "
    set "f2=!_AVG!            "
    set "f3=!_2XX!            "
    set "f4=!_5XX!            "
    set "f5=!_OTH!            "
    set "f6=!_P50!            "
    set "f7=!_P75!            "
    set "f8=!_P90!            "
    set "f9=!_P95!            "
    set "fA=!_P99!            "
    set "row= !f1:~0,27! !f2:~0,8! !f3:~0,9! !f4:~0,7! !f5:~0,7! !f6:~0,9! !f7:~0,9! !f8:~0,9! !f9:~0,9! !fA:~0,9!"
    echo !row!
    >>"%RESULTS%" echo !row!
goto :eof
