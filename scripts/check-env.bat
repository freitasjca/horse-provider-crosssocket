@echo off
setlocal EnableDelayedExpansion

REM ============================================================================
REM  check-env.bat  —  Verify build prerequisites for horse-provider-crosssocket
REM
REM  Usage:
REM    check-env.bat [Release|Debug] [Win32|Win64]
REM
REM  Exits with 0 if all checks pass, 1 if any check fails.
REM  Called automatically by build.bat before any compilation.
REM
REM  Checks performed:
REM    1. Delphi rsvars.bat exists and sets $(BDS)
REM    2. MSBuild is in PATH (set by rsvars.bat)
REM    3. dcc64 / dcc32 compiler is reachable
REM    4. Boss is in PATH
REM    5. .dproj files exist
REM    6. modules/ directory exists (boss install has been run)
REM    7. Required module subdirectories exist
REM    8. Port 9100 is not already in use (test port conflict check)
REM ============================================================================

set CONFIG=%~1
set PLATFORM=%~2
if "%CONFIG%"==""   set CONFIG=Release
if "%PLATFORM%"=="" set PLATFORM=Win64

set ERRORS=0

echo.
echo ============================================================
echo  Environment check  (%CONFIG% %PLATFORM%)
echo ============================================================

REM ── 1. Locate rsvars.bat ─────────────────────────────────────────────────────

set RSVARS_FOUND=0

if defined DELPHI_ROOT (
    if exist "%DELPHI_ROOT%\bin\rsvars.bat" (
        set RSVARS="%DELPHI_ROOT%\bin\rsvars.bat"
        set RSVARS_FOUND=1
        echo [OK]   rsvars.bat : %DELPHI_ROOT%\bin\rsvars.bat
    ) else (
        echo [FAIL] rsvars.bat not found at DELPHI_ROOT=%DELPHI_ROOT%
        set /A ERRORS+=1
    )
) else (
    for %%V in (23.0 22.0 21.0) do (
        if "!RSVARS_FOUND!"=="0" (
            set CANDIDATE=C:\Program Files (x86)\Embarcadero\Studio\%%V\bin\rsvars.bat
            if exist "!CANDIDATE!" (
                set RSVARS="!CANDIDATE!"
                set RSVARS_FOUND=1
                echo [OK]   rsvars.bat : !CANDIDATE!
            )
        )
    )
    if "!RSVARS_FOUND!"=="0" (
        echo [FAIL] Delphi not found. Install Delphi 10.4+ or set DELPHI_ROOT.
        echo        Checked: C:\Program Files (x86)\Embarcadero\Studio\{23.0,22.0,21.0}\bin\rsvars.bat
        set /A ERRORS+=1
    )
)

REM ── 2. Load rsvars and check BDS / MSBuild ───────────────────────────────────

if "!RSVARS_FOUND!"=="1" (
    call !RSVARS! >nul 2>&1

    if defined BDS (
        echo [OK]   BDS        : %BDS%
    ) else (
        echo [FAIL] rsvars.bat did not set BDS. Delphi installation may be corrupt.
        set /A ERRORS+=1
    )

    where msbuild >nul 2>&1
    if errorlevel 1 (
        echo [FAIL] msbuild not found in PATH after rsvars.bat. Check Delphi install.
        set /A ERRORS+=1
    ) else (
        for /F "tokens=*" %%P in ('where msbuild 2^>nul') do (
            echo [OK]   msbuild    : %%P
            goto :msbuild_done
        )
        :msbuild_done
    )

    REM Verify the correct DCC compiler binary exists
    if "%PLATFORM%"=="Win64" (
        if exist "%BDS%\bin\dcc64.exe" (
            echo [OK]   dcc64      : %BDS%\bin\dcc64.exe
        ) else (
            echo [FAIL] dcc64.exe not found at %BDS%\bin\dcc64.exe
            echo        Win64 target requires dcc64.exe (included with all Delphi editions).
            set /A ERRORS+=1
        )
    ) else (
        if exist "%BDS%\bin\dcc32.exe" (
            echo [OK]   dcc32      : %BDS%\bin\dcc32.exe
        ) else (
            echo [FAIL] dcc32.exe not found at %BDS%\bin\dcc32.exe
            set /A ERRORS+=1
        )
    )

    REM Verify CodeGear.Delphi.Targets exists — if missing, every msbuild call fails
    if exist "%BDS%\Bin\CodeGear.Delphi.Targets" (
        echo [OK]   Targets    : %BDS%\Bin\CodeGear.Delphi.Targets
    ) else (
        echo [FAIL] CodeGear.Delphi.Targets not found at %BDS%\Bin\
        echo        This file is part of the Delphi install. Re-install if missing.
        set /A ERRORS+=1
    )
)

REM ── 3. Boss ──────────────────────────────────────────────────────────────────

where boss >nul 2>&1
if errorlevel 1 (
    echo [FAIL] boss not found in PATH.
    echo        Install Boss: https://github.com/HashLoad/boss/releases
    echo        Then add its directory to the system PATH.
    set /A ERRORS+=1
) else (
    for /F "tokens=*" %%P in ('where boss 2^>nul') do (
        echo [OK]   boss       : %%P
        goto :boss_done
    )
    :boss_done
)

REM ── 4. .dproj files ──────────────────────────────────────────────────────────

if exist "samples\tests\HorseCSTestServer.dproj" (
    echo [OK]   Server .dproj found
) else (
    echo [FAIL] samples\tests\HorseCSTestServer.dproj not found.
    echo        This file should be committed to the repository.
    set /A ERRORS+=1
)

if exist "samples\tests\HorseCSTestClient.dproj" (
    echo [OK]   Client .dproj found
) else (
    echo [FAIL] samples\tests\HorseCSTestClient.dproj not found.
    echo        This file should be committed to the repository.
    set /A ERRORS+=1
)

REM ── 5. modules/ (boss install output) ────────────────────────────────────────

if exist "modules\" (
    echo [OK]   modules\   exists
) else (
    echo [WARN] modules\ does not exist — "boss install" has not been run yet.
    echo        Run: boss install
    echo        (build.bat does this automatically)
)

REM Check for specific module subdirectories only if modules/ exists
if exist "modules\" (
    for %%D in (
        "modules\horse\src"
        "modules\Delphi-Cross-Socket\Net"
        "modules\Delphi-Cross-Socket\Utils"
        "modules\Delphi-Cross-Socket\OpenSSL"
    ) do (
        if exist %%D (
            echo [OK]   %%~D
        ) else (
            echo [FAIL] %%~D not found after boss install.
            echo        Expected from boss.json dependencies:
            echo          github.com/freitasjca/horse
            echo          github.com/freitasjca/Delphi-Cross-Socket
            set /A ERRORS+=1
        )
    )
)

REM ── 6. Port 9100 availability (test port conflict) ────────────────────────────

netstat -ano | find ":9100 " >nul 2>&1
if not errorlevel 1 (
    echo [WARN] Port 9100 is already in use. Integration tests may fail.
    echo        Check for a leftover HorseCSTestServer.exe:
    echo          tasklist /FI "IMAGENAME eq HorseCSTestServer.exe"
    echo          taskkill /F /IM HorseCSTestServer.exe
) else (
    echo [OK]   Port 9100  available
)

REM ── Summary ───────────────────────────────────────────────────────────────────

echo.
if "%ERRORS%"=="0" (
    echo ============================================================
    echo  All checks PASSED
    echo ============================================================
    exit /b 0
) else (
    echo ============================================================
    echo  %ERRORS% check(s^) FAILED — fix the issues above before building
    echo ============================================================
    exit /b 1
)
