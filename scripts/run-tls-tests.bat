@echo off
setlocal EnableDelayedExpansion
REM ===========================================================================
REM  run-tls-tests.bat  -  TLS / mutual-TLS integration tests (CrossSocket)
REM
REM  Runs HorseCSTLSTestServer + HorseCSTLSTestClient in two passes:
REM    1. one-way TLS  (no argument)   -> T1, T2
REM    2. mutual TLS   (mtls argument) -> T3, T4
REM
REM  Usage:  run-tls-tests.bat        (build first with tests\build-tls-tests.bat)
REM  Exit code: 0 = all passed, N = N failed assertions, 2 = VOID (nothing ran).
REM
REM  ---------------------------------------------------------------------
REM  Rewritten 2026-09-24. The previous version looked for the binaries under
REM  samples\tests\<Platform>\<Config>, which has never existed for this pair:
REM  build-tls-tests.bat passes no -E and so builds them in place, into tests\.
REM  The script therefore exited 1 with "Not built" and gated nothing. It also
REM  took [Win32|Win64] [Release|Debug] arguments that selected that directory;
REM  they are gone because there is only one output location.
REM
REM  It now also refuses to run rather than produce an untrustworthy pass:
REM
REM  1. The port must be FREE before we start. Windows lets a second process
REM     bind an already-owned port without error, so "port is LISTENING" says
REM     nothing about WHOSE server answers the client. A stale server would be
REM     silently tested in place of the fresh one.
REM
REM  2. We kill by PID, not by image name. taskkill /IM truncates at 25
REM     characters; "HorseCSTLSTestServer.exe" is 24 and happens to fit, but
REM     the sibling mORMot suite's 28-character name does not, and a kill that
REM     matches nothing still reports success.
REM
REM  What this suite genuinely proves: T1/T2 run over HTTPS through
REM  TCrossHttpClient, so a server that was not actually speaking TLS fails the
REM  handshake and they go red. (That is how the mORMot provider's dead TLS was
REM  found -- FIX-MORMOT-TLS-1.) T4 alone is weak: it only asserts "not 200".
REM
REM  No parenthesised blocks; ping rather than timeout for the wait.
REM  ---------------------------------------------------------------------
REM ===========================================================================

for %%I in ("%~dp0..") do set "ROOT=%%~fI"
set "BIN=%ROOT%\tests"
set "SERVER_EXE=%BIN%\HorseCSTLSTestServer.exe"
set "CLIENT_EXE=%BIN%\HorseCSTLSTestClient.exe"
set "TLS_PORT=9101"

REM -- Build first, so the gate owns its inputs ------------------------------
REM  A stale .exe passes exactly as convincingly as a current one, and nothing
REM  in the result says which you ran. That cost four void results on
REM  2026-09-24 across these three suites; the CrossSocket one was caught only
REM  because code that had since been DELETED happened to still print a
REM  diagnostic line. Timestamp heuristics can be fooled and are awkward to get
REM  right in cmd; rebuilding costs ~2 seconds and removes the question.
REM
REM  A build failure is VOID, not FAILED: nothing was tested, so reporting a
REM  count of failed assertions would be a lie.
REM
REM  Pass  nobuild  to skip it (prebuilt binaries, or a CI stage that already
REM  built) - then staleness is yours to own again.
if /I "%~1"=="nobuild" goto :skip_build
echo === building (pass "nobuild" to skip) ===
call "%ROOT%\tests\build-tls-tests.bat"
if errorlevel 1 goto :build_failed
echo.
:skip_build

if not exist "%SERVER_EXE%" goto :not_built
if not exist "%CLIENT_EXE%" goto :not_built
if not exist "%BIN%\certs\server.crt" goto :no_certs

set "VOIDED=0"
set /a TOTAL=0

call :runpass "" "one-way TLS" oneway
set /a TOTAL+=%ERRORLEVEL%
call :runpass "mtls" "mutual TLS" mtls
set /a TOTAL+=%ERRORLEVEL%

echo.
echo ===========================================================================
if "%VOIDED%"=="1" goto :report_void
if not "%TOTAL%"=="0" goto :report_fail
echo  ALL PASSED - one-way TLS and mutual TLS.
echo ===========================================================================
exit /b 0
:report_fail
echo  FAILED - %TOTAL% assertion^(s^). Server logs: %BIN%\tls-*.log
echo ===========================================================================
exit /b %TOTAL%
:report_void
echo  VOID - the suite did not run. This is NOT a pass; see the reason above.
echo ===========================================================================
exit /b 2

REM ---------------------------------------------------------------------------
:runpass
set "ARG=%~1"
set "LABEL=%~2"
set "LOG=%BIN%\tls-%~3.log"
echo.
echo ===========================================================================
echo  TLS pass: !LABEL!
echo ===========================================================================

set "OWNER="
for /f "tokens=5" %%P in ('netstat -ano 2^>nul ^| findstr ":%TLS_PORT% " ^| findstr /I "LISTENING"') do set "OWNER=%%P"
echo    pre-check: port %TLS_PORT% owner=[!OWNER!]
if not "!OWNER!"=="" goto :port_busy

del /q "!LOG!" >nul 2>&1
pushd "%BIN%"
start "" /B cmd /c ""%SERVER_EXE%" !ARG! > "!LOG!" 2>&1"
popd

set /a TRIES=0
:wait_loop
set "SRVPID="
for /f "tokens=5" %%P in ('netstat -ano 2^>nul ^| findstr ":%TLS_PORT% " ^| findstr /I "LISTENING"') do set "SRVPID=%%P"
if not "!SRVPID!"=="" goto :bound
set /a TRIES+=1
if !TRIES! GEQ 20 goto :no_bind
ping -n 2 127.0.0.1 >nul 2>&1
goto :wait_loop

:bound
echo    server pid !SRVPID! listening on port %TLS_PORT%

"%CLIENT_EXE%" !ARG!
set "PASS_EXIT=!ERRORLEVEL!"

taskkill /PID !SRVPID! /F /T >nul 2>&1
exit /b !PASS_EXIT!

:port_busy
echo    [VOID] port %TLS_PORT% is already held by pid !OWNER!.
echo           Windows would let our server bind anyway and the client could
echo           then be testing the OTHER process. Stop it first:
echo             taskkill /PID !OWNER! /F
set "VOIDED=1"
exit /b 0

:no_bind
echo    [VOID] server never bound port %TLS_PORT% within 20 tries.
call :dumplog
set "VOIDED=1"
exit /b 0

:dumplog
echo    ---- server output ----
if exist "!LOG!" type "!LOG!"
echo    -----------------------
exit /b 0

:build_failed
echo.
echo ===========================================================================
echo  VOID - the build failed, so nothing was tested. This is NOT a test
echo         failure; fix the build error above and run again.
echo ===========================================================================
exit /b 2
:not_built
echo ERROR: the TLS test binaries are not built. Run:
echo          tests\build-tls-tests.bat
echo        They build in place, into tests\ - there is no Win64\Release copy.
exit /b 2
:no_certs
echo ERROR: %BIN%\certs\server.crt not found. See tests\TLS-TESTS.md.
exit /b 2
