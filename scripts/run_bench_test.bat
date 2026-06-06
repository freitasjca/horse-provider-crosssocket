@echo off
setlocal enabledelayedexpansion

REM -- Auto-detect binary directory ----------------------------------------------
REM Tries, in order: same folder as this script, then two common msbuild layouts.
set SERVERS_DIR=
if exist "%~dp0HorseBenchClient.exe"                                                        set SERVERS_DIR=%~dp0
if "!SERVERS_DIR!"=="" if exist "%~dp0..\samples\bench\Win64\Release\HorseBenchClient.exe"  set SERVERS_DIR=%~dp0..\samples\bench\Win64\Release
if "!SERVERS_DIR!"=="" if exist "%~dp0..\Win64\Release\HorseBenchClient.exe"                set SERVERS_DIR=%~dp0..\Win64\Release
if "!SERVERS_DIR!"=="" (
    echo [ERROR] Bench binaries not found. Looked in:
    echo           %~dp0
    echo           %~dp0..\samples\bench\Win64\Release
    echo           %~dp0..\Win64\Release
    echo         Run scripts\build.bat first, or copy binaries to one of those folders.
    exit /b 1
)
echo [info]  Binaries: !SERVERS_DIR!

REM -- Kill any running bench servers for a clean, deterministic state -----------
echo.
echo Killing any running bench servers...
for %%E in (HorseBenchIndy.exe HorseBenchCrossSocket.exe HorseBenchMormot.exe HorseBenchRawCrossSocket.exe HorseBenchRawMormot.exe) do (
    taskkill /F /IM %%E >nul 2>&1
)
timeout /t 1 /nobreak >nul

REM -- Launch all 8 servers this test needs --------------------------------------
echo Launching servers...
REM Bare mode (6 windows or background starts)
call :CHECK_PORT 9001 HorseBenchIndy.exe
call :CHECK_PORT 9002 HorseBenchCrossSocket.exe
call :CHECK_PORT 9003 HorseBenchMormot.exe
call :CHECK_PORT 9004 HorseBenchRawCrossSocket.exe
call :CHECK_PORT 9005 HorseBenchRawMormot.exe
REM Middleware mode (Horse providers only)
call :CHECK_PORT 9011 HorseBenchIndy.exe --middleware
call :CHECK_PORT 9012 HorseBenchCrossSocket.exe --middleware
call :CHECK_PORT 9013 HorseBenchMormot.exe --middleware


REM Verify all 8 ports are listening
powershell "Get-NetTCPConnection -State Listen | Where-Object {$_.LocalPort -in 9001,9002,9003,9004,9005,9011,9012,9013} | Select LocalPort,OwningProcess | Sort LocalPort"

REM Run
"%SERVERS_DIR%\HorseBenchClient.exe"


endlocal
goto :eof

REM -- Subroutine: CHECK_PORT ----------------------------------------------------
REM Usage: call :CHECK_PORT <port> <exe> [extra-args]
REM   Checks if <port> is already listening. If not, launches <exe> from
REM   SERVERS_DIR with optional <extra-args> in a minimised window, then
REM   waits up to 5 seconds for the port to open.
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
    REM Poll up to 5 seconds (5 x 1 s)
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
