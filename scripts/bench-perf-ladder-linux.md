# Running the performance ladder on Linux / WSL

Goal: reproduce the **exact same output** as `bench-perf-ladder.bat` (the
`raw → Horse → Horse+middleware` ladder, all providers, RPS + P50–P99) on Linux,
driven by **`bench-perf-ladder.sh`**, run inside **WSL**.

The runner script is a faithful bash port of the `.bat` (same auto-scaled caps,
warm-up, RUNS averaging, per-c/n result file, identical columns). The only real
work is **getting Linux builds of the server binaries** and a couple of WSL knobs.

---

## 1. Prerequisites

### 1a. bombardier (Linux build)

**Which build:** WSL Ubuntu 22 on a normal PC is **x86-64**, so use the **`linux-amd64`**
prebuilt binary from the official releases (use `linux-arm64` only if `uname -m` reports
`aarch64`, e.g. ARM Windows):

```bash
uname -m        # x86_64 = amd64 ;  aarch64 = arm64
curl -L -o bombardier \
  https://github.com/codesenberg/bombardier/releases/latest/download/bombardier-linux-amd64
chmod +x bombardier
```
(The `/releases/latest/download/` URL always fetches the current version. With Go installed,
`go install github.com/codesenberg/bombardier@latest` also works → `~/go/bin`.)

**Where to install it — `/usr/local/bin`** (the FHS location for manually-installed tools;
already on `PATH`, separate from apt-managed `/usr/bin`):
```bash
sudo mv bombardier /usr/local/bin/
bombardier --version && which bombardier      # -> /usr/local/bin/bombardier
```
No-sudo alternative: `mkdir -p ~/.local/bin && mv bombardier ~/.local/bin/` (on PATH on
modern Ubuntu).

| Location | Use for |
|---|---|
| **`/usr/local/bin`** | manually-installed tools, all users ← recommended |
| `/usr/bin` | apt-managed binaries only — don't drop downloads here |
| `~/.local/bin` / `~/bin` | per-user install, no sudo |
| `/opt/<tool>/` | large self-contained app dirs (overkill for one binary) |

`bench-perf-ladder.sh` defaults to `bombardier` on `PATH`, so installing to `/usr/local/bin`
means **no extra config**. Only if it's off-PATH do you need `export BOMB=/path/to/bombardier`.
Keep it on the **Linux filesystem** (not `/mnt/c/...`, which is slower and skews results).

### 1b. The server binaries — built for Linux (ELF, no `.exe`)
The script expects these **six** ELF binaries in `SERVERS_DIR` (default: the script's folder):

```
HorseBenchRawMormot  HorseBenchRawCrossSocket  HorseBenchRawIndy
HorseBenchIndy       HorseBenchCrossSocket     HorseBenchMormot
```

Build them with **Delphi LINUX64** (recommended — keeps the *same* providers: real
Indy/WebBroker, CrossSocket→epoll, mORMot→epoll/threadpool). FPC is **not**
equivalent here (Horse's FPC default is `fphttpserver`, not Indy/WebBroker).

> ⚠️ **One source change is required first.** The bench `.dpr` are currently
> Windows-only: they use `Winapi.Windows` + `SetConsoleCtrlHandler` +
> `function CtrlHandler(...): BOOL; stdcall;`. Those don't exist on Linux64, so the
> projects won't compile for Linux until the Ctrl-handler is guarded. Wrap it:
>
> ```pascal
> uses
>   {$IFDEF MSWINDOWS} Winapi.Windows, {$ENDIF}
>   {$IFDEF LINUX}     Posix.Signal,   {$ENDIF}
>   System.SysUtils, ... ;
>
> {$IFDEF MSWINDOWS}
> function CtrlHandler(dwCtrlType: DWORD): BOOL; stdcall;
> begin GShutdown := True; if Assigned(GServer) then GServer.Active := False; Result := True; end;
> {$ENDIF}
> {$IFDEF LINUX}
> procedure SignalHandler(ASigNum: Integer); cdecl;
> begin GShutdown := True; end;   { the script also kill()s the process }
> {$ENDIF}
>
> begin
>   {$IFDEF MSWINDOWS} SetConsoleCtrlHandler(@CtrlHandler, True); {$ENDIF}
>   {$IFDEF LINUX}     Posix.Signal.signal(SIGINT,  @SignalHandler);
>                      Posix.Signal.signal(SIGTERM, @SignalHandler); {$ENDIF}
>   ...
> ```
> The Horse servers (which block in `THorse.Listen`) need the same guard around
> their `CtrlHandler`/`THorse.StopListen` call. (Ask me to apply these guards to
> all bench `.dpr` — it's a small, mechanical change per project.)

**Build & deploy (Delphi Linux64):**
1. Install **PAServer** in WSL (`paserver` from the Delphi `PAServer` redist) and start it.
2. In the IDE: add the **Linux64** platform to each bench project, set **Release**, build.
3. Delphi deploys the ELF to the PAServer scratch dir (`~/PAServer/scratch-dir/<profile>/`).
   Copy all six binaries into one folder, e.g. `~/horsebench/`.

### 1c. WSL knobs (do these once per shell / session)
```bash
ulimit -n 100000                 # Indy spawns ~c threads+fds at high c; default 1024 is too low
cat /proc/sys/net/core/somaxconn # ListenQueue is clamped to this; raise if < your listenqueue:
sudo sysctl -w net.core.somaxconn=1024
```
- **CPU count:** `nproc`. WSL2 sees the host cores (or the subset set in `C:\Users\<you>\.wslconfig` → `[wsl2] processors=N`). CrossSocket auto-sizes its IO threads = `nproc*2+1`.
- **Stable clocks:** WSL2 is a lightweight VM — set the **Windows host** power plan to *High Performance* for consistent results.
- **Run from a native WSL path** (`~/horsebench`), **not** `/mnt/c/...` — `/mnt/c` (DrvFs) is slower and can skew results.

---

## 2. Install the script

Put `bench-perf-ladder.sh` in the same folder as the six binaries (or set
`SERVERS_DIR`), and make it executable:
```bash
cp bench-perf-ladder.sh ~/horsebench/
cd ~/horsebench
chmod +x bench-perf-ladder.sh
```
(If you copied it from Windows, strip CRLF: `sed -i 's/\r$//' bench-perf-ladder.sh`.)

---

## 3. Run

```bash
./bench-perf-ladder.sh                 # c=100 n=200000 runs=3  (caps auto 256/200)
./bench-perf-ladder.sh 500             # c=500, caps auto 1000/1000, warm-up 5000
./bench-perf-ladder.sh 200 500000      # c=200, n=500000
./bench-perf-ladder.sh 100 200000 3 256 200   # explicit maxconn/listenqueue

# concurrency sweep (one ladder each; each writes its own file):
for c in 10 28 56 100 200 500; do ./bench-perf-ladder.sh "$c"; done
```

Output goes to the console **and** to `bench-perf-ladder-c<c>-n<n>.txt`, with the
same columns as Windows:

```
 LABEL                       RPSavg   2xx        5xx      others   P50       P75       P90       P95       P99
 raw-mormot bare             ...      200000     0        0        ...
 ...
 Horse+Indy +headers         ...
```

**Reading it** (identical to Windows): take `raw-mormot bare` RPS as the ceiling;
`fraction retained = row_RPS / ceiling`. Any non-zero `5xx`/`others` means that
row's RPS is inflated by failures — ignore it and check the build/limits.

---

## 4. What to expect vs Windows (and what's different)

- **The *shape* should replicate:** Indy degrades under concurrency (thread-per-connection
  → tail blow-up; `raw-indy` and `Horse+Indy` both collapse with headers), while
  CrossSocket/mORMot stay flat. That conclusion is transport-architectural, so it holds on Linux.
- **Absolute numbers will differ:** CrossSocket uses **epoll** on Linux (IOCP on Windows);
  mORMot uses its epoll/threadpool path; Indy is still thread-per-connection but on the
  Linux scheduler. WSL2 also runs ~10–30% below native Linux.
- **`others` at high c** on Linux can also come from `ulimit -n` or `somaxconn` — raise both
  (§1c) before blaming the server. The script's caps auto-scale, but the OS limits don't.

---

## 5. Quick checklist
- [ ] `bombardier` (Linux) on PATH or `$BOMB` set
- [ ] six ELF binaries built (Delphi Linux64, Release) in one folder
- [ ] `.dpr` Ctrl-handler guarded with `{$IFDEF MSWINDOWS}` (so they compile on Linux64)
- [ ] `bench-perf-ladder.sh` copied there, `chmod +x`, LF line-endings
- [ ] `ulimit -n 100000`; `somaxconn >=` your listenqueue
- [ ] run from a native WSL path, Windows host on High Performance
