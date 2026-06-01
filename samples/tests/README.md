# Integration Test Matrix — `horse-provider-crosssocket` samples/tests

This tree exercises every PATCH-HORSE-2 Provider × Application-type combination using a single shared test client and a per-shape server. The shared client (`HorseCSTestClient.dpr`) is *transport-neutral* — it sends HTTP to `127.0.0.1:9010` and asserts response bodies / headers / status codes. Any of the server projects in this tree can be the target: each registers the same 32 routes via the shared `Horse.CrossSocket.TestRoutes` unit.

Expected result for every server: **88 passed, 1 failed** (89 sub-assertions). The single failure is the documented multi-value `Set-Cookie` limitation — `FCustomHeaders` is a `TDictionary<string,string>` on Delphi / `TStringList` on FPC, so two `Res.AddHeader('Set-Cookie', …)` calls keep only the last. See [`doc/providers.md`](../../doc/providers.md) for context.

---

## Folder layout

```
samples/tests/
├── README.md                                 ← this file
├── HorseCSTestClient.dpr / .dproj            ← shared client; targets 127.0.0.1:9010
├── HorseCSTestServer.dpr / .dproj            ← legacy baseline (Console + HORSE_CROSSSOCKET).
│                                                Kept for backwards compatibility; same routes
│                                                as Delphi/Console/ below.
│
├── Common/
│   └── Horse.CrossSocket.TestRoutes.pas      ← the 32-route surface, dual-compiler.
│                                                Used by every per-shape server below.
│
├── Delphi/
│   ├── Console/HorseCSConsoleTestServer.dpr  ← HORSE_PROVIDER_CROSSSOCKET
│   ├── VCL/    HorseCSVCLTestServer.dpr      ← HORSE_PROVIDER_CROSSSOCKET + HORSE_APPTYPE_VCL
│   │           Main.Form.pas / .dfm          ← TfrmHorseTestVCL : TfrmHorseVCLHost
│   ├── WinService/                           ← HORSE_PROVIDER_CROSSSOCKET + HORSE_APPTYPE_DAEMON
│   │   HorseCSServiceTestServer.dpr
│   │   MyHorseService.pas / .dfm             ← THorseCSTestService : THorseCrossSocketService
│   └── LinuxDaemon/                          ← HORSE_PROVIDER_CROSSSOCKET, target Linux64
│       HorseCSLinuxDaemonTestServer.dpr
│
└── Lazarus/
    ├── Console/HorseCSTestServer.lpr         ← -dHORSE_PROVIDER_CROSSSOCKET
    ├── Daemon/ HorseCSDaemonTestServer.lpr   ← + -dHORSE_APPTYPE_DAEMON; THorseCrossSocketDaemonApp
    ├── LCL/    HorseCSLCLTestServer.lpr      ← + -dHORSE_APPTYPE_LCL
    │           Main.Form.pas / .lfm          ← TfrmHorseTestLCL : TfrmHorseLCLHost
    └── HTTPApplication/                      ← -dHORSE_PROVIDER_CROSSSOCKET; THorseCrossSocketHTTPApp
        HorseCSHTTPAppTestServer.lpr
```

---

## Test matrix

| # | Server project | Compiler | App type | Provider unit selected by Horse.pas | Lifecycle helper used | Defines |
|---|---|---|---|---|---|---|
| 1 | `HorseCSTestServer` *(legacy baseline)* | Delphi | Console | `Horse.Provider.CrossSocket` | manual | `HORSE_CROSSSOCKET` *(legacy alias)* |
| 2 | `Delphi/Console/HorseCSConsoleTestServer` | Delphi | Console | `Horse.Provider.CrossSocket` | `SetConsoleCtrlHandler` | `HORSE_PROVIDER_CROSSSOCKET` |
| 3 | `Delphi/VCL/HorseCSVCLTestServer` | Delphi | VCL | `Horse.Provider.CrossSocket.VCL` | `TfrmHorseVCLHost` | `HORSE_PROVIDER_CROSSSOCKET` + `HORSE_APPTYPE_VCL` |
| 4 | `Delphi/WinService/HorseCSServiceTestServer` | Delphi | Service | `Horse.Provider.CrossSocket.Daemon` | `THorseCrossSocketService` | `HORSE_PROVIDER_CROSSSOCKET` + `HORSE_APPTYPE_DAEMON` |
| 5 | `Delphi/LinuxDaemon/HorseCSLinuxDaemonTestServer` | Delphi (Linux64) | Daemon | `Horse.Provider.CrossSocket.Daemon` | `THorseCrossSocketLinuxDaemonApp.Run` | `HORSE_PROVIDER_CROSSSOCKET` + `HORSE_APPTYPE_DAEMON` |
| 6 | `Lazarus/Console/HorseCSTestServer` | FPC | Console | `Horse.Provider.CrossSocket` | `fpSignal` | `-dHORSE_PROVIDER_CROSSSOCKET` |
| 7 | `Lazarus/Daemon/HorseCSDaemonTestServer` | FPC | Daemon | `Horse.Provider.CrossSocket.FPC.Daemon` | `THorseCrossSocketDaemonApp.Run` | `-dHORSE_PROVIDER_CROSSSOCKET` + `-dHORSE_APPTYPE_DAEMON` |
| 8 | `Lazarus/LCL/HorseCSLCLTestServer` | FPC | LCL | `Horse.Provider.CrossSocket.FPC.LCL` | `TfrmHorseLCLHost` | `-dHORSE_PROVIDER_CROSSSOCKET` + `-dHORSE_APPTYPE_LCL` |
| 9 | `Lazarus/HTTPApplication/HorseCSHTTPAppTestServer` | FPC | HTTPApp | `Horse.Provider.CrossSocket` | `THorseCrossSocketHTTPApp.Run` | `-dHORSE_PROVIDER_CROSSSOCKET` |

Run any one of them on port 9010, then run the shared `HorseCSTestClient`. Expected: **88 passed, 1 failed**.

> **Why rows 4 and 5 share the same defines.** On Delphi, `HORSE_APPTYPE_DAEMON` means "OS-supervised long-running process" — the OS-specific incarnation (Windows Service via `TService`, or Linux daemon via POSIX signal handlers) is selected by the build target, not by another define. `Horse.Provider.CrossSocket.Daemon.pas` ships both paths in one unit (`{$IFDEF MSWINDOWS}` switch). This matches the cross-platform behaviour of the existing Indy-based `Horse.Provider.Daemon.pas`.

---

## Building each project — the .dproj / .lpi situation

> The `.dpr` / `.lpr` sources are committed. The matching `.dproj` / `.lpi` project files for the **new per-shape servers** are **not** committed — they're user-created via the IDE so platform settings, search paths, and IDE state stay with the developer. The two legacy projects (`HorseCSTestClient.dproj` and `HorseCSTestServer.dproj`) at the root *are* committed because they pre-date PATCH-HORSE-2.

### Delphi (Console / VCL / WinService / LinuxDaemon)

1. **File → Open Project** and select the `.dpr` file. Delphi prompts to create the matching `.dproj`; accept.
2. **Project → Options → Conditional defines:** add the defines from the matrix (e.g. `HORSE_PROVIDER_CROSSSOCKET;HORSE_APPTYPE_VCL`).
3. **Project → Options → Delphi Compiler → Search path:** add the entries below — same absolute-path style used by `horse-provider-mormot/samples/tests/README.md`. The exact paths depend on which install path you chose (upstream + CnPack, or fork). Both are documented; pick one.
4. **Project → Options → Application type** (only for VCL/WinService — set to VCL Forms Application or Service Application as appropriate; Console/LinuxDaemon use the `{$APPTYPE CONSOLE}` directive from the .dpr).
5. **Project → Build**, then run.

> Horse is pulled in by `boss install horse-provider-crosssocket` directly from `HashLoad/horse`. If you ran Boss inside the provider repo, the Boss-managed copy lives under `modules/horse/src` and you reference it via the relative `..\..\modules\horse\src` path. If you cloned `HashLoad/horse` manually, use an absolute path instead.

**Search paths — Path A (upstream `winddriver/Delphi-Cross-Socket` + `cnpack/cnvcl`):**

```
C:\lang\Repo\horse-provider-crosssocket\src         ← this repo
C:\lang\Repo\horse-provider-crosssocket\modules\horse\src   ← HashLoad/horse via Boss
C:\lang\Repo\Delphi-Cross-Socket\Net                ← winddriver/Delphi-Cross-Socket
C:\lang\Repo\Delphi-Cross-Socket\Utils
C:\lang\Repo\Delphi-Cross-Socket\OpenSSL
C:\lang\Repo\cnvcl\Source\Common                    ← CnPack — separate clone
C:\lang\Repo\cnvcl\Source\Crypto                    ← CnPack — separate clone
..\..\Common                                        ← shared test routes
```

Pasted as a single semicolon-joined string into the Search-path field:

```
C:\lang\Repo\horse-provider-crosssocket\src;C:\lang\Repo\horse-provider-crosssocket\modules\horse\src;C:\lang\Repo\Delphi-Cross-Socket\Net;C:\lang\Repo\Delphi-Cross-Socket\Utils;C:\lang\Repo\Delphi-Cross-Socket\OpenSSL;C:\lang\Repo\cnvcl\Source\Common;C:\lang\Repo\cnvcl\Source\Crypto;..\..\Common
```

**Search paths — Path B (fork `freitasjca/Delphi-Cross-Socket v1.0.3` — bundled CnPack + mTLS):**

```
C:\lang\Repo\horse-provider-crosssocket\src         ← this repo
C:\lang\Repo\horse-provider-crosssocket\modules\horse\src   ← HashLoad/horse via Boss
C:\lang\Repo\Delphi-Cross-Socket\Net                ← freitasjca/Delphi-Cross-Socket v1.0.3
C:\lang\Repo\Delphi-Cross-Socket\Utils
C:\lang\Repo\Delphi-Cross-Socket\OpenSSL
C:\lang\Repo\Delphi-Cross-Socket\CnPack\Common      ← bundled in fork
C:\lang\Repo\Delphi-Cross-Socket\CnPack\Crypto      ← bundled in fork
..\..\Common
```

> **Choose Path B when:** you need mTLS server mode (`SSLVerifyPeer = True`) or prefer one fewer clone. **Choose Path A otherwise** — it tracks the upstream `winddriver/Delphi-Cross-Socket` maintainer directly and you keep upstream improvements as soon as they land. Horse itself is identical between the two paths — Boss pulls `HashLoad/horse` either way.

### Lazarus / FPC (Console / Daemon / LCL / HTTPApplication)

1. **Project → New Project**, then add the `.lpr` file. Or **Project → Open Project** on the `.lpr` and let Lazarus generate the `.lpi`.
2. **Project → Project Options → Compiler Options → Custom Options:** add the `-d` flags from the matrix (e.g. `-dHORSE_PROVIDER_CROSSSOCKET -dHORSE_APPTYPE_DAEMON`).
3. **Compiler Options → Paths → Other unit files:** add the same path list as the Delphi block above (Path A or Path B), using `/` separators and your local checkout root instead of `C:\lang\Repo`.
4. For LCL specifically: in **Project Options → Application** check **Use LCL** (`-dLCL` is automatic).
5. **Project → Build**, then run.

---

## Running the shared client

The client (`HorseCSTestClient.dpr` at the root of this folder) is a single Delphi console binary. It dispatches 32 numbered tests against `http://127.0.0.1:9010` and prints `[HorseCSTest] X passed, Y failed`.

```
> HorseCSTestClient.exe
[HorseCSTest] Client - target: http://127.0.0.1:9010
[HorseCSTest] Ensure HorseCSTestServer is running before proceeding.

── 01  GET /ping
  PASS  status 200
  PASS  body = "pong"

  …

── 32  GET /compat/rawbody  (COMPAT-1: shadow field wins over RawWebResponse.Content)
  PASS  status 200
  PASS  body = "shadow-wins"
  PASS  RawWebResponse stub value NOT present in body

[HorseCSTest] 88 passed, 1 failed  (total 89)
```

The single failure is always Test 10 (multi-value `Set-Cookie`). It's the same failure across every shape — the limitation is in `Horse.Response.FCustomHeaders`, not in the transport or the application type.

---

## Linux daemon: systemd unit template

For shapes 5 (`Delphi/LinuxDaemon`) and 7 (`Lazarus/Daemon`):

```ini
# /etc/systemd/system/horsecs-test-daemon.service
[Unit]
Description=Horse CrossSocket integration test daemon
After=network.target

[Service]
Type=simple
ExecStart=/opt/horsecs-test/HorseCSLinuxDaemonTestServer
# or:    /opt/horsecs-test/HorseCSDaemonTestServer
Restart=on-failure
RestartSec=2s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

```sh
sudo cp horsecs-test-daemon.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start  horsecs-test-daemon
sudo systemctl status horsecs-test-daemon
# … run the client from any host that can reach :9010
sudo systemctl stop   horsecs-test-daemon    # SIGTERM → SEC-30 drain → exit 0
```

---

## Windows Service: install / start / stop

For shape 4 (`Delphi/WinService`):

```bat
REM Install — MUST be run from an elevated Command Prompt
REM (right-click → Run as administrator). A normal user-level prompt,
REM even on an Administrator account, fails with:
REM   EOSError ... System Error. Code: 5. Access is denied.
REM because UAC filters the token and SCM rejects the
REM OpenSCManager(..., SC_MANAGER_CREATE_SERVICE) call.
HorseCSServiceTestServer.exe /install

REM Start (SCM) — also requires elevation
sc start HorseCSTestService

REM Verify (any prompt — read-only is allowed)
sc query HorseCSTestService

REM Run the client from any host that can reach :9010
HorseCSTestClient.exe

REM Stop — drains via SEC-30 active-request counter
sc stop HorseCSTestService

REM Uninstall — elevated prompt again
HorseCSServiceTestServer.exe /uninstall
```

From a non-elevated PowerShell you can trigger the UAC prompt with
`Start-Process -FilePath .\HorseCSServiceTestServer.exe -ArgumentList "/install" -Verb RunAs`.

If a service-start failure shows up after `/install` succeeds, look in **Event Viewer → Windows Logs → Application** for source `Service Control Manager` (event 7000) plus the paired event from the service itself with the Pascal exception text — service-side `Listen` errors never reach the console because the process is launched by the SCM, not by your shell.

The `THorseCrossSocketService` base class runs `Listen` on a dedicated worker thread so `ServiceStart` returns to the SCM within milliseconds — the SCM's 30 s startup timeout is never an issue regardless of how slow CrossSocket's IO threads bootstrap.

---

## Why one client, many servers

The point of testing every cross-product combination is to confirm that the **transport behaviour is identical** regardless of which Application-type shape wraps it. By keeping:

- **One** route surface (`Common/Horse.CrossSocket.TestRoutes.pas`)
- **One** client test runner (`HorseCSTestClient.dpr`)
- **N** per-shape servers — each ~30–50 lines of pure lifecycle wiring

…any divergence in test results between shapes points immediately at a shape-specific bug (in the cross-product unit), not at a route-surface bug. The `88 passed, 1 failed` baseline is the contract every shape must satisfy.

---

## Test cadence

Two reasonable cadences:

1. **Per-PR sanity (fast):** build + run the Delphi/Console shape only. Catches transport regressions.
2. **Per-release matrix (slow):** build + run all 8 shapes manually. Catches shape-specific bugs in the cross-product units.

The full matrix is currently a manual exercise — no CI script orchestrates it because each shape needs its IDE-specific build environment. A future PR could add a `scripts/test-matrix.bat` for Windows that builds Delphi shapes 1–4 and runs them in turn.

---

## See also

- [`doc/providers.md` §8](../../doc/providers.md) — annotated longhand recipes for each shape (what the cross-product units automate).
- [`doc/deployment.md`](../../doc/deployment.md) — one-page cheatsheet for the seven shapes.
- [`doc/PATCH-HORSE-2-normalisation-plan.md`](../../doc/PATCH-HORSE-2-normalisation-plan.md) — the design of the cross-product units exercised here.
