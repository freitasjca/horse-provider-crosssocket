@echo off
setlocal EnableDelayedExpansion

REM ============================================================================
REM  run-tls-tests.bat  -  TLS / mutual-TLS integration tests (CrossSocket)
REM
REM  Runs HorseCSTLSTestServer + HorseCSTLSTestClient in two passes:
REM    1. one-way TLS  (no argument)        → T1, T2
REM    2. mutual TLS   (mtls argument)      → T3, T4   (needs the mTLS patches)
REM
REM  Usage:  run-tls-tests.bat [Win32|Win64] [Release|Debug]
REM  Defaults: Win64 Release. Exit code = total failed assertions.
REM
REM  The mORMot and ICS providers ship the parallel HorseMormotTLSTest* /
REM  HorseICSTLSTest* pairs in their own repos (same structure, ports 9201/9111);
REM  run those from their respective scripts.
REM ============================================================================

set PLATFORM=%~1
set CONFIG=%~2
if "%PLATFORM%"=="" set PLATFORM=Win64
if "%CONFIG%"==""   set CONFIG=Release

set BIN=samples\tests\%PLATFORM%\%CONFIG%
set SERVER_EXE=%BIN%\HorseCSTLSTestServer.exe
set CLIENT_EXE=%BIN%\HorseCSTLSTestClient.exe
set TLS_PORT=9101

if not exist "%SERVER_EXE%" ( echo [ERROR] Not built: %SERVER_EXE% & exit /b 1 )
if not exist "%CLIENT_EXE%" ( echo [ERROR] Not built: %CLIENT_EXE% & exit /b 1 )

REM -- Cert fixtures must sit next to the binaries ----------------------------
if not exist "%BIN%\certs\server.crt" (
    if exist "tests\certs\server.crt" (
        echo [tls-test] Copying cert fixtures next to the binaries...
        xcopy /E /I /Y "tests\certs" "%BIN%\certs" >nul
    ) else (
        echo [ERROR] tests\certs\server.crt not found. Run tests\certs\gen-certs.sh.
        exit /b 1
    )
)

set TOTAL=0

call :RUNPASS ""      "one-way TLS"
set /a TOTAL+=%ERRORLEVEL%
call :RUNPASS "mtls"  "mutual TLS"
set /a TOTAL+=%ERRORLEVEL%

echo.
if "%TOTAL%"=="0" ( echo [tls-test] ALL PASSED ) else ( echo [tls-test] %TOTAL% assertion^(s^) FAILED )
exit /b %TOTAL%

REM ---------------------------------------------------------------------------
:RUNPASS
REM  %~1 = server/client argument ("" or "mtls"), %~2 = label
set ARG=%~1
echo.
echo ============================================================
echo  TLS pass: %~2   (arg='%ARG%')
echo ============================================================
taskkill /F /IM HorseCSTLSTestServer.exe /T >nul 2>&1
start "HorseCSTLSTestServer" /B "%SERVER_EXE%" %ARG%

set READY=0
for /L %%I in (1,1,10) do (
    if "!READY!"=="0" (
        netstat -ano 2>nul | findstr ":%TLS_PORT% " | findstr /I "LISTENING" >nul 2>&1
        if not errorlevel 1 ( set READY=1 ) else ( timeout /t 1 /nobreak >nul )
    )
)
if "!READY!"=="0" (
    echo [tls-test] Server did not bind port %TLS_PORT%.
    taskkill /F /IM HorseCSTLSTestServer.exe /T >nul 2>&1
    exit /b 1
)

"%CLIENT_EXE%" %ARG%
set PASS_EXIT=%ERRORLEVEL%

taskkill /F /IM HorseCSTLSTestServer.exe /T >nul 2>&1
exit /b %PASS_EXIT%
