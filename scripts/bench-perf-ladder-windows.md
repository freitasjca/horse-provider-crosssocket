# Running the performance ladder on Windows

Goal: produce the `raw → Horse → Horse+middleware` ladder (all providers, RPS +
P50–P99) on Windows with **`bench-perf-ladder.bat`**, run from `cmd`.

The script runs each server in isolation, warms it up, runs N times averaged, and
writes the table to console **and** `bench-perf-ladder-c<c>-n<n>.txt`. (Linux/WSL
sibling: `bench-perf-ladder-linux.md`.)

---

## 1. Prerequisites

### 1a. bombardier (Windows build)

**Which build:** a 64-bit PC needs the **`windows-amd64`** prebuilt `.exe` from the official
releases (use `windows-arm64` only on an ARM device). Download with PowerShell:
```powershell
mkdir C:\tools\bombardier
curl.exe -L -o C:\tools\bombardier\bombardier.exe `
  https://github.com/codesenberg/bombardier/releases/latest/download/bombardier-windows-amd64.exe
C:\tools\bombardier\bombardier.exe --version
```
(The `/releases/latest/download/` URL always fetches the current version.)

**Where to install it:** Windows has no FHS, so the convention is a **dedicated tools folder**.
The script defaults to **`C:\tools\bombardier\bombardier.exe`** — keep it there and nothing else
is needed. Otherwise either:
- edit the `set BOMB=` line at the top of `bench-perf-ladder.bat`, or
- add the folder to `PATH` and set `set BOMB=bombardier.exe`
  (`setx PATH "%PATH%;C:\tools\bombardier"`, then reopen `cmd`).

| Location | Use for |
|---|---|
| **`C:\tools\<tool>\`** | manually-installed CLI tools ← the script's default |
| `C:\Program Files\…` | installer-managed apps (needs admin; spaces in path) |
| `%USERPROFILE%\bin` + on PATH | per-user, no admin |

Keep it (and run from) a **local disk** — not OneDrive/network paths.

### 1b. The server binaries — Win64 **Release** `.exe`
The script expects these **six** in `SERVERS_DIR`:
```
HorseBenchRawMormot.exe  HorseBenchRawCrossSocket.exe  HorseBenchRawIndy.exe
HorseBenchIndy.exe       HorseBenchCrossSocket.exe     HorseBenchMormot.exe
```
Build each with Delphi, **Win64 / Release**. Conditional defines per project:

| Project | Conditional define | Notes |
|---|---|---|
| HorseBenchIndy | *(none)* | default = Indy/Console provider |
| HorseBenchCrossSocket | `HORSE_PROVIDER_CROSSSOCKET` | |
| HorseBenchMormot | `HORSE_PROVIDER_MORMOT` | |
| HorseBenchRaw* | *(none)* | no Horse units referenced |

> **`HorseBenchRawIndy` has no `.dproj` yet** — create it in the IDE (New → Console
> App, add `HorseBenchRawIndy.dpr`, add the **Indy** library paths used by
> `HorseBenchIndy.dproj`, no defines, Win64/Release).

> ⚠️ **THE critical Windows pitfall — the stale-DCU trap.**
> If `HorseBenchCrossSocket` / `HorseBenchMormot` share a DCU output folder with the
> Indy project, the `HORSE_PROVIDER_*` define may **not** recompile `Horse.dcu`, and
> the binary silently runs **Indy** instead — exactly what contaminated the first
> round of results (CrossSocket/mORMot showing Indy's ~60% 500s). Prevent it:
> - give each project its **own unit output (DCU) directory**, **or** do a **Build**
>   (not *Compile*) / clean the DCU dir between providers;
> - **verify** after building (see §4): the startup banner shows the active provider,
>   and the thread count must match (`Indy ≈ c`, `CrossSocket ≈ nproc*2+1 ≈ 57`,
>   `mORMot ≈ 32`). If "CrossSocket" spawns ~c threads, it's secretly Indy — rebuild.

### 1c. Windows knobs (do these before measuring)
- **Power plan → High Performance.** On hybrid CPUs (e.g. PC1 i7-14700HX, 8P+12E) the
  *Balanced* plan relegates server threads to E-cores and drops throughput ~35–40%.
- **Pause antivirus / Defender real-time** (or exclude the bench folder + bombardier).
  ESET `ekrn` in particular measurably perturbs results.
- **Idle the box:** close browsers and background load (they steal cores and skew RPS).
- Firewall: localhost (127.0.0.1) needs no rule; if prompted, allow on Private.

---

## 2. Install the script
Put `bench-perf-ladder.bat` in the same folder as the six `.exe` (e.g.
`C:\lang\Repo\bin\Win64\Release`). The script auto-detects `SERVERS_DIR` (its own
folder, else `..\samples\bench\Win64\Release`, else `..\Win64\Release`).

The `.bat` must be **ASCII + CRLF** (it already is). If you hand-edit it, keep CRLF.

---

## 3. Run (from `cmd`)
```bat
bench-perf-ladder.bat                 :: c=100 n=200000 runs=3  (caps auto 256/200)
bench-perf-ladder.bat 500             :: c=500, caps auto 1000/1000, warm-up 5000
bench-perf-ladder.bat 200 500000      :: c=200, n=500000
bench-perf-ladder.bat 100 200000 3 256 200   :: explicit maxconn/listenqueue

:: concurrency sweep (one ladder each; each writes its own file):
for %c in (10 28 56 100 200 500) do bench-perf-ladder.bat %c
```
(Inside a `.bat` file, double the percent: `for %%c in (...) do ...`.)

Output columns (same as Linux):
```
 LABEL                       RPSavg   2xx        5xx      others   P50       P75       P90       P95       P99
 raw-mormot bare             ...      200000     0        0        ...
 ...
 Horse+Indy +headers         ...
```

**Reading it:** take `raw-mormot bare` RPS as the ceiling;
`fraction retained = row_RPS / ceiling`. Any non-zero `5xx`/`others` means that
row's RPS is **inflated by failures** — ignore it and fix the cause (see §4).

### mORMot backend A/B — thread-pool / async / http.sys

The ladder runs each mORMot tier on **all three** of mORMot2's HTTP servers:

```
 raw-mormot bare                 ← THttpServer     (thread pool, default)
 raw-mormot bare (async)         ← THttpAsyncServer (--async, non-blocking IOCP)
 raw-mormot bare (httpapi)       ← THttpApiServer   (--httpapi, Windows http.sys)
 Horse+mORMot bare               ← THttpServer
 Horse+mORMot bare (async)       ← THttpAsyncServer
 Horse+mORMot bare (httpapi)     ← THttpApiServer
```

The `(async)` / `(httpapi)` rows come from the bench servers' `--async` / `--httpapi`
switches (`THorseMormotConfig.ServerKind = mskAsync` / `mskHttpApi`). Read them as deltas:

- **`raw-mormot bare (async)` vs `raw-mormot bare`** — the *transport-only* effect of the
  async engine, no Horse in the path.
- **`Horse+mORMot bare (async)` vs `Horse+mORMot bare`** — the same swap *with* the Horse
  pipeline; comparing the deltas isolates transport gains from framework interaction.
- The `(httpapi)` rows are the same comparison for the Windows kernel-mode http.sys server.

Expect async to hold throughput and lower the P99/P99.9 tail at high `c` (≥100); at low `c`
the two are usually within noise. `--async` accepts `--maxconn` but ignores `--listenqueue`
(Indy-only), so the async rows omit it. Building the `--async` server needs
`mormot.net.async` on the project search path (it ships in the same mORMot2 `src\net`).

#### http.sys rows show `ERR  noListen` — fix the URL ACL

Unlike the socket backends, `--httpapi` (http.sys) does **not** `bind()` a port — it
*registers a URL prefix* with the kernel, which needs **Administrator rights or a one-time
URL reservation**. Without one, the server's `AddUrl` fails with `ERROR_ACCESS_DENIED`, it
exits, and the cell reports `ERR  noListen`. (You don't see the real message because the
ladder redirects each server's output to `nul`.)

Confirm by running one server by hand so its stdout is visible:

```bat
HorseBenchRawMormot.exe --httpapi
REM prints "http.sys AddUrl failed … run as Administrator, or netsh …" instead of "Listening…"
```

Fix — **pick one:**

- **Pre-authorize the ports once** (in an *elevated* `cmd`), then run the ladder normally:

  ```bat
  netsh http add urlacl url=http://+:9003/ user=%USERDOMAIN%\%USERNAME%
  netsh http add urlacl url=http://+:9005/ user=%USERDOMAIN%\%USERNAME%
  netsh http add urlacl url=http://+:9013/ user=%USERDOMAIN%\%USERNAME%
  ```
  (9005 = raw-mormot, 9003/9013 = Horse+mORMot http.sys ports.) Use your account, **not**
  `user=Everyone` — "Everyone" is localized on non-English Windows and fails; the locale-safe
  Everyone SID is `user=S-1-1-0`.

- **Or run the whole ladder from an elevated `cmd`** — with admin rights `AddUrl` reserves the
  URL itself, no netsh needed (but every tier then runs elevated).

Manage reservations with `netsh http show urlacl` and
`netsh http delete urlacl url=http://+:9005/`. The non-http.sys rows never need this — they
bind a socket directly. If you don't care about the kernel-mode comparison, the `(httpapi)`
`ERR` rows are harmless to ignore.

---

## 4. Verify the build is correct (avoid the mis-build)
Before trusting a run, start one server by hand and check:
```bat
HorseBenchCrossSocket.exe --headers-only
```
- The startup banner should identify the CrossSocket provider (not Indy).
- In **Task Manager → Details** (add the *Threads* column) or PowerShell:
  ```powershell
  (Get-Process HorseBenchCrossSocket).Threads.Count   # expect ~57 (nproc*2+1), NOT ~c
  ```
- A correctly-built run shows **CrossSocket/mORMot at 0 `5xx` / 0 `others`** while
  **Indy** needs `--maxconn`/`--listenqueue` to stay clean. If CrossSocket/mORMot
  *also* shed ~60% 5xx, they're mis-built (secretly Indy) — rebuild per §1b.

---

## 5. Windows-specific caveats
- **`5xx` on Indy** without enough `--maxconn` = the WebBroker `MaxConnections=32`
  cap. The script auto-scales `maxconn` to ≥ c, so this should be 0; if not, the
  build is stale or you overrode the caps too low.
- **`others` (connectex refusals)** = `ListenQueue` < the connection burst, or
  ephemeral-port/`TIME_WAIT` pressure at very high c. The script auto-scales
  `listenqueue`; for very high c you can also widen the dynamic port range:
  ```bat
  netsh int ipv4 show dynamicport tcp
  netsh int ipv4 set dynamicport tcp start=10000 num=55000
  ```
  (bombardier reuses keep-alive connections, so this rarely bites until c is large.)
- **`ERR  noListen` on the `(httpapi)` rows** = http.sys URL reservation missing.
  Run the netsh `urlacl` commands once (elevated) for ports 9003/9005/9013, or run the
  ladder elevated — see "http.sys rows show ERR noListen" in §3. Harmless to ignore if you
  don't need the kernel-mode comparison.
- **Run from a local disk** — not OneDrive/network paths.
- **Hybrid CPUs:** confirm High Performance actually parks work on P-cores; the
  Delphi client and bombardier can even *reverse* the PC1/PC2 ranking under Balanced.

---

## 6. Quick checklist
- [ ] `bombardier.exe` at `c:\tools\bombardier\` (or `set BOMB=` edited)
- [ ] six `.exe` built **Win64 Release** with the **correct defines**, each in one folder
- [ ] `HorseBenchRawIndy.dproj` created and built
- [ ] **no stale-DCU mis-build** — verified via banner + thread count (§4)
- [ ] `bench-perf-ladder.bat` in that folder (ASCII + CRLF)
- [ ] **High Performance** power plan; AV paused; box idle
- [ ] run `bench-perf-ladder.bat` (or a sweep); check `5xx`/`others` are 0 on the clean rows
