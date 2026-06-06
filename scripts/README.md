# Build scripts

All scripts are run from the **repository root** (`horse-provider-crosssocket\`), not from inside `scripts\`.

---

## Quick start (Windows CLI)

```bat
REM 1. Set Delphi path (once per machine / CI agent)
set DELPHI_ROOT=C:\Program Files (x86)\Embarcadero\Studio\22.0

REM 2. Verify everything is in place
scripts\check-env.bat

REM 3. Build Release Win64 (installs deps, compiles both test projects)
scripts\build.bat

REM 4. Run integration tests (14 tests, exit code = failures)
scripts\run-tests.bat
```

---

## Scripts

### `check-env.bat [Config] [Platform]`

Verifies all prerequisites before any compilation:

| Check | What it looks for |
|---|---|
| Delphi | `rsvars.bat` at `%DELPHI_ROOT%\bin\` or auto-detected in common install paths |
| `$(BDS)` | Set by `rsvars.bat`; needed by MSBuild to find `CodeGear.Delphi.Targets` |
| `msbuild` | In PATH after `rsvars.bat` |
| `dcc64` / `dcc32` | Compiler binary at `%BDS%\bin\` |
| `CodeGear.Delphi.Targets` | MSBuild targets file at `%BDS%\Bin\` |
| `boss` | In PATH |
| `.dproj` files | Both `samples\tests\HorseCSTestServer.dproj` and `HorseCSTestClient.dproj` |
| `modules\` | Created by `boss install`; warns if missing |
| Port 9100 | Warns if already bound (integration test port conflict) |

Exit code: `0` = all OK, `1` = one or more checks failed.

---

### `build.bat [Config] [Platform] [clean]`

| Argument | Default | Options |
|---|---|---|
| Config | `Release` | `Release`, `Debug` |
| Platform | `Win64` | `Win64`, `Win32` |
| clean | *(omit)* | `clean` = rebuild from scratch |

```bat
scripts\build.bat                       Release Win64 incremental
scripts\build.bat Debug Win64           Debug Win64 incremental
scripts\build.bat Release Win64 clean   Release Win64, clean first
```

Output:
```
samples\tests\Win64\Release\HorseCSTestServer.exe
samples\tests\Win64\Release\HorseCSTestClient.exe
```

---

### `run-tests.bat [Platform] [Config]`

| Argument | Default | Options |
|---|---|---|
| Platform | `Win64` | `Win64`, `Win32` |
| Config | `Release` | `Release`, `Debug` |

Starts `HorseCSTestServer.exe` on port 9100, waits for it to accept connections (polls `GET /ping` up to 10 s), then runs `HorseCSTestClient.exe`.

Exit code = number of failed tests (`0` = all 14 passed).

The server is always killed on exit, even if the client crashes or the script is interrupted.

---

## Delphi version notes

`ProjectVersion` in the `.dproj` files is set to `20.0` (Delphi 11 Alexandria).

| Delphi version | Studio version | `DELPHI_ROOT` example |
|---|---|---|
| 12 Athens | 23.0 | `C:\Program Files (x86)\Embarcadero\Studio\23.0` |
| 11 Alexandria | 22.0 | `C:\Program Files (x86)\Embarcadero\Studio\22.0` |
| 10.4 Sydney | 21.0 | `C:\Program Files (x86)\Embarcadero\Studio\21.0` |

If using Delphi 10.4, the IDE will offer to upgrade `ProjectVersion` when you first open the `.dproj`. Accept the upgrade and commit the updated file. The CLI build will continue to work without this change, but the IDE will prompt every time.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `[FAIL] Delphi not found` | `DELPHI_ROOT` not set, wrong path | `set DELPHI_ROOT=C:\...\Studio\22.0` |
| `Fatal: Unit not found: Horse` | `boss install` not run, or `modules\horse\src` missing | `boss install` |
| `Fatal: Unit not found: Net.CrossHttpServer` | `modules\Delphi-Cross-Socket\Net` missing | `boss install` |
| `[ERROR] CodeGear.Delphi.Targets not found` | `rsvars.bat` not called, or BDS wrong | Call `rsvars.bat` before `msbuild` |
| `[ERROR] Server did not start within 10 seconds` | Port 9100 in use, or server crashed at startup | `netstat -ano \| find ":9100"`, then `taskkill /F /IM HorseCSTestServer.exe` |
| Test client exits with N | N integration tests failed | Read client console output for which tests failed and what response was received |
