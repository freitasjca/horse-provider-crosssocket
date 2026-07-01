@echo off
setlocal EnableDelayedExpansion

REM ============================================================================
REM  bench-tls.bat  -  TLS / mutual-TLS throughput bench across all providers
REM
REM  Benchmarks HTTPS performance for the three TLS-capable self-hosted Horse
REM  providers — CrossSocket, mORMot, ICS — using HorseBenchTLSClient as the
REM  driver (TCrossHttpClient over https; mTLS via a client-cert override).
REM
REM  Usage:
REM    bench-tls.bat              one-way TLS
REM    bench-tls.bat --mtls       mutual TLS (servers + client present certs)
REM
REM  Prerequisites (build with scripts\build.bat or the IDE):
REM    HorseBenchCrossSocket.exe   HorseBenchMormot.exe   HorseBenchICS.exe
REM    HorseBenchTLSClient.exe
REM  …and a certs\ folder (ca/server/client .crt/.key) next to those exes.
REM  This script copies samples\bench\certs there if it is missing.
REM
REM  TLS ports (bare + 30): CrossSocket 9032   mORMot 9033   ICS 9039
REM ============================================================================

set MODE=%~1
set SRVFLAG=--tls
set CLIFLAG=
if /I "%MODE%"=="--mtls" (
    set SRVFLAG=--mtls
    set CLIFLAG=--mtls
)

REM -- Locate the built bench binaries (same discovery as bench-perf-ladder) ----
set SERVERS_DIR=
if exist "%~dp0HorseBenchCrossSocket.exe"                                          set SERVERS_DIR=%~dp0
if "!SERVERS_DIR!"=="" if exist "%~dp0..\samples\bench\Win64\Release\HorseBenchCrossSocket.exe" set SERVERS_DIR=%~dp0..\samples\bench\Win64\Release
if "!SERVERS_DIR!"=="" if exist "%~dp0..\Win64\Release\HorseBenchCrossSocket.exe"   set SERVERS_DIR=%~dp0..\Win64\Release
if "!SERVERS_DIR!"=="" (
    echo ERROR: HorseBench server binaries not found near this script.
    echo        Build them first ^(scripts\build.bat or the IDE^).
    exit /b 1
)
echo [bench-tls] Binaries: !SERVERS_DIR!
echo [bench-tls] Mode    : !SRVFLAG!

REM -- Ensure the cert fixtures sit next to the binaries -----------------------
if not exist "!SERVERS_DIR!\certs\server.crt" (
    if exist "%~dp0..\samples\bench\certs\server.crt" (
        echo [bench-tls] Copying cert fixtures next to the binaries...
        xcopy /E /I /Y "%~dp0..\samples\bench\certs" "!SERVERS_DIR!\certs" >nul
    ) else (
        echo ERROR: certs\server.crt not found. Generate with samples\bench\certs\gen-certs.sh.
        exit /b 1
    )
)

REM -- Start the three TLS servers in the background ---------------------------
echo [bench-tls] Starting CrossSocket (9032), mORMot (9033), ICS (9039) with !SRVFLAG! ...
pushd "!SERVERS_DIR!"
start "BenchTLS-CrossSocket" /B HorseBenchCrossSocket.exe !SRVFLAG!
start "BenchTLS-mORMot"      /B HorseBenchMormot.exe      !SRVFLAG!
start "BenchTLS-ICS"         /B HorseBenchICS.exe         !SRVFLAG!
popd

REM -- Wait for the TLS ports to come up (up to ~10 s) ------------------------
set READY=0
for /L %%I in (1,1,10) do (
    if "!READY!"=="0" (
        netstat -ano 2>nul | findstr ":9032 " | findstr /I "LISTENING" >nul 2>&1
        if not errorlevel 1 (
            netstat -ano 2>nul | findstr ":9033 " | findstr /I "LISTENING" >nul 2>&1
            if not errorlevel 1 (
                netstat -ano 2>nul | findstr ":9039 " | findstr /I "LISTENING" >nul 2>&1
                if not errorlevel 1 set READY=1
            )
        )
        if "!READY!"=="0" timeout /t 1 /nobreak >nul
    )
)
if "!READY!"=="0" echo [bench-tls] WARNING: not all TLS ports came up; running anyway.

REM -- Run the TLS bench client -----------------------------------------------
echo.
"!SERVERS_DIR!\HorseBenchTLSClient.exe" !CLIFLAG!
set BENCH_EXIT=%ERRORLEVEL%

REM -- Stop the servers -------------------------------------------------------
echo.
echo [bench-tls] Stopping servers...
taskkill /F /IM HorseBenchCrossSocket.exe /T >nul 2>&1
taskkill /F /IM HorseBenchMormot.exe      /T >nul 2>&1
taskkill /F /IM HorseBenchICS.exe         /T >nul 2>&1

echo [bench-tls] Done (client exit=%BENCH_EXIT%).
exit /b %BENCH_EXIT%
